/**
 * 输出折行与状态栏提示单测：长行不再被 canvas 直接截断。
 */
package cjterm

import std.collection.*

@Test
public class WrapAnsiTest {
    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc = false
        for (r in s.toRuneArray()) {
            let ch = r.toString()
            if (ch == "\u{1b}") { inEsc = true; continue }
            if (inEsc) {
                if (ch == "m") { inEsc = false }
                continue
            }
            sb.append(ch)
        }
        return sb.toString()
    }

    @TestCase
    public func testWrapAnsiCjkNoOverflow(): Unit {
        let text = "abc中文def长行内容"
        let segs = TuiCanvas.wrapAnsi(text, 5)
        var joined = ""
        for (s in segs) {
            joined += stripAnsi(s)
            @Assert(TuiCanvas.displayWidth(s) <= 5, true)
        }
        @Assert(joined, text)
    }

    @TestCase
    public func testWrapAnsiPrefersWordBoundary(): Unit {
        // 实机回复出现 "13509.\n05"：数字被硬折劈开。优先在空格处折行后，
        // 完整 token 必须落在同一行内。
        let segs = TuiCanvas.wrapAnsi("金额 13509.05 元", 10)
        var found = false
        for (s in segs) {
            @Assert(TuiCanvas.displayWidth(s) <= 10, true)
            if (stripAnsi(s).contains("13509.05")) {
                found = true
            }
        }
        @Assert(found, true)
    }

    @TestCase
    public func testWrapAnsiLongTokenStillHardBreaks(): Unit {
        // 没有空格可退（超长 token）时不能死循环/溢出，仍按宽度硬折
        let segs = TuiCanvas.wrapAnsi("abcdefghij", 4)
        var joined = ""
        for (s in segs) {
            @Assert(TuiCanvas.displayWidth(s) <= 4, true)
            joined += stripAnsi(s)
        }
        @Assert(joined, "abcdefghij")
        @Assert(segs.size, 3)
    }

    @TestCase
    public func testWrapAnsiKeepsAnsiPrefix(): Unit {
        let prefix = Ansi.fg(Ansi.THEME_MUTED)
        let text = prefix + "0123456789abcdef" + Ansi.reset()
        let segs = TuiCanvas.wrapAnsi(text, 6)
        @Assert(segs.size > 1, true)
        for (i in 0..segs.size) {
            if (i > 0) {
                @Assert(segs[i].startsWith(prefix), true)
            }
            @Assert(TuiCanvas.displayWidth(segs[i]) <= 6, true)
        }
    }

    @TestCase
    public func testWrapRenderedTextSkipsTableButWrapsProse(): Unit {
        let table = "┌───┬───┐"
        let prose = "这是一段很长的说明文字，必须在窄终端里折行显示，而不是被截断。"
        let out = wrapRenderedText(table + "\n" + prose, 10)
        let lines = out.split("\n", -1)
        @Assert(lines.size > 2, true)
        @Assert(lines[0], table)  // 表格行原样保留
        for (i in 1..lines.size) {
            @Assert(TuiCanvas.displayWidth(lines[i]) <= 10, true)
        }
    }

    @TestCase
    public func testStatusBarKeepsScrollHint(): Unit {
        let bar = StatusBar()
        bar.setUtf8(true)
        bar.setModel("deepseek-flash")
        bar.setStatus("正在压缩历史并保留最近消息，状态文本很长很长")
        bar.setRightHint("48-71/6628")
        let canvas = TuiCanvas()
        canvas.begin(4, 60, true)
        let _ = bar.render(canvas, 0, 60, 1)
        let raw = canvas.flush()
        @Assert(raw.contains("48-71/6628"), true)
    }

    /** 后台任务角标必须在状态为空（显示 ready）时也常驻，不被状态段顶掉 */
    @TestCase
    public func testStatusBarBadgeVisibleWithReadyStatus(): Unit {
        let bar = StatusBar()
        bar.setUtf8(true)
        bar.setModel("deepseek-flash")
        bar.setBadge("后台 2/8")
        let canvas = TuiCanvas()
        canvas.begin(4, 80, true)
        let _ = bar.render(canvas, 0, 80, 1)
        let raw = canvas.flush()
        @Assert(raw.contains("后台 2/8"), true)
        @Assert(raw.contains("ready"), true)
        // 空角标不留下分隔符尾巴
        bar.setBadge("")
        let canvas2 = TuiCanvas()
        canvas2.begin(4, 80, true)
        let _ = bar.render(canvas2, 0, 80, 1)
        @Assert(canvas2.flush().contains("后台"), false)
    }
}
