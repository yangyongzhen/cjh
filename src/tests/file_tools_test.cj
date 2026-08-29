package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * WriteTool / AppendFileTool 单元测试
 *
 * 重点验证：
 * - 写入/覆盖/追加基本语义
 * - isAsciiDigitGarbage 幻觉防护（LLM 把文本转 ASCII 码值的垃圾内容必须拒绝）
 * - 超长内容软约束（写入成功 + 警告）
 */
@Test
public class FileWriteToolsTest {
    private let dir: String = testTempDir("filewrite")

    @TestCase
    public func testWriteNewFile(): Unit {
        let path = this.dir + "/new.txt"
        let tool = WriteTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("line1\nline2\n"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "line1\nline2\n")
    }

    @TestCase
    public func testOverwriteExisting(): Unit {
        let path = this.dir + "/overwrite.txt"
        writeTextFile(path, "old content\n")
        let tool = WriteTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("new content\n"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "new content\n")
    }

    @TestCase
    public func testMissingContentParam(): Unit {
        let tool = WriteTool()
        var args = JsonObject()
        args.put("path", JsonString(this.dir + "/x.txt"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testAsciiDigitGarbageRejected(): Unit {
        // 200 个纯数字、无换行 → 幻觉产物，必须拒绝
        let tool = WriteTool()
        var args = JsonObject()
        args.put("path", JsonString(this.dir + "/garbage.txt"))
        args.put("content", JsonString(repeatStr("1234567890", 20)))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("ASCII"), true)
    }

    @TestCase
    public func testLargeContentWrittenWithWarning(): Unit {
        // 超 4000 字符：软约束——写入成功 + 警告（不阻断，截断风险提示）
        let path = this.dir + "/large.txt"
        let tool = WriteTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString(repeatStr("x", 5000)))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("WARNING"), true)
        @Assert(readTextFile(path).size, Int64(5000))
    }

    @TestCase
    public func testAppendToExisting(): Unit {
        let path = this.dir + "/append.txt"
        writeTextFile(path, "part1\n")
        let tool = AppendFileTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("part2\n"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "part1\npart2\n")
    }

    @TestCase
    public func testAppendMissingFileFails(): Unit {
        let tool = AppendFileTool()
        var args = JsonObject()
        args.put("path", JsonString(this.dir + "/missing.txt"))
        args.put("content", JsonString("data"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testAppendDigitGarbageRejected(): Unit {
        let path = this.dir + "/append_garbage.txt"
        writeTextFile(path, "ok\n")
        let tool = AppendFileTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString(repeatStr("1111111111", 15)))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        // 原文件不被污染
        @Assert(readTextFile(path), "ok\n")
    }
}
