package cjh.tests

import std.collection.*
import cjterm.*

/**
 * bracketed paste 解码单元测试（回归：粘贴中文乱码）
 *
 * 根因：旧 readBracketedPaste 逐字节 Rune(Int32(byte)) 拼接，把中文 UTF-8
 * 字节当独立 Latin-1 码点（"好"=E5 A5 BD → "å¥½"），与 §3.15 bash 输出乱码
 * 同款。修复后字节累积 + safeFromUtf8 整段解码 + 字节层结束标记剥离。
 *
 * 直调 PosixTerminalBackend 的 public static 解码原语（纯函数，无 I/O）：
 *  - decodePaste(raw, dropTail)：UTF-8 解码 + ESC 序列剥离
 *  - endsWithBytes(raw, suffix)：字节层结束标记匹配
 *  - stripEscapeSequences(s)：控制序列剥离
 * 端到端（stdin 读 + 闭合标记）由 scripts/tui_pty_test.py 的 bracketed
 * paste 场景覆盖。
 */
@Test
public class TermPasteDecodeTest {

    /** 字符串 → 字节 ArrayList（测试辅助） */
    private static func toBytes(s: String): ArrayList<Byte> {
        var list = ArrayList<Byte>(0)
        let arr = s.toArray()
        for (i in 0..arr.size) {
            list.add(arr[i])
        }
        return list
    }

    /** 中文粘贴正确解码（主路径）："好"=E5 A5 BD 三字节须合成一个码点 */
    @TestCase
    public func testChineseDecode(): Unit {
        let raw = toBytes("中文测试")
        let out = PosixTerminalBackend.decodePaste(raw, 0)
        @Assert(out, "中文测试")
        // 旧逐字节实现的产物（乱码）绝不能出现
        @Assert(out.contains("å"), false)
    }

    /** emoji（4 字节）+ 中文混合解码 */
    @TestCase
    public func testEmojiAndChineseMix(): Unit {
        let raw = toBytes("测试🚀")
        let out = PosixTerminalBackend.decodePaste(raw, 0)
        @Assert(out, "测试🚀")
    }

    /** ASCII 粘贴不受影响（主路径回归） */
    @TestCase
    public func testAsciiDecode(): Unit {
        let raw = toBytes("git status && ls")
        @Assert(PosixTerminalBackend.decodePaste(raw, 0), "git status && ls")
    }

    /** 结束标记剥离：尾部 ESC[201~ 不进入粘贴体 */
    @TestCase
    public func testEndMarkerStripped(): Unit {
        // 模拟已读入 "好" + 结束标记字节，dropTail 去掉标记
        let marker = (TermEsc.ESC + "[201~").toArray()
        let raw = toBytes("好" + String.fromUtf8(marker))
        @Assert(PosixTerminalBackend.endsWithBytes(raw, marker), true)
        let out = PosixTerminalBackend.decodePaste(raw, marker.size)
        @Assert(out, "好")
    }

    /** 非法字节容错：FF 是非法 UTF-8 首字节 → U+FFFD 替换，不抛异常 */
    @TestCase
    public func testInvalidByteFallback(): Unit {
        // "好" + 0xFF（非法）+ 'a'
        let good = "好".toArray()
        var raw = ArrayList<Byte>(0)
        for (i in 0..good.size) {
            raw.add(good[i])
        }
        raw.add(0xFFu8)
        raw.add(0x61u8)
        let out = PosixTerminalBackend.decodePaste(raw, 0)
        @Assert(out.contains("好"), true)
        @Assert(out.contains("a"), true)
        // 非法字节被替换为 U+FFFD（不崩溃、不产生 Latin-1 乱码）
        @Assert(out.contains("\u{FFFD}"), true)
    }

    /** ESC 序列剥离：方向键 CSI 序列不污染粘贴文本 */
    @TestCase
    public func testEscapeSequenceStripped(): Unit {
        // "ab" + ESC[D（左方向键 CSI）+ "cd"
        let s = "ab" + TermEsc.ESC + "[D" + "cd"
        @Assert(PosixTerminalBackend.stripEscapeSequences(s), "abcd")
        // 颜色序列 ESC[31m 同样剥离
        let sgr = "x" + TermEsc.ESC + "[31m" + "y"
        @Assert(PosixTerminalBackend.stripEscapeSequences(sgr), "xy")
    }

    /** 边界：dropTail 等于全长 → 空串；空输入 → 空串 */
    @TestCase
    public func testEmptyAndFullDrop(): Unit {
        let raw = toBytes("好")
        @Assert(PosixTerminalBackend.decodePaste(raw, raw.size), "")
        let empty = ArrayList<Byte>(0)
        @Assert(PosixTerminalBackend.decodePaste(empty, 0), "")
    }

    /** endsWithBytes 边界：内容短于 suffix / 不匹配 / 空输入 */
    @TestCase
    public func testEndsWithBytesEdges(): Unit {
        let marker = (TermEsc.ESC + "[201~").toArray()
        @Assert(PosixTerminalBackend.endsWithBytes(toBytes("ab"), marker), false)
        @Assert(PosixTerminalBackend.endsWithBytes(toBytes("ab" + String.fromUtf8(marker)), marker), true)
        @Assert(PosixTerminalBackend.endsWithBytes(ArrayList<Byte>(0), marker), false)
    }
}
