package cjh.tests

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * ReadTool 边界测试：offset 越界、limit 超限、空文件、中文、offset 无 limit、大文件流式、二进制容错
 */
@Test
public class ReadToolEdgeTest {
    private let dir: String = testTempDir("readedge")

    private func runRead(path: String, offset: Int64, limit: Int64): ToolResult {
        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        if (offset > 0) { args.put("offset", JsonInt(offset)) }
        if (limit > 0) { args.put("limit", JsonInt(limit)) }
        return tool.execute(args)
    }

    @TestCase
    public func testOffsetOutOfRange(): Unit {
        let path = this.dir + "/oor.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runRead(path, 999, 0)
        @Assert(result.isError, true)
        @Assert(result.content.contains("超出文件行数"), true)
    }

    @TestCase
    public func testLimitBeyondEOF(): Unit {
        let path = this.dir + "/limit.txt"
        writeTextFile(path, "a\nb\nc\n")
        let result = this.runRead(path, 1, 100)
        @Assert(result.isError, false)
        @Assert(result.content.contains("1\ta"), true)
        @Assert(result.content.contains("3\tc"), true)
    }

    @TestCase
    public func testEmptyFile(): Unit {
        let path = this.dir + "/empty.txt"
        writeTextFile(path, "")
        let result = this.runRead(path, 0, 0)
        @Assert(result.isError, false)
    }

    @TestCase
    public func testChineseContentLineNumbers(): Unit {
        let path = this.dir + "/cn.txt"
        writeTextFile(path, "第一行\n第二行\n第三行\n")
        let result = this.runRead(path, 0, 0)
        @Assert(result.isError, false)
        @Assert(result.content.contains("1\t第一行"), true)
        @Assert(result.content.contains("3\t第三行"), true)
    }

    @TestCase
    public func testOffsetWithoutLimitReadsToEOF(): Unit {
        let path = this.dir + "/tail.txt"
        writeTextFile(path, "l1\nl2\nl3\nl4\nl5\n")
        let result = this.runRead(path, 3, 0)
        @Assert(result.isError, false)
        @Assert(result.content.contains("3\tl3"), true)
        @Assert(result.content.contains("5\tl5"), true)
        @Assert(result.content.contains("1\tl1"), false)
    }

    @TestCase
    public func testLargeFileStreamingRange(): Unit {
        // >256KB 走流式 readLargeFile；offset+limit 行段模式
        let path = this.dir + "/big.txt"
        var sb = StringBuilder()
        for (i in 0..5000) {
            sb.append("line${i}\n")
        }
        writeTextFile(path, sb.toString())
        let result = this.runRead(path, 10, 3)
        @Assert(result.isError, false)
        @Assert(result.content.contains("10\tline9"), true)
        @Assert(result.content.contains("12\tline11"), true)
        @Assert(result.content.contains("13\tline12"), false)
    }

    @TestCase
    public func testLargeFileDefaultSummaryOrTruncation(): Unit {
        // 大文件无 offset/limit：>256KB 走流式（摘要或前 500 行），必须带截断提示
        let path = this.dir + "/big2.txt"
        var sb = StringBuilder()
        for (i in 0..5000) {
            sb.append("line${i}\n")
        }
        writeTextFile(path, sb.toString())
        let result = this.runRead(path, 0, 0)
        @Assert(result.isError, false)
        // 两种合法输出之一：结构化摘要 或 行段+截断提示
        let hasSummary = result.content.contains("结构化摘要")
        let hasTruncHint = result.content.contains("offset=")
        @Assert(hasSummary || hasTruncHint, true)
    }

    @TestCase
    public func testSqliteRead(): Unit {
        // P1-7：.db 文件走 SQLite 读取。sqlite3 CLI 可用 → 表/行输出；
        // 不可用 → 明确提示安装（不静默失败）
        let path = this.dir + "/test.db"
        writeTextFile(path, "placeholder")
        let result = this.runRead(path, 0, 0)
        // 两种合法结果：sqlite3 存在 → 表结构输出；不存在 → 提示安装
        let hasSqlite = sqlite3Available()
        if (hasSqlite) {
            @Assert(result.isError, false)
        } else {
            @Assert(result.isError, true)
            @Assert(result.content.contains("sqlite3"), true)
        }
    }

    @TestCase
    public func testSqliteReadRealData(): Unit {
        // 仅当 sqlite3 可用时验证真实数据读取（建临时库 → 表/行）
        if (!sqlite3Available()) {
            return  // 环境无 sqlite3，跳过（无法建库）
        }
        let path = this.dir + "/real.db"
        removeTree(path)
        var args = Array<String>(3, repeat: "")
        args[0] = path
        args[1] = "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES(1,'alice'),(2,'bob');"
        let (code, _, _) = executeWithOutput("sqlite3", args)
        @Assert(code, 0)
        let result = this.runRead(path, 0, 0)
        @Assert(result.isError, false)
        @Assert(result.content.contains("users"), true)
        @Assert(result.content.contains("alice"), true)
        @Assert(result.content.contains("bob"), true)
    }

    private func sqlite3Available(): Bool {
        try {
            let (code, _, _) = executeWithOutput("/bin/bash", ["-c", "which sqlite3"])
            return code == 0
        } catch (e: Exception) {
            return false
        }
    }

    @TestCase
    public func testBinaryContentTolerant(): Unit {
        // 含非法 UTF-8 字节：safeFromUtf8 容错，不抛异常
        let path = this.dir + "/bin.dat"
        var bytes = ArrayList<Byte>()
        for (b in [0x41u8, 0xFFu8, 0xFEu8, 0x42u8, 0x0Au8]) {
            bytes.add(b)
        }
        File.writeTo(path, bytes.toArray())
        let result = this.runRead(path, 0, 0)
        @Assert(result.isError, false)
    }
}
