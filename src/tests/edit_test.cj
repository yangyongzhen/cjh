package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * EditTool 单元测试（str_replace 精确替换，omp EditTool 移植）
 *
 * 重点验证安全机制：
 * - old_string 必须唯一（多处匹配拒绝）
 * - replace_all=true 允许全替换
 * - old_string 为空 / old==new 拒绝
 * - 未匹配时给出诊断信息
 * - 多行替换
 */
@Test
public class EditToolTest {
    private let dir: String = testTempDir("edit")

    private func buildArgs(path: String, oldS: String, newS: String): JsonObject {
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString(oldS))
        args.put("new_string", JsonString(newS))
        return args
    }

    @TestCase
    public func testUniqueReplace(): Unit {
        let path = this.dir + "/unique.txt"
        writeTextFile(path, "let x = 1\nlet y = 2\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "let x = 1", "let x = 10"))
        @Assert(result.isError, false)
        @Assert(result.content.contains("替换 1 处"), true)
        @Assert(readTextFile(path), "let x = 10\nlet y = 2\n")
    }

    @TestCase
    public func testReplaceAll(): Unit {
        let path = this.dir + "/all.txt"
        writeTextFile(path, "foo\nbar\nfoo\n")
        let tool = EditTool()
        var args = this.buildArgs(path, "foo", "FOO")
        args.put("replace_all", JsonBool(true))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("替换 2 处"), true)
        @Assert(readTextFile(path), "FOO\nbar\nFOO\n")
    }

    @TestCase
    public func testAmbiguousRejected(): Unit {
        // old_string 出现两次且未设 replace_all → 拒绝
        let path = this.dir + "/ambig.txt"
        writeTextFile(path, "same\nother\nsame\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "same", "X"))
        @Assert(result.isError, true)
        @Assert(result.content.contains("非唯一"), true)
        // 文件未被修改
        @Assert(readTextFile(path), "same\nother\nsame\n")
    }

    @TestCase
    public func testNoMatchDiagnostic(): Unit {
        let path = this.dir + "/nomatch.txt"
        writeTextFile(path, "hello world\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "goodbye", "X"))
        @Assert(result.isError, true)
        @Assert(result.content.contains("未找到"), true)
    }

    @TestCase
    public func testEmptyOldStringRejected(): Unit {
        let path = this.dir + "/empty.txt"
        writeTextFile(path, "content\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "", "X"))
        @Assert(result.isError, true)
    }

    @TestCase
    public func testSameOldNewRejected(): Unit {
        let path = this.dir + "/same.txt"
        writeTextFile(path, "content\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "content", "content"))
        @Assert(result.isError, true)
    }

    @TestCase
    public func testMultilineReplace(): Unit {
        let path = this.dir + "/multi.txt"
        writeTextFile(path, "line1\nline2\nline3\n")
        let tool = EditTool()
        let result = tool.execute(this.buildArgs(path, "line1\nline2", "A\nB"))
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "A\nB\nline3\n")
    }

    @TestCase
    public func testMissingParamRejected(): Unit {
        let tool = EditTool()
        var args = JsonObject()
        args.put("path", JsonString(this.dir + "/x.txt"))
        args.put("old_string", JsonString("a"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }
}
