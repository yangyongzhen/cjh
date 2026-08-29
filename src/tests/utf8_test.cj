package cjh.tests

import std.collection.*
import cjutil.*

/**
 * cjutil UTF-8 基础设施测试：容错解码、字节安全截断
 */
@Test
public class Utf8UtilTest {

    @TestCase
    public func testSafeFromUtf8Ascii(): Unit {
        @Assert(safeFromUtf8("hello".toArray()), "hello")
    }

    @TestCase
    public func testSafeFromUtf8Chinese(): Unit {
        @Assert(safeFromUtf8("你好".toArray()), "你好")
    }

    @TestCase
    public func testSafeFromUtf8InvalidByteReplaced(): Unit {
        // 0xFF 非法字节 → U+FFFD 替换，不抛异常
        var bytes = ArrayList<Byte>()
        bytes.add(0x41u8)   // A
        bytes.add(0xFFu8)   // 非法
        bytes.add(0x42u8)   // B
        let result = safeFromUtf8(bytes.toArray())
        @Assert(result.contains("A"), true)
        @Assert(result.contains("B"), true)
        @Assert(result.contains("\u{FFFD}"), true)
    }

    @TestCase
    public func testSafeFromUtf8TruncatedSequence(): Unit {
        // 多字节序列被切断（2 字节序列只有首字节）→ 替换
        var bytes = ArrayList<Byte>()
        bytes.add(0xE4u8)   // 中文首字节，缺后续字节
        bytes.add(0x41u8)   // A
        let result = safeFromUtf8(bytes.toArray())
        @Assert(result.contains("\u{FFFD}"), true)
        @Assert(result.contains("A"), true)
    }

    @TestCase
    public func testTruncateUtf8Ascii(): Unit {
        @Assert(truncateUtf8("hello world", 5), "hello")
    }

    @TestCase
    public func testTruncateUtf8ChineseBoundary(): Unit {
        // "你好" 是 6 字节；截 5 字节必须回退到合法边界（"你" 3 字节）
        let text = "你好"
        @Assert(truncateUtf8(text, 5), "你")
        @Assert(truncateUtf8(text, 6), "你好")
    }

    @TestCase
    public func testTruncateUtf8NoTruncation(): Unit {
        @Assert(truncateUtf8("abc", 10), "abc")
    }

    @TestCase
    public func testTruncateUtf8Zero(): Unit {
        @Assert(truncateUtf8("abc", 0), "")
    }

    @TestCase
    public func testTailUtf8Chinese(): Unit {
        let text = "你好世界"  // 12 字节（每字 3 字节）
        // 取末尾 4 字节 → 装不下"世界"（6 字节），回退到"界"（3 字节）
        @Assert(tailUtf8(text, 4), "界")
        // 取末尾 6 字节 → 恰好"世界"
        @Assert(tailUtf8(text, 6), "世界")
    }

    @TestCase
    public func testTailUtf8Full(): Unit {
        @Assert(tailUtf8("abc", 100), "abc")
    }
}
