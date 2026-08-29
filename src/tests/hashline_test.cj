package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * HashlineEditTool 单元测试（行号锚点 + 内容验证的补丁编辑）
 *
 * 重点验证：
 * - 替换/插入/删除行
 * - 内容验证（@@N content / -old）不匹配拒绝（防打错地方）
 * - 行号越界拒绝
 * - **多锚点行号偏移回归**：前序锚点 Insert 后，后续 @@N 必须按偏移定位
 *   （修复前：插入后 @@4 错误定位到原第 3 行，内容校验必然误拒）
 */
@Test
public class HashlineEditToolTest {
    private let dir: String = testTempDir("hashline")

    private func runPatch(path: String, patch: String): ToolResult {
        let tool = HashlineEditTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("patch", JsonString(patch))
        return tool.execute(args)
    }

    @TestCase
    public func testReplaceLine(): Unit {
        let path = this.dir + "/replace.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2\n-b\n+B2")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nB2\nc\n")
    }

    @TestCase
    public func testInsertAfterLine(): Unit {
        let path = this.dir + "/insert.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@1\n+x")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nx\nb\nc\n")
    }

    @TestCase
    public func testDeleteLine(): Unit {
        let path = this.dir + "/delete.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2\n-b")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nc\n")
    }

    @TestCase
    public func testContentGuardMatch(): Unit {
        // @@N content 校验通过 → 应用
        let path = this.dir + "/guard_ok.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2 b\n+b2")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nb\nb2\nc\n")
    }

    @TestCase
    public func testContentGuardMismatchRejected(): Unit {
        // 文件已变（第 2 行不是 "zzz"）→ 拒绝，防打错地方
        let path = this.dir + "/guard_bad.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2 zzz\n+b2")
        @Assert(result.isError, true)
        @Assert(result.content.contains("内容不匹配"), true)
        @Assert(readTextFile(path), "a\nb\nc\n")  // 未修改
    }

    @TestCase
    public func testDeleteMismatchRejected(): Unit {
        let path = this.dir + "/del_mismatch.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@1\n-zzz")
        @Assert(result.isError, true)
        @Assert(readTextFile(path), "a\nb\nc\n")
    }

    @TestCase
    public func testLineOutOfRangeRejected(): Unit {
        let path = this.dir + "/oor.txt"
        writeTextFile(path, "a\nb\n")
        let result = this.runPatch(path, "@@99\n+x")
        @Assert(result.isError, true)
        @Assert(result.content.contains("超出范围"), true)
    }

    @TestCase
    public func testMultiAnchorLineOffsetRegression(): Unit {
        // 回归：@@1 插入一行后，@@4 必须仍指向原始第 4 行（d）
        // 修复前：无偏移校正，@@4 定位到插入后的第 3 行（c），-d 内容校验误拒
        let path = this.dir + "/multi.txt"
        writeTextFile(path, "a\nb\nc\nd\ne\n")
        let result = this.runPatch(path, "@@1\n+x\n@@4\n-d")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nx\nb\nc\ne\n")
    }

    @TestCase
    public func testMultiAnchorReplaceWithOffset(): Unit {
        // 前序锚点删除第 2 行（b）后，@@3 按偏移 -1 定位到原始第 3 行（c）并替换为 C
        let path = this.dir + "/multi2.txt"
        writeTextFile(path, "a\nb\nc\nd\n")
        let result = this.runPatch(path, "@@2\n-b\n@@3\n-c\n+C")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nC\nd\n")
    }

    @TestCase
    public func testHashAnchorBackCompat(): Unit {
        // 哈希锚点（向后兼容）：按内容定位，天然抗行号偏移
        let path = this.dir + "/hash.txt"
        writeTextFile(path, "a\nb\nc\n")
        let hash = HashlineHash.hashLine("b")
        let result = this.runPatch(path, "@@{" + hash + "}\n-b\n+B2")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nB2\nc\n")
    }

    @TestCase
    public func testInvalidPatchNoOps(): Unit {
        let path = this.dir + "/noops.txt"
        writeTextFile(path, "a\nb\n")
        let result = this.runPatch(path, "just some text\n")
        @Assert(result.isError, true)
        @Assert(result.content.contains("无有效操作"), true)
    }
}
