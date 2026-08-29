package cjh.tests

import stdx.encoding.json.*
import std.fs.*
import cjh.tools.*

/**
 * GlobTool 单元测试：双星/单星/问号 通配、basePath、隐藏文件跳过、无匹配
 * （块注释内不写 星号斜杠 序列，避免触发嵌套注释解析）
 */
@Test
public class GlobToolTest {
    private let dir: String = testTempDir("glob")

    private func setupTree(): Unit {
        // dir/
        //   a.txt
        //   b.md
        //   sub/
        //     c.txt
        //   .hidden.txt
        // Directory.create 对已存在目录抛异常（不幂等），先整体清理再重建
        removeTree(this.dir)
        Directory.create(this.dir + "/sub", recursive: true)
        writeTextFile(this.dir + "/a.txt", "a\n")
        writeTextFile(this.dir + "/b.md", "b\n")
        writeTextFile(this.dir + "/sub/c.txt", "c\n")
        writeTextFile(this.dir + "/.hidden.txt", "h\n")
    }

    private func runGlob(pattern: String): ToolResult {
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString(pattern))
        args.put("path", JsonString(this.dir))
        return tool.execute(args)
    }

    @TestCase
    public func testDoubleStarMatchesNested(): Unit {
        this.setupTree()
        let result = this.runGlob("**/*.txt")
        @Assert(result.isError, false)
        @Assert(result.content.contains("a.txt"), true)
        @Assert(result.content.contains("c.txt"), true)  // 子目录
    }

    @TestCase
    public func testSingleStarNoCrossDir(): Unit {
        this.setupTree()
        let result = this.runGlob("*.txt")
        @Assert(result.isError, false)
        @Assert(result.content.contains("a.txt"), true)
        @Assert(result.content.contains("c.txt"), false)  // * 不跨目录
    }

    @TestCase
    public func testQuestionMarkSingleChar(): Unit {
        this.setupTree()
        let result = this.runGlob("?.txt")
        @Assert(result.isError, false)
        @Assert(result.content.contains("a.txt"), true)
        @Assert(result.content.contains("b.md"), false)
    }

    @TestCase
    public func testHiddenFileSkipped(): Unit {
        this.setupTree()
        let result = this.runGlob("**/*.txt")
        @Assert(result.isError, false)
        @Assert(result.content.contains(".hidden.txt"), false)
    }

    @TestCase
    public func testNoMatch(): Unit {
        this.setupTree()
        let result = this.runGlob("*.xyz")
        @Assert(result.isError, false)
        @Assert(result.content.contains("没有文件匹配"), true)
    }

    @TestCase
    public func testEmptyPatternRejected(): Unit {
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString(""))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testNonexistentBasePath(): Unit {
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString("*.txt"))
        args.put("path", JsonString(this.dir + "/nope"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testGlobMatchDirectStarAtEnd(): Unit {
        // "**" 在模式末尾：匹配剩余所有内容（含跨目录）
        @Assert(GlobToolMatches.matchStarEnd(), true)
    }
}

/**
 * globMatchDirect 是 cjh.tools 包私有函数，测试包不可直接调用；
 * 通过等价场景间接验证：** 结尾模式匹配任意层级
 */
class GlobToolMatches {
    public static func matchStarEnd(): Bool {
        // 用 GlobTool 执行 "sub/**" 应匹配 sub/c.txt
        let dir = "/tmp/cjh_ut_globstar"
        try {
            removeTree(dir)
            Directory.create(dir + "/sub", recursive: true)
            File.writeTo(dir + "/sub/c.txt", "c".toArray())
            let tool = GlobTool()
            var args = JsonObject()
            args.put("pattern", JsonString("sub/**"))
            args.put("path", JsonString(dir))
            let result = tool.execute(args)
            return result.content.contains("c.txt")
        } catch (e: Exception) {
            return false
        }
    }
}
