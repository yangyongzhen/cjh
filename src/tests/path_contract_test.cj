package cjh.tests

import std.env.*
import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*
import cjllm.*
import cjcfg.*

/**
 * P0 路径契约：文件工具一律按工作区根解析相对路径，并在结果中回显绝对路径。
 * 与 bash 会话的 cwd 解耦（bash `cd` 不会改变文件工具的解释基准）。
 */
@Test
public class PathContractTest {
    @TestCase
    public func testResolveFilePathIsLexicalAndRooted(): Unit {
        let root = getWorkingDirectory().toString()
        @Assert(resolveFilePath("src/main.cj"), root + "/src/main.cj")
        @Assert(resolveFilePath("./src/../src/main.cj"), root + "/src/main.cj")
        @Assert(resolveFilePath(root + "/src/main.cj"), root + "/src/main.cj")
        @Assert(resolveFilePath("//tmp//x/../y"), "/tmp/y")
    }

    @TestCase
    public func testReadRelativePathEchoesResolvedAbsolutePath(): Unit {
        let root = getWorkingDirectory().toString()
        var args = JsonObject()
        args.put("path", JsonString("src/main.cj"))
        args.put("limit", JsonString("5"))
        let result = ReadTool().execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.startsWith("[path] " + root + "/src/main.cj\n"), true)
        @Assert(result.content.contains("\t"), true)
    }

    @TestCase
    public func testReadAbsolutePathDoesNotRepeatNotice(): Unit {
        let root = getWorkingDirectory().toString()
        var args = JsonObject()
        args.put("path", JsonString(root + "/src/main.cj"))
        args.put("limit", JsonString("5"))
        let result = ReadTool().execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.startsWith("[path]"), false)
    }

    @TestCase
    public func testWriteEditAppendAndHashlineUseAbsolutePath(): Unit {
        let dir = testTempDir("path_contract_tools")
        try {
            let file = dir + "/note.txt"
            var w = JsonObject()
            w.put("path", JsonString(file))
            w.put("content", JsonString("one\ntwo\n"))
            let written = WriteTool().execute(w)
            @Assert(written.isError, false)
            @Assert(written.content.contains(file), true)

            var e = JsonObject()
            e.put("path", JsonString(file))
            e.put("old_string", JsonString("two"))
            e.put("new_string", JsonString("TWO"))
            let edited = EditTool().execute(e)
            @Assert(edited.isError, false)
            @Assert(edited.content.contains(file), true)

            var a = JsonObject()
            a.put("path", JsonString(file))
            a.put("content", JsonString("three\n"))
            let appended = AppendFileTool().execute(a)
            @Assert(appended.isError, false)
            @Assert(readTextFile(file), "one\nTWO\nthree\n")

            // hashline 走同一路径契约：绝对路径写入后按锚点替换
            var h = JsonObject()
            h.put("path", JsonString(file))
            h.put("patch", JsonString("@@1\n-one\n+ONE"))
            let hashed = HashlineEditTool().execute(h)
            @Assert(hashed.isError, false)
            @Assert(readTextFile(file), "ONE\nTWO\nthree\n")
        } finally {
            removeTree(dir)
        }
    }

    @TestCase
    public func testWriteScopeGlobResolvesAgainstRoot(): Unit {
        // task scope 是模型给的相对 glob；守卫侧比较的是绝对路径，必须先解析再匹配。
        @Assert(Capability.globMatch(resolveFilePath("src/*.cj"), resolveFilePath("src/main.cj")), true)
        @Assert(Capability.globMatch(resolveFilePath("src/*.cj"), resolveFilePath("other/main.cj")), false)
    }

    @TestCase
    public func testGlobBaseResolvesAgainstRoot(): Unit {
        let dir = testTempDir("path_contract_glob")
        try {
            File.writeTo(dir + "/a.txt", "a".toArray())
            var args = JsonObject()
            args.put("pattern", JsonString("*.txt"))
            args.put("path", JsonString(dir))
            let result = GlobTool().execute(args)
            @Assert(result.isError, false)
            @Assert(result.content.contains("a.txt"), true)
        } finally {
            removeTree(dir)
        }
    }
}
