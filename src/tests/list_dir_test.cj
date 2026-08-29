package cjh.tests

import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * ListDirTool 单元测试：目录列出、50 项截断提示、错误路径
 */
@Test
public class ListDirToolTest {

    @TestCase
    public func testListContents(): Unit {
        let dir = testTempDir("listdir")
        writeTextFile(dir + "/a.txt", "a\n")
        writeTextFile(dir + "/b.txt", "b\n")
        Directory.create(dir + "/subdir", recursive: true)
        let tool = ListDirTool()
        var args = JsonObject()
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("a.txt"), true)
        @Assert(result.content.contains("b.txt"), true)
        @Assert(result.content.contains("subdir/"), true)  // 目录带 /
    }

    @TestCase
    public func testNonexistentPath(): Unit {
        let tool = ListDirTool()
        var args = JsonObject()
        args.put("path", JsonString("/tmp/cjh_ut_nonexistent_dir_xyz"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testMissingPathParam(): Unit {
        let tool = ListDirTool()
        var args = JsonObject()
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testTruncationOver50(): Unit {
        let dir = testTempDir("listdir50")
        for (i in 0..60) {
            writeTextFile(dir + "/f${i}.txt", "x\n")
        }
        let tool = ListDirTool()
        var args = JsonObject()
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("共 60 项"), true)
        @Assert(result.content.contains("仅显示前 50"), true)
    }
}
