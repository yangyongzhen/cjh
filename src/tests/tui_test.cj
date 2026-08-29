package cjh.tests

import cjterm.*
import cjh.tui.*

/**
 * TUI 层单元测试（此前零覆盖）：
 * - MarkdownRender：粗体/行内代码/代码块/混合/跨帧流式/finish 复位
 * - Screen：setLine 填充截断/中文/diff 只输出变化行/clone/renderToString
 * - Ansi：转义序列格式
 */
@Test
public class MarkdownRenderTest {

    @TestCase
    public func testBold(): Unit {
        let m = MarkdownRender()
        let out = m.process("**bold**")
        @Assert(out, Ansi.bold() + "bold" + Ansi.reset())
    }

    @TestCase
    public func testBoldAcrossFrames(): Unit {
        // 流式：** 拆到两帧
        let m = MarkdownRender()
        let f1 = m.process("**bo")
        let f2 = m.process("ld**")
        @Assert(f1, Ansi.bold() + "bo")
        @Assert(f2, "ld" + Ansi.reset())
    }

    @TestCase
    public func testSingleStarLiteral(): Unit {
        let m = MarkdownRender()
        let out = m.process("* 列表项")
        @Assert(out, "* 列表项")  // 单 * 是普通字符
    }

    @TestCase
    public func testInlineCode(): Unit {
        let m = MarkdownRender()
        // 帧尾反引号延迟到 finish() flush（流式语义：无法预知后续是否还有反引号）
        let out = m.process("`code`") + m.finish()
        @Assert(out, Ansi.fg(Ansi.THEME_ACCENT) + "code" + Ansi.reset())
    }

    @TestCase
    public func testInlineCodeTwoTicks(): Unit {
        // 2 反引号行内代码
        let m = MarkdownRender()
        let out = m.process("``code``") + m.finish()
        @Assert(out, Ansi.fg(Ansi.THEME_ACCENT) + "code" + Ansi.reset())
    }

    @TestCase
    public func testCodeBlockRegression(): Unit {
        // 回归：``` 三连反引号必须正确开/关代码块（旧实现第 2 个开、第 3 个立即关）
        let m = MarkdownRender()
        let open = m.process("```\n")  // \n 触发 flush（3 反引号 → 开代码块）
        @Assert(open, Ansi.fg(Ansi.THEME_MUTED) + "\n")
        let body = m.process("fn main() {}\n")
        @Assert(body, "fn main() {}\n")
        // 闭合反引号在帧尾：需 finish 或后续字符 flush
        let close = m.process("```") + m.finish()
        @Assert(close, Ansi.reset())
        // 闭合后状态复位：后续内容无 ANSI
        let after = m.process("done")
        @Assert(after, "done")
    }

    @TestCase
    public func testCodeBlockTicksAcrossFrames(): Unit {
        // 流式：三连反引号拆到两帧（帧1 末尾 2 个，帧2 开头 1 个）
        let m = MarkdownRender()
        let f1 = m.process("prefix``")
        @Assert(f1, "prefix")  // 未决反引号不输出
        let f2 = m.process("`code")
        @Assert(f2, Ansi.fg(Ansi.THEME_MUTED) + "code")  // 第 3 个到达 → 开代码块
        let f3 = m.process("````x")  // 4 个反引号 + x：flush 关闭代码块
        @Assert(f3, Ansi.reset() + "x")
    }

    @TestCase
    public func testMixedContent(): Unit {
        let m = MarkdownRender()
        let out = m.process("**粗体** 和 `code`") + m.finish()
        @Assert(out, Ansi.bold() + "粗体" + Ansi.reset() + " 和 " + Ansi.fg(Ansi.THEME_ACCENT) + "code" + Ansi.reset())
    }

    @TestCase
    public func testChineseNoMojibake(): Unit {
        // 中文内容不得乱码（Rune 迭代 vs Byte 迭代的回归）
        let m = MarkdownRender()
        let out = m.process("你好世界")
        @Assert(out, "你好世界")
    }

    @TestCase
    public func testFinishResetsUnclosed(): Unit {
        let m = MarkdownRender()
        m.process("**unclosed")
        let tail = m.finish()
        @Assert(tail, Ansi.reset())
        // 复位后可复用
        let after = m.process("ok")
        @Assert(after, "ok")
    }

    @TestCase
    public func testFinishFlushesTicks(): Unit {
        let m = MarkdownRender()
        m.process("`")  // 帧尾 1 个反引号未决（无后续字符触发 flush）
        let tail = m.finish()
        // finish 先 flush（开行内代码 accent），再关闭（reset）
        @Assert(tail, Ansi.fg(Ansi.THEME_ACCENT) + Ansi.reset())
    }
}

@Test
public class ScreenRenderTest {

    @TestCase
    public func testSetLineFillAndTruncate(): Unit {
        let s = Screen(3, 5)
        s.setLine(0, "hello")        // 恰好 5 列
        s.setLine(1, "hi")           // 填充空格到 5 列
        s.setLine(2, "toolongtext")  // 截断到 5 列
        @Assert(s.renderToString(), "hello\nhi   \ntoolo")
    }

    @TestCase
    public func testSetLineOutOfRange(): Unit {
        let s = Screen(2, 3)
        s.setLine(5, "x")  // 越界行忽略
        s.setLine(-1, "x")
        @Assert(s.renderToString(), "   \n   ")
    }

    @TestCase
    public func testDiffOnlyChangedLines(): Unit {
        let old = Screen(2, 5)
        old.setLine(0, "aaaaa")
        old.setLine(1, "bbbbb")
        let cur = Screen(2, 5)
        cur.setLine(0, "aaaaa")
        cur.setLine(1, "ccccc")
        let diff = cur.diff(old)
        @Assert(diff.contains(Ansi.moveTo(2, 1)), true)   // 只第 2 行变化
        @Assert(diff.contains(Ansi.moveTo(1, 1)), false)  // 第 1 行无变化不输出
        @Assert(diff.contains("ccccc"), true)
        @Assert(diff.contains("aaaaa"), false)
    }

    @TestCase
    public func testDiffNoChangeEmpty(): Unit {
        let old = Screen(2, 5)
        old.setLine(0, "aaaaa")
        old.setLine(1, "bbbbb")
        let cur = Screen(2, 5)
        cur.setLine(0, "aaaaa")
        cur.setLine(1, "bbbbb")
        @Assert(cur.diff(old), "")
    }

    @TestCase
    public func testChineseNoMojibake(): Unit {
        let s = Screen(1, 8)
        s.setLine(0, "你好世界")
        let rendered = s.renderToString()
        @Assert(rendered.contains("你好"), true)
        @Assert(rendered.contains("\u{FFFD}"), false)  // 无替换符
    }

    @TestCase
    public func testCloneIndependent(): Unit {
        let s = Screen(2, 3)
        s.setLine(0, "abc")
        let c = s.clone()
        c.setLine(0, "xyz")  // 修改克隆不影响原屏
        @Assert(s.renderToString(), "abc\n   ")
        @Assert(c.renderToString(), "xyz\n   ")
    }

    @TestCase
    public func testDiffAfterClone(): Unit {
        let old = Screen(1, 3)
        old.setLine(0, "abc")
        let cur = old.clone()
        cur.setLine(0, "abd")
        let diff = cur.diff(old)
        @Assert(diff.contains(Ansi.moveTo(1, 1)), true)
        @Assert(diff.contains("abd"), true)
    }
}

@Test
public class AnsiTest {

    @TestCase
    public func testEscapeSequences(): Unit {
        let esc = Rune(27).toString()
        @Assert(Ansi.esc(), esc)
        @Assert(Ansi.bold(), esc + "[1m")
        @Assert(Ansi.reset(), esc + "[0m")
        @Assert(Ansi.fg(73), esc + "[38;5;73m")
        @Assert(Ansi.bg(235), esc + "[48;5;235m")
        @Assert(Ansi.moveTo(3, 5), esc + "[3;5H")
        @Assert(Ansi.clearLine(), esc + "[2K")
        @Assert(Ansi.clearScreen(), esc + "[2J" + esc + "[H")
    }

    @TestCase
    public func testCursorAndScreen(): Unit {
        let esc = Rune(27).toString()
        @Assert(Ansi.hideCursor(), esc + "[?25l")
        @Assert(Ansi.showCursor(), esc + "[?25h")
        @Assert(Ansi.enterAltScreen(), esc + "[?1049h")
        @Assert(Ansi.exitAltScreen(), esc + "[?1049l")
    }
}
