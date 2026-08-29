package cjh.tests

import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * GrepTool 单元测试：单文件/目录搜索、正则、上下文、忽略目录、错误路径
 */
@Test
public class GrepToolTest {
    private let dir: String = testTempDir("grep")

    @TestCase
    public func testSingleFileMatch(): Unit {
        let path = this.dir + "/single.txt"
        writeTextFile(path, "alpha\nbeta\ngamma\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("beta"))
        args.put("path", JsonString(path))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("匹配 1 行"), true)
        @Assert(result.content.contains("2: beta"), true)  // 行号
    }

    @TestCase
    public func testSingleFileNoMatch(): Unit {
        let path = this.dir + "/nomatch.txt"
        writeTextFile(path, "alpha\nbeta\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("zzz"))
        args.put("path", JsonString(path))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("未找到"), true)
    }

    @TestCase
    public func testRegexMetaChars(): Unit {
        // 正则语义：a.c 匹配 abc（. 是任意字符）
        let path = this.dir + "/regex.txt"
        writeTextFile(path, "abc\naxc\nadc\nxyz\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("a.c"))
        args.put("path", JsonString(path))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("匹配 3 行"), true)
    }

    @TestCase
    public func testDirectoryRecursive(): Unit {
        let sub = this.dir + "/sub"
        Directory.create(sub, recursive: true)
        writeTextFile(this.dir + "/root.txt", "needle in root\n")
        writeTextFile(sub + "/nested.txt", "needle in nested\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("needle"))
        args.put("path", JsonString(this.dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("2 个文件"), true)
        @Assert(result.content.contains("nested.txt"), true)
        @Assert(result.content.contains("root.txt"), true)
    }

    @TestCase
    public func testContextLines(): Unit {
        let path = this.dir + "/ctx.txt"
        writeTextFile(path, "l1\nl2\nl3\nl4\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("l3"))
        args.put("path", JsonString(path))
        args.put("context", JsonInt(1))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("3: l3"), true)
        @Assert(result.content.contains("2- l2"), true)  // 前 1 行
        @Assert(result.content.contains("4- l4"), true)  // 后 1 行
    }

    @TestCase
    public func testNonexistentPath(): Unit {
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("x"))
        args.put("path", JsonString(this.dir + "/nope"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testMissingParams(): Unit {
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("x"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }
}
