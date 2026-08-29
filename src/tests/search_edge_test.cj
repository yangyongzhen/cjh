package cjh.tests

import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * GrepTool / GlobTool / ListDirTool 边界测试
 *
 * 重点回归：Directory.walk 非递归 + false 终止遍历的修复——
 * 目录树中混有忽略目录（如 .git）时，搜索必须继续而非提前终止。
 */
@Test
public class SearchToolsEdgeTest {

    @TestCase
    public func testGrepInvalidRegex(): Unit {
        let dir = testTempDir("grepregex")
        writeTextFile(dir + "/f.txt", "abc\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("["))  // 非法正则
        args.put("path", JsonString(dir + "/f.txt"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testGrepEmptyPattern(): Unit {
        let dir = testTempDir("grepempty")
        writeTextFile(dir + "/f.txt", "abc\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString(""))
        args.put("path", JsonString(dir + "/f.txt"))
        let result = tool.execute(args)
        // 空正则匹配所有行（std.regex 语义），不崩溃即可
        @Assert(result.isError, false)
    }

    @TestCase
    public func testGrepDirWithGitDirContinues(): Unit {
        // 回归：目录中含 .git 子目录时，搜索必须继续（原实现 return false 终止整个 walk）
        let dir = testTempDir("grepgit")
        Directory.create(dir + "/.git", recursive: true)
        writeTextFile(dir + "/.git/config", "needle in git\n")
        writeTextFile(dir + "/src.txt", "needle in src\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("needle"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("src.txt"), true)     // 正常文件被搜到
        @Assert(result.content.contains(".git"), false)       // .git 被跳过
    }

    @TestCase
    public func testGrepDirNestedSubdirs(): Unit {
        // 深层嵌套子目录内容也能搜到（显式递归修复的回归）
        let dir = testTempDir("grepdeep")
        Directory.create(dir + "/a/b/c", recursive: true)
        writeTextFile(dir + "/a/b/c/deep.txt", "needle deep\n")
        let tool = GrepTool()
        var args = JsonObject()
        args.put("pattern", JsonString("needle"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("deep.txt"), true)
    }

    @TestCase
    public func testGlobDeepNested(): Unit {
        let dir = testTempDir("globdeep")
        Directory.create(dir + "/x/y/z", recursive: true)
        writeTextFile(dir + "/x/y/z/deep.txt", "d\n")
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString("**/*.txt"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("deep.txt"), true)
    }

    @TestCase
    public func testGlobIgnoresTargetDir(): Unit {
        // target 目录被忽略：glob ** 不应匹配 target 内文件
        let dir = testTempDir("globtarget")
        Directory.create(dir + "/target", recursive: true)
        writeTextFile(dir + "/target/out.txt", "x\n")
        writeTextFile(dir + "/keep.txt", "y\n")
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString("**/*.txt"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("keep.txt"), true)
        @Assert(result.content.contains("target"), false)
    }

    @TestCase
    public func testGlobEmptyDir(): Unit {
        let dir = testTempDir("globempty")
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString("**/*.txt"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("没有文件匹配"), true)
    }

    @TestCase
    public func testListDirEmptyDir(): Unit {
        let dir = testTempDir("listempty")
        let tool = ListDirTool()
        var args = JsonObject()
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("0 项"), true)
    }

    @TestCase
    public func testGlobPatternWithStarDirPrefix(): Unit {
        // "*/sub/*.txt"：星号匹配一层目录
        let dir = testTempDir("globstar2")
        Directory.create(dir + "/d1/sub", recursive: true)
        Directory.create(dir + "/d2/sub", recursive: true)
        writeTextFile(dir + "/d1/sub/a.txt", "a\n")
        writeTextFile(dir + "/d2/sub/b.txt", "b\n")
        writeTextFile(dir + "/d2/c.txt", "c\n")  // 不匹配
        let tool = GlobTool()
        var args = JsonObject()
        args.put("pattern", JsonString("*/sub/*.txt"))
        args.put("path", JsonString(dir))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("d1/sub/a.txt"), true)
        @Assert(result.content.contains("d2/sub/b.txt"), true)
        @Assert(result.content.contains("d2/c.txt"), false)
    }
}
