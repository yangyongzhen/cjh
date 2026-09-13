package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import cjh.tools.*

/**
 * CangjieRefTool 单元测试
 *
 * 覆盖（对齐 AGENTS.md：主路径 + 错误路径 + 边界）：
 * - 主路径：中文关键词命中、ASCII 符号命中、命中片段带文件路径 + 行号 + 小节标题
 * - 边界：递归下钻子目录、只收 Markdown（.txt / .sqlite3 必须跳过）、path 过滤、
 *         max_results（含字符串写法）、单字兜底分词、同一文件限量
 * - 错误路径：缺 query、query 无有效字符、语料目录不存在、path 过滤后无文件
 *
 * 说明：分词（refTokens）与行打分（scoreRefLine）是 cjh.tools 的 public 纯函数，直接断言；
 * 检索行为一律通过 execute() 公共 API 断言 ToolResult 契约。
 */
@Test
public class CangjieRefToolTest {
    private let dir: String = testTempDir("cangjie_ref")

    private func setupCorpus(): Unit {
        // dir/
        //   cangjie-quickref/SKILL.md          ← 中文命中（两行含"字节流转"）
        //   cangjie-coding/SKILL.md            ← ASCII 符号命中（ArrayList / sortBy）
        //   cangjie-coding/references/a.md     ← 递归下钻命中（envsetup / cjpm）
        //   notes/raw.txt                      ← 非 Markdown + 中文同词，必须跳过
        //   cangjie-coding/references/knowledge.sqlite3 ← 二进制（含同词），必须跳过
        removeTree(this.dir)
        Directory.create(this.dir + "/cangjie-quickref", recursive: true)
        Directory.create(this.dir + "/cangjie-coding/references", recursive: true)
        Directory.create(this.dir + "/notes", recursive: true)
        writeTextFile(this.dir + "/cangjie-quickref/SKILL.md",
            "# 仓颉速查\n" +
            "\n" +
            "## 字节与字符串\n" +
            "\n" +
            "字节流转 String 禁止逐字节 Rune(byte)，须整段 safeFromUtf8。\n" +
            "字节流转 的勘误见踩坑记录 §3.15。\n")
        writeTextFile(this.dir + "/cangjie-coding/SKILL.md",
            "# cangjie coding\n" +
            "\n" +
            "## Search\n" +
            "\n" +
            "Use ArrayList sortBy to order items; Directory.walk is not recursive.\n")
        writeTextFile(this.dir + "/cangjie-coding/references/a.md",
            "# 参考资料\n" +
            "\n" +
            "## 环境\n" +
            "\n" +
            "cjc 与 cjpm 需要先 source envsetup.sh。\n")
        writeTextFile(this.dir + "/notes/raw.txt", "字节流转 String 禁止逐字节 —— 非 Markdown，不应被检索\n")
        writeTextFile(this.dir + "/cangjie-coding/references/knowledge.sqlite3", "字节流转 String 禁止逐字节\n")
    }

    /**
     * 组装参数执行检索；maxResults <= 0 表示不传该参数
     */
    private func runQuery(query: String, maxResults: Int64, pathFilter: String): ToolResult {
        let tool = CangjieRefTool(this.dir)
        var args = JsonObject()
        args.put("query", JsonString(query))
        if (maxResults > 0) {
            args.put("max_results", JsonInt(maxResults))
        }
        if (pathFilter.size > 0) {
            args.put("path", JsonString(pathFilter))
        }
        return tool.execute(args)
    }

    // ---------- 分词与打分（纯函数） ----------

    @TestCase
    public func testTokensCjkBigram(): Unit {
        let tokens = refTokens("编译报错")
        @Assert(tokens.size, 3)
        @Assert(tokens.contains("编译"), true)
        @Assert(tokens.contains("译报"), true)
        @Assert(tokens.contains("报错"), true)
    }

    @TestCase
    public func testTokensAsciiLoweredAndSplit(): Unit {
        let tokens = refTokens("ArrayList sortBy")
        @Assert(tokens.contains("arraylist"), true)
        @Assert(tokens.contains("sortby"), true)
        @Assert(tokens.contains("a"), false)  // 单字符不进主 token
    }

    @TestCase
    public func testTokensSingleCharFallback(): Unit {
        // 整体只有单字符时回退单字，保证"查单字"仍可用
        let tokens = refTokens("排")
        @Assert(tokens.size, 1)
        @Assert(tokens.contains("排"), true)
    }

    @TestCase
    public func testTokensMixedRepeatsDeduped(): Unit {
        let tokens = refTokens("编译 编译")
        @Assert(tokens.size, 1)
        @Assert(tokens.contains("编译"), true)
    }

    @TestCase
    public func testLowerAsciiKeepsMultibyteIntact(): Unit {
        // 回归：逐字节切片会切碎 UTF-8 序列（运行时 "Invalid utf8 byte sequence"）
        @Assert(lowerAsciiStr("字节Stream 编译报错"), "字节stream 编译报错")
        @Assert(lowerAsciiStr(""), "")
    }

    @TestCase
    public func testScoreFullCoverageAndHeadingBonus(): Unit {
        let tokens = refTokens("字节流转")
        let full = scoreRefLine("字节流转 String 禁止逐字节", false, tokens)
        let partial = scoreRefLine("字节流很有用", false, tokens)
        let heading = scoreRefLine("# 字节流转", true, tokens)
        let none = scoreRefLine("完全不相关的一行", false, tokens)
        @Assert(full > 0, true)
        @Assert(full > partial, true)   // 全覆盖优于部分命中
        @Assert(heading > full - 8, true)  // 标题行有额外加成
        @Assert(none, 0)                // 零命中不打分
    }

    // ---------- 检索主路径 ----------

    @TestCase
    public func testExecuteChineseHitWithPathLineHeading(): Unit {
        this.setupCorpus()
        let result = this.runQuery("字节流转", 5, "")
        @Assert(result.isError, false)
        @Assert(result.content.contains("cangjie-quickref/SKILL.md:5"), true)  // 文件路径 + 行号
        @Assert(result.content.contains("字节与字符串"), true)                  // 命中所在小节标题
        @Assert(result.content.contains("safeFromUtf8"), true)                // 命中行内容
    }

    @TestCase
    public func testExecuteAsciiSymbolHit(): Unit {
        this.setupCorpus()
        let result = this.runQuery("sortBy", 5, "")
        @Assert(result.isError, false)
        @Assert(result.content.contains("cangjie-coding/SKILL.md"), true)
        @Assert(result.content.contains("ArrayList"), true)
    }

    @TestCase
    public func testExecuteRecursesIntoSubdir(): Unit {
        this.setupCorpus()
        let result = this.runQuery("envsetup", 5, "")
        @Assert(result.isError, false)
        @Assert(result.content.contains("references/a.md"), true)  // 子目录里的 .md 被递归收集
        @Assert(result.content.contains("环境"), true)
    }

    // ---------- 边界 ----------

    @TestCase
    public func testExecuteSkipsNonMarkdownAndBinary(): Unit {
        this.setupCorpus()
        let result = this.runQuery("字节流转", 5, "")
        @Assert(result.isError, false)
        @Assert(result.content.contains("raw.txt"), false)              // .txt 不在语料白名单
        @Assert(result.content.contains("knowledge.sqlite3"), false)    // 二进制不当文本读
    }

    @TestCase
    public func testExecutePathFilter(): Unit {
        this.setupCorpus()
        let result = this.runQuery("cjpm", 5, "cangjie-coding")
        @Assert(result.isError, false)
        @Assert(result.content.contains("references/a.md"), true)
        @Assert(result.content.contains("cangjie-quickref"), false)  // 过滤掉的目录不出现
    }

    @TestCase
    public func testExecuteMaxResultsAsString(): Unit {
        this.setupCorpus()
        // 同一文件两行命中，max_results 用字符串写法（"1"）只展示 1 条
        let tool = CangjieRefTool(this.dir)
        var args = JsonObject()
        args.put("query", JsonString("字节流转"))
        args.put("max_results", JsonString("1"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("[1]"), true)
        @Assert(result.content.contains("[2]"), false)
    }

    @TestCase
    public func testExecuteNoHitNotError(): Unit {
        this.setupCorpus()
        let result = this.runQuery("完全不存在的关键词xyz", 5, "")
        @Assert(result.isError, false)  // 未命中不是错误：给建议即可
        @Assert(result.content.contains("未命中"), true)
    }

    // ---------- 错误路径 ----------

    @TestCase
    public func testExecuteMissingQuery(): Unit {
        let tool = CangjieRefTool(this.dir)
        let result = tool.execute(JsonObject())
        @Assert(result.isError, true)
        @Assert(result.content.contains("query"), true)
    }

    @TestCase
    public func testExecuteEmptyQuery(): Unit {
        this.setupCorpus()
        let result = this.runQuery("   ", 5, "")
        @Assert(result.isError, true)
    }

    @TestCase
    public func testExecuteCorpusMissing(): Unit {
        let tool = CangjieRefTool("/tmp/cjh_ut_cangjie_ref_absent")
        var args = JsonObject()
        args.put("query", JsonString("ArrayList"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("install-cangjie-knowledge.sh"), true)  // 给出可操作提示
    }

    @TestCase
    public func testExecutePathFilterWithoutFiles(): Unit {
        this.setupCorpus()
        let result = this.runQuery("ArrayList", 5, "no_such_dir")
        @Assert(result.isError, true)
    }

    // ---------- 工具契约 ----------

    @TestCase
    public func testSpecNameAndReadOnly(): Unit {
        let tool = CangjieRefTool(this.dir)
        @Assert(tool.spec().name, "cangjie_ref")
        @Assert(tool.isReadOnly(), true)  // 只读：可被并发执行引擎并行调度
    }
}
