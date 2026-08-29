package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * HashlineEditTool 更多场景测试：同锚点多操作、CRLF、单行文件、哈希碰撞拒绝
 */
@Test
public class HashlineEditMoreTest {
    private let dir: String = testTempDir("hashline2")

    private func runPatch(path: String, patch: String): ToolResult {
        let tool = HashlineEditTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("patch", JsonString(patch))
        return tool.execute(args)
    }

    @TestCase
    public func testMultipleInsertsSameAnchor(): Unit {
        let path = this.dir + "/multi_ins.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@1\n+x\n+y")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nx\ny\nb\nc\n")
    }

    @TestCase
    public func testInsertThenDeleteSameBlock(): Unit {
        // 同锚点块：插入后删除锚点行（lines[lineIdx] 仍是锚点行）
        let path = this.dir + "/ins_del.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2\n+x\n-b")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nx\nc\n")
    }

    @TestCase
    public func testReplaceThenInsert(): Unit {
        let path = this.dir + "/rep_ins.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runPatch(path, "@@2\n-b\n+B\n+z")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nB\nz\nc\n")
    }

    @TestCase
    public func testSingleLineNoTrailingNewline(): Unit {
        // 单行文件无结尾换行：split("\n", -1) 得 [content]
        let path = this.dir + "/single.txt"
        writeTextFile(path, "only")
        let result = this.runPatch(path, "@@1\n-only\n+ONLY")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "ONLY")
    }

    @TestCase
    public func testEmptyFileRejected(): Unit {
        let path = this.dir + "/empty.txt"
        writeTextFile(path, "")
        // 空文件 split 得空数组（0 行）→ @@1 行号越界拒绝（合理防御，无法锚定空文件）
        let result = this.runPatch(path, "@@1\n+x")
        @Assert(result.isError, true)
        @Assert(result.content.contains("超出范围"), true)
    }

    @TestCase
    public func testCrlfLineReplacement(): Unit {
        // CRLF 文件：split("\n") 后行尾带 \r，-old 必须含 \r 才能匹配
        let path = this.dir + "/crlf.txt"
        writeTextFile(path, "a\r\nb\r\nc\r\n")
        let result = this.runPatch(path, "@@2\n-b\r\n+B\r\n")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\r\nB\r\nc\r\n")
    }

    @TestCase
    public func testCrlfMismatchRejected(): Unit {
        // CRLF 文件用不含 \r 的 -old → 拒绝（防换行符不一致误改）
        let path = this.dir + "/crlf2.txt"
        writeTextFile(path, "a\r\nb\r\n")
        let result = this.runPatch(path, "@@2\n-b")
        @Assert(result.isError, true)
    }

    @TestCase
    public func testHashAnchorCollisionRejected(): Unit {
        // 构造两个哈希相同（低 16 位碰撞）的行 → 拒绝
        let path = this.dir + "/collision.txt"
        // 用暴力找 16 位碰撞行不现实，直接验证 locate 语义：
        // 同一内容两行 → 哈希相同 → 碰撞拒绝
        writeTextFile(path, "same\nsame\n")
        let hash = HashlineHash.hashLine("same")
        let result = this.runPatch(path, "@@{" + hash + "}\n-x")
        @Assert(result.isError, true)
        @Assert(result.content.contains("碰撞"), true)
    }

    @TestCase
    public func testDeleteTwoLinesSameBlock(): Unit {
        // 同锚点连续两个 -old：第二个删除会校验 next 行——构造不同内容使之一致
        let path = this.dir + "/del2.txt"
        writeTextFile(path, "a\nb\nb\nc\n")
        // @@2 定位 b，删除后 lines[1] 是下一个 b → 第二个 -b 匹配
        let result = this.runPatch(path, "@@2\n-b\n-b")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nc\n")
    }

    @TestCase
    public func testContentGuardWithInsertedOffset(): Unit {
        // 内容校验 + 偏移结合：前序插入后，@@3 定位原始第 3 行（c），-c 校验 +C 替换
        let path = this.dir + "/guard_offset.txt"
        writeTextFile(path, "a\nb\nc\nd\n")
        let result = this.runPatch(path, "@@1\n+x\n@@3\n-c\n+C")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "a\nx\nb\nC\nd\n")
    }
}
