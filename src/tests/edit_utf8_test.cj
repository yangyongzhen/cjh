package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * EditTool UTF-8 与更多边界测试
 *
 * 回归重点：replaceString 曾把 Byte 当十进制整数输出（把文件毁成数字串），
 * 修复后必须保证多字节 UTF-8 内容（中文/emoji）替换无损。
 */
@Test
public class EditToolUtf8Test {
    private let dir: String = testTempDir("editutf8")

    private func runEdit(path: String, oldS: String, newS: String): ToolResult {
        return this.runEdit(path, oldS, newS, false)
    }

    private func runEdit(path: String, oldS: String, newS: String, replaceAll: Bool): ToolResult {
        let tool = EditTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString(oldS))
        args.put("new_string", JsonString(newS))
        if (replaceAll) {
            args.put("replace_all", JsonBool(true))
        }
        return tool.execute(args)
    }

    @TestCase
    public func testChineseReplace(): Unit {
        let path = this.dir + "/cn.txt"
        writeTextFile(path, "你好世界\n再见\n")
        let result = this.runEdit(path, "你好", "您好")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "您好世界\n再见\n")
    }

    @TestCase
    public func testChineseReplaceAll(): Unit {
        let path = this.dir + "/cn_all.txt"
        writeTextFile(path, "苹果和苹果\n")
        let result = this.runEdit(path, "苹果", "橙子", true)
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "橙子和橙子\n")
    }

    @TestCase
    public func testEmojiReplace(): Unit {
        // 4 字节 UTF-8（emoji）替换
        let path = this.dir + "/emoji.txt"
        writeTextFile(path, "happy 😀 day\n")
        let result = this.runEdit(path, "😀", "😎")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "happy 😎 day\n")
    }

    @TestCase
    public func testChineseNoMatchKeepsFile(): Unit {
        let path = this.dir + "/cn_nomatch.txt"
        writeTextFile(path, "原始内容\n")
        let result = this.runEdit(path, "不存在", "X")
        @Assert(result.isError, true)
        @Assert(readTextFile(path), "原始内容\n")
    }

    @TestCase
    public func testMultilineWithChinese(): Unit {
        let path = this.dir + "/cn_multi.txt"
        writeTextFile(path, "第一行\n第二行\n第三行\n")
        let result = this.runEdit(path, "第一行\n第二行", "甲\n乙")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "甲\n乙\n第三行\n")
    }

    @TestCase
    public func testReplacePreservesRest(): Unit {
        // 替换中间片段：前后内容完整保留（回归：整段切片替换正确性）
        let path = this.dir + "/mid.txt"
        writeTextFile(path, "AAA\nBBB\nCCC\n")
        let result = this.runEdit(path, "BBB", "DDD")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "AAA\nDDD\nCCC\n")
    }

    @TestCase
    public func testNonAsciiInOldStringMatchesExact(): Unit {
        // 含中文的 old_string 必须精确匹配（UTF-8 字节序列一致）
        let path = this.dir + "/exact.txt"
        writeTextFile(path, "配置项 = 100\n")
        let result = this.runEdit(path, "配置项 = 100", "配置项 = 200")
        @Assert(result.isError, false)
        @Assert(readTextFile(path), "配置项 = 200\n")
    }
}
