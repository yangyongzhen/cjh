package cjh.tests

import std.fs.*
import cjh.agent.*

/**
 * ToolResultTruncator 单元测试（从 Agent 私有方法提取后可直接测）
 *
 * 覆盖：差异化阈值、头尾保留、省略标记、spill 落盘、UTF-8 安全、不截断路径
 */
@Test
public class TruncatorTest {

    @TestCase
    public func testMaxCharsPerTool(): Unit {
        @Assert(ToolResultTruncator.maxChars("bash", 6000), 2000)
        @Assert(ToolResultTruncator.maxChars("list_dir", 6000), 4000)
        @Assert(ToolResultTruncator.maxChars("read_file", 6000), Int64.Max)
        @Assert(ToolResultTruncator.maxChars("grep", 6000), 6000)          // 默认
        @Assert(ToolResultTruncator.maxChars("write_file", 6000), 6000)    // 默认
        @Assert(ToolResultTruncator.maxChars("bash", 0), Int64.Max)        // 全局禁用
        @Assert(ToolResultTruncator.maxChars("bash", -5), Int64.Max)       // 负数禁用
    }

    @TestCase
    public func testShortContentNotTruncated(): Unit {
        let result = ToolResultTruncator.truncate("hello", "bash", 6000, "", "", "c1")
        @Assert(result, "hello")
    }

    @TestCase
    public func testLongContentHeadTail(): Unit {
        // 100 字符 bash 结果（阈值 2000 不触发——用默认工具阈值 20 验证头尾）
        let content = repeatStr("abcdefghij", 10)  // 100 字符
        let result = ToolResultTruncator.truncate(content, "write_file", 20, "", "", "c2")
        @Assert(result.contains("已截断 80 字符"), true)
        // 头尾保留：前 10 字符 + 后 10 字符（maxChars=20, head=10, tail=10）
        @Assert(result.startsWith("abcdefghij"), true)
        @Assert(result.endsWith("abcdefghij"), true)
        // 中间被省略
        @Assert(result.contains("…[已截断"), true)
    }

    @TestCase
    public func testBashThreshold2000(): Unit {
        let content = repeatStr("x", 2500)
        let result = ToolResultTruncator.truncate(content, "bash", 6000, "", "", "c3")
        @Assert(result.contains("已截断 500 字符"), true)
    }

    @TestCase
    public func testReadFileNeverTruncated(): Unit {
        let content = repeatStr("x", 10000)
        let result = ToolResultTruncator.truncate(content, "read_file", 6000, "", "", "c4")
        @Assert(result, content)
    }

    @TestCase
    public func testSpillWritten(): Unit {
        let spillDir = testTempDir("truncspill")
        let content = repeatStr("y", 3000)
        let result = ToolResultTruncator.truncate(content, "bash", 6000, spillDir, "sess1", "call_9")
        @Assert(result.contains("完整结果已保存"), true)
        @Assert(result.contains(spillDir + "/sess1/call_9.txt"), true)
        // 落盘完整内容
        @Assert(exists(spillDir + "/sess1/call_9.txt"), true)
        @Assert(readTextFile(spillDir + "/sess1/call_9.txt"), content)
    }

    @TestCase
    public func testNoSpillWhenDirEmpty(): Unit {
        let content = repeatStr("z", 3000)
        let result = ToolResultTruncator.truncate(content, "bash", 6000, "", "", "c5")
        @Assert(result.contains("完整结果已保存"), false)
    }

    @TestCase
    public func testChineseContentUtf8Safe(): Unit {
        // 中文每字 1 个 Rune：截断按字符计，不破坏多字节 UTF-8
        let content = repeatStr("你好世界", 50)  // 200 个中文字符
        let result = ToolResultTruncator.truncate(content, "write_file", 100, "", "", "c6")
        @Assert(result.contains("已截断 100 字符"), true)
        // 头尾各 50 个中文字符，均完整（无 U+FFFD 替换符）
        @Assert(result.contains("\u{FFFD}"), false)
        @Assert(result.startsWith("你好世界"), true)
        @Assert(result.endsWith("你好世界"), true)
    }

    @TestCase
    public func testExactThresholdNotTruncated(): Unit {
        let content = repeatStr("a", 2000)  // 恰等于 bash 阈值
        let result = ToolResultTruncator.truncate(content, "bash", 6000, "", "", "c7")
        @Assert(result, content)
    }
}
