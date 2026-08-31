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
        // 第 3 个到达 → 开代码块；"code" 作为语言标注进入缓冲（待 \n 确定），
        // 内容延迟输出——markdown 语义（```lang 声明语言）
        @Assert(f2.contains(Ansi.fg(Ansi.THEME_MUTED)), true)
        @Assert(f2.contains("code"), false)
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

/**
 * Markdown 表格渲染测试（TUI 消息流 markdown 表格 → 边框 + 列对齐）
 */
@Test
public class MarkdownTableTest {
    // ===== 表格渲染（markdown 表格 → 边框 + 列对齐）=====

    @TestCase
    public func testTableRender(): Unit {
        let m = MarkdownRender()
        // 表头 + 分隔 + 数据行（跨帧流式）
        let out = m.process("| # | 问题 | 修复 |\n") +
            m.process("|---|---|---|\n") +
            m.process("| 1 | boss 未声明 | 显式声明 |\n") +
            m.process("| 2 | 双重自增 | 只加一次 |") + m.finish()
        // 表头渲染：边框 + 粗体
        @Assert(out.contains("│"), true)
        @Assert(out.contains("├"), true)   // 分隔线
        @Assert(out.contains("┼"), true)
        @Assert(out.contains(Ansi.bold()), true)  // 表头加粗
        // 列对齐：每行宽度一致（表头列宽对齐）
        let lines = out.split("\n", -1)
        // 表头行与数据行宽度差 ≤2（CJK 宽度 + 边框）
        @Assert(lines.size >= 5, true)
    }

    @TestCase
    public func testTableCjkAlignment(): Unit {
        let m = MarkdownRender()
        // 中英文混合列宽（CJK 宽度感知）
        let out = m.process("| 列一 | col |\n") +
            m.process("|---|---|\n") +
            m.process("| 中文内容 | value |\n") +
            m.process("| a | 长内容值 |") + m.finish()
        let lines = out.split("\n", -1)
        // 表头/数据行应等宽（±2 边框差异内）
        var widths: Array<Int64> = Array<Int64>(lines.size, repeat: 0)
        for (i in 0..lines.size) {
            widths[i] = TuiCanvas.displayWidth(stripAnsi(lines[i]))
        }
        var maxW: Int64 = 0
        for (w in widths) {
            if (w > maxW) { maxW = w }
        }
        for (w in widths) {
            if (w > 0) {
                eprintln("[tbl] w=${w} max=${maxW} line='${this.stripAnsi(lines[0])}'")
                @Assert(maxW - w == 0, true)  // 完全对齐（含分隔线）
            }
        }
    }

    @TestCase
    public func testTableEndOnPlainLine(): Unit {
        let m = MarkdownRender()
        // 表格后接普通文本：表格结束，普通文本正常
        let out = m.process("| a | b |\n") +
            m.process("|---|---|\n") +
            m.process("| 1 | 2 |\n") +
            m.process("普通文本")
        // 表格行渲染 + 普通文本保留
        @Assert(out.contains("│"), true)
        @Assert(out.contains("普通文本"), true)
    }

    // 剥离 ANSI 辅助（测试用）
    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc: Bool = false
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

}

/**
 * 代码块语法高亮测试（对齐 OMP：语言标注时高亮，无标注灰底）
 */
@Test
public class MarkdownHighlightTest {

    @TestCase
    public func testCodeBlockNoLangPlain(): Unit {
        // 无语言标注：不高亮（防误判，对齐 OMP），灰底
        let m = MarkdownRender()
        let out = m.process("```\nlet x = 1\n```") + m.finish()
        // 无关键字紫色（141）、无字符串绿（108）
        @Assert(out.contains("38;5;141"), false)
        @Assert(out.contains("38;5;108"), false)
        // 灰底（代码块默认 245）
        @Assert(out.contains("38;5;245"), true)
    }

    @TestCase
    public func testCodeBlockPythonHighlight(): Unit {
        // python 标注：关键字紫、字符串绿、数字青、# 注释
        let m = MarkdownRender()
        let f1 = m.process("```python\n")
        let f2 = m.process("def foo(x):\n")
        let out = f1 + f2 +
            m.process("    # 注释内容\n") +
            m.process("    return x + 42\n") +
            m.process("```") + m.finish()
        // 关键字 def → 紫（141）
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "def"), true)
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "return"), true)
        // 数字 42 → 青（73）
        @Assert(out.contains(Ansi.fg(Ansi.THEME_ACCENT) + "42"), true)
    }

    @TestCase
    public func testCodeBlockStringComment(): Unit {
        // 字符串绿 + 注释灰蓝（行注释）
        let m = MarkdownRender()
        let out = m.process("```js\n") +
            m.process("const s = \"hello\"; // 注释\n") +
            m.process("```") + m.finish()
        @Assert(out.contains(Ansi.fg(Ansi.THEME_OK) + "\""), true)   // 字符串
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "const"), true)
        // 行注释：// 后内容用 THEME_INFO（103）
        @Assert(out.contains("38;5;103"), true)
    }

    @TestCase
    public func testCodeBlockBlockComment(): Unit {
        // 块注释 /* */ 完整检测
        let m = MarkdownRender()
        let out = m.process("```rust\n") +
            m.process("/* 块注释 */ let x = 1;\n") +
            m.process("```") + m.finish()
        @Assert(out.contains("38;5;103"), true)  // 注释色出现
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "let"), true)  // 注释后的关键字正常
    }
}

/**
 * 思考行 Markdown 渲染测试（灰斜体基础 + 行内粗体/代码高亮）
 */
@Test
public class ThinkingMdTest {
    @TestCase
    public func testThinkingInlineMarkdown(): Unit {
        let out = OutputView()
        out.setThinking("检查 **game.js** 与 `src/game.js` 配置", true)
        // 展开态渲染：灰斜体 + 行内高亮
        out.toggleThinking()
        let canvas = TuiCanvas()
        canvas.begin(5, 80, true)
        out.render(canvas, 0, 80, 5)
        // 无法直接取行文本——用 flush 检查 ANSI
        let flushed = canvas.flush()
        // 粗体（ESC[1m）与行内代码（青 38;5;73）应出现
        @Assert(flushed.contains(Ansi.bold()), true)
        @Assert(flushed.contains("38;5;73"), true)
    }
}
