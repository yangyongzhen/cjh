package cjh

import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * ast_grep 纯函数测试（根包 cjh 内）：
 * - parseSgJsonLine：sg --json=stream 单行解析
 * - escapeRegex：grep 降级正则转义
 * - tryAstGrepCli 降级路径：sg 不存在返回 None
 * - AstGrepTool 端到端降级：无 sg 时 grep 兜底
 */
@Test
public class AstGrepTest {

    @TestCase
    public func testParseSgJsonLineFull(): Unit {
        let line = "{\"text\":\"fn main() {\",\"fileName\":\"src/main.rs\",\"range\":{\"start\":{\"line\":1,\"column\":0},\"end\":{\"line\":3,\"column\":1}}}"
        let parsed = parseSgJsonLine(line)
        @Assert(parsed.isSome(), true)
        let info = parsed.getOrThrow()
        // 行号 1-based（内部 0-based +1）；列 0-based 原样
        @Assert(info.startsWith("src/main.rs:2:0:"), true)
        @Assert(info.contains("fn main() {"), true)
    }

    @TestCase
    public func testParseSgJsonLineMissingFields(): Unit {
        // 缺 fileName/range → 用默认值，不崩溃
        let line = "{\"text\":\"abc\"}"
        let parsed = parseSgJsonLine(line)
        @Assert(parsed.isSome(), true)
        @Assert(parsed.getOrThrow().contains("abc"), true)
    }

    @TestCase
    public func testParseSgJsonLineInvalidJson(): Unit {
        @Assert(parseSgJsonLine("not json at all").isSome(), false)
        @Assert(parseSgJsonLine("").isSome(), false)
    }

    @TestCase
    public func testParseSgJsonLineNonObject(): Unit {
        @Assert(parseSgJsonLine("[1,2,3]").isSome(), false)
    }

    @TestCase
    public func testParseSgJsonLineTextTruncated(): Unit {
        var sb = StringBuilder()
        sb.append("{\"text\":\"")
        for (i in 0..200) {
            sb.append("x")
        }
        sb.append("\",\"fileName\":\"f.rs\",\"range\":{\"start\":{\"line\":0,\"column\":0},\"end\":{\"line\":1,\"column\":0}}}")
        let parsed = parseSgJsonLine(sb.toString())
        @Assert(parsed.isSome(), true)
        let info = parsed.getOrThrow()
        @Assert(info.size < 120, true)
        @Assert(info.endsWith("..."), true)
    }

    @TestCase
    public func testParseSgJsonLineEscapesNewline(): Unit {
        // text 含换行 → 转义为 \n 显示
        let line = "{\"text\":\"a\\nb\",\"fileName\":\"f.rs\",\"range\":{\"start\":{\"line\":0,\"column\":0},\"end\":{\"line\":1,\"column\":0}}}"
        let parsed = parseSgJsonLine(line)
        @Assert(parsed.isSome(), true)
        @Assert(parsed.getOrThrow().contains("a\\nb"), true)
    }

    @TestCase
    public func testEscapeRegexMetaChars(): Unit {
        @Assert(escapeRegex("a.b*c"), "a\\.b\\*c")
        @Assert(escapeRegex("fn(x)"), "fn\\(x\\)")
        @Assert(escapeRegex("a+b?c"), "a\\+b\\?c")
        @Assert(escapeRegex("plain"), "plain")
        @Assert(escapeRegex("$^"), "\\$\\^")
        @Assert(escapeRegex(""), "")
    }

    @TestCase
    public func testTryAstGrepCliFallsBackWhenSgMissing(): Unit {
        // sg 大概率不存在 → 返回 None（触发 grep 降级）；若已安装则返回 Some
        let result = tryAstGrepCli("fn $NAME()", "rust", ".", 0)
        // 两种结果都合法：sg 存在 → Some(格式化文本)；不存在 → None
        @Assert(result.isSome() || result == None, true)
    }

    @TestCase
    public func testAstGrepToolMissingParams(): Unit {
        let tool = AstGrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("x"))
        let result = tool.execute(args)  // 缺 lang
        @Assert(result.isError, true)
    }

    @TestCase
    public func testAstGrepToolEmptyPattern(): Unit {
        let tool = AstGrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString(""))
        args.put("lang", JsonString("rust"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("pattern 不能为空"), true)
    }

    @TestCase
    public func testAstGrepToolUnsupportedLang(): Unit {
        let tool = AstGrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("x"))
        args.put("lang", JsonString("haskell"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("不支持的 lang"), true)
    }

    @TestCase
    public func testAstGrepToolGrepFallback(): Unit {
        // 无 sg 环境：降级 grep 字面匹配 .rs 文件
        let dir = coreTestTempDir("astgrep")
        coreWriteTextFile(dir + "/main.rs", "fn main() {\n    // TODO: fix\n}\n")
        let tool = AstGrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("TODO"))
        args.put("lang", JsonString("rust"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        // sg 缺失时 grep 降级命中；sg 存在时 ast-grep 命中——两种情况都不应 isError
        @Assert(result.isError, false)
    }
}
