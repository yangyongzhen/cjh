package cjh.tests

import std.fs.*
import std.collection.*
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
        @Assert(out, Ansi.bold() + Ansi.fg(Ansi.COLOR_TEXT) + "bold" + Ansi.reset())
    }

    @TestCase
    public func testBoldAcrossFrames(): Unit {
        // 流式：** 拆到两帧
        let m = MarkdownRender()
        let f1 = m.process("**bo")
        let f2 = m.process("ld**")
        @Assert(f1, Ansi.bold() + Ansi.fg(Ansi.COLOR_TEXT) + "bo")
        @Assert(f2, "ld" + Ansi.reset())
    }

    @TestCase
    public func testSingleStarLiteral(): Unit {
        let m = MarkdownRender()
        let out = m.process("* 列表项")
        @Assert(stripAnsi(out), "* 列表项")  // 单 * 是普通字符
        @Assert(out.contains(Ansi.fg(Ansi.COLOR_TEXT)), true)  // 普通文本素白
    }

    @TestCase
    public func testInlineCode(): Unit {
        let m = MarkdownRender()
        // 帧尾反引号延迟到 finish() flush（流式语义：无法预知后续是否还有反引号）
        let out = m.process("`code`") + m.finish()
        @Assert(out, Ansi.fg(250) + Ansi.bg(Ansi.THEME_CODE_BG) + "code" + Ansi.reset())
    }

    @TestCase
    public func testInlineCodeTwoTicks(): Unit {
        // 2 反引号行内代码
        let m = MarkdownRender()
        let out = m.process("``code``") + m.finish()
        @Assert(out, Ansi.fg(250) + Ansi.bg(Ansi.THEME_CODE_BG) + "code" + Ansi.reset())
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
        // 闭合后状态复位：后续内容为普通文本（素白）
        let after = m.process("done")
        @Assert(stripAnsi(after), "done")
        @Assert(after.contains(Ansi.fg(Ansi.COLOR_TEXT)), true)
    }

    @TestCase
    public func testCodeBlockTicksAcrossFrames(): Unit {
        // 流式：三连反引号拆到两帧（帧1 末尾 2 个，帧2 开头 1 个）
        let m = MarkdownRender()
        let f1 = m.process("prefix``")
        @Assert(stripAnsi(f1), "prefix")  // 未决反引号不输出
        @Assert(f1.contains(Ansi.fg(Ansi.COLOR_TEXT)), true)
        let f2 = m.process("`code")
        // 第 3 个到达 → 开代码块；"code" 作为语言标注进入缓冲（待 \n 确定），
        // 内容延迟输出——markdown 语义（```lang 声明语言）
        @Assert(f2.contains(Ansi.fg(Ansi.THEME_MUTED)), true)
        @Assert(f2.contains("code"), false)
        let f3 = m.process("````x")  // 4 个反引号 + x：flush 关闭代码块
        @Assert(stripAnsi(f3), "x")
        @Assert(f3.contains(Ansi.reset()), true)
    }

    @TestCase
    public func testMixedContent(): Unit {
        let m = MarkdownRender()
        let out = m.process("**粗体** 和 `code`") + m.finish()
        @Assert(stripAnsi(out), "粗体 和 code")
        @Assert(out.contains(Ansi.fg(Ansi.COLOR_TEXT)), true)  // 粗体/普通文本素白
        @Assert(out.contains(Ansi.fg(250)), true)  // 行内代码芯片 fg250
        @Assert(out.contains(Ansi.bg(Ansi.THEME_CODE_BG)), true)  // 行内代码芯片 bg236
    }

    @TestCase
    public func testChineseNoMojibake(): Unit {
        // 中文内容不得乱码（Rune 迭代 vs Byte 迭代的回归）
        let m = MarkdownRender()
        let out = m.process("你好世界")
        @Assert(stripAnsi(out), "你好世界")
        @Assert(out.contains(Ansi.fg(Ansi.COLOR_TEXT)), true)
    }

    @TestCase
    public func testHeadingRendered(): Unit {
        // ATX 标题：主题色 + 加粗（对齐 omp heading）
        let m = MarkdownRender()
        let out = m.process("## 项目简介") + m.finish()
        @Assert(out.contains(Ansi.fg(Ansi.THEME_ACCENT)), true)  // 主题色
        @Assert(out.contains(Ansi.bold()), true)                  // 加粗
        @Assert(stripAnsi(out).contains("项目简介"), true)
        @Assert(stripAnsi(out).contains("##"), false)            // 标题标记被消费
    }

    @TestCase
    public func testHeadingH1Underline(): Unit {
        // H1 额外下划线（对齐 omp）
        let m = MarkdownRender()
        let out = m.process("# 总览") + m.finish()
        @Assert(out.contains(Ansi.underline()), true)
    }

    @TestCase
    public func testHeadingNotTag(): Unit {
        // #tag / 非 ATX（# 后无空格）→ 原样输出，不渲染成标题
        let m = MarkdownRender()
        let out = m.process("#tag") + m.finish()
        @Assert(stripAnsi(out), "#tag")
        @Assert(out.contains(Ansi.fg(Ansi.THEME_ACCENT)), false)
    }

    @TestCase
    public func testHeadingAcrossFrames(): Unit {
        // 流式：标题跨帧分片
        let m = MarkdownRender()
        let f1 = m.process("## 项目")
        @Assert(stripAnsi(f1), "")  // 缓冲中未输出
        let f2 = m.process("简介\n正文") + m.finish()
        @Assert(stripAnsi(f2).contains("项目简介"), true)
        @Assert(f2.contains(Ansi.fg(Ansi.THEME_ACCENT)), true)
    }

    @TestCase
    public func testTableFullBorders(): Unit {
        // 表格完整边框：顶框 ┌ 与底框 └（旧实现缺边框，看着不像表格）
        let m = MarkdownRender()
        let out = m.process("| A | B |\n|---|---|\n| 1 | 2 |\n") + m.finish()
        @Assert(out.contains("┌"), true)  // 顶边框
        @Assert(out.contains("└"), true)  // 底边框
        @Assert(out.contains("├"), true)  // 表头分隔线
        @Assert(out.contains("┼"), true)
        @Assert(out.contains("┤"), true)
    }

    @TestCase
    public func testPythonBuiltinHighlighted(): Unit {
        // python 内置函数高亮（旧实现缺失 print/len 等——"代码不能高亮"主因）
        let m = MarkdownRender()
        let out = m.process("```python\nprint(len(x))\n```\n") + m.finish()
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "print"), true)
        @Assert(out.contains(Ansi.fg(Ansi.THEME_PURPLE) + "len"), true)
    }

    @TestCase
    public func testFinishResetsUnclosed(): Unit {
        let m = MarkdownRender()
        m.process("**unclosed")
        let tail = m.finish()
        @Assert(stripAnsi(tail), "")  // 无文本残留
        @Assert(tail.contains(Ansi.reset()), true)  // 未闭合粗体已 reset
        // 复位后可复用
        let after = m.process("ok")
        @Assert(stripAnsi(after), "ok")
    }

    @TestCase
    public func testFinishFlushesTicks(): Unit {
        let m = MarkdownRender()
        m.process("`")  // 帧尾 1 个反引号未决（无后续字符触发 flush）
        let tail = m.finish()
        // finish 先 flush（开行内代码 fg250+bg236 芯片），再关闭（reset）
        @Assert(tail, Ansi.fg(250) + Ansi.bg(Ansi.THEME_CODE_BG) + Ansi.reset())
    }

    // 剥离 ANSI 转义（测试辅助：验证文本内容而非精确 ANSI 序列）
    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc: Bool = false
        for (r in s.toRuneArray()) {
            let ch = r.toString()
            if (ch == "\u{1b}") {
                inEsc = true
                continue
            }
            if (inEsc) {
                if (ch == "m") {
                    inEsc = false
                }
                continue
            }
            sb.append(ch)
        }
        return sb.toString()
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

/**
 * OutputView 思考块位置测试：
 * 思考块渲染在消息流末尾（回复下方）——流式/阅读时输出区锚定底部，
 * 思考块始终可见；插到回复上方会在长回复增长时先滚出可视区（用户实测反馈）
 */
@Test
public class OutputViewThinkingTest {

    /**
     * 渲染 OutputView 到 TuiCanvas 并返回行序文本。
     * flush() 按屏幕行序输出（moveTo + 内容），子串顺序即屏幕行顺序。
     */
    private func renderText(ov: OutputView, rows: Int64, cols: Int64): String {
        let c = TuiCanvas()
        c.begin(rows, cols, true)
        ov.render(c, 0, cols, rows)
        return c.flush()
    }

    @TestCase
    public func testThinkingBelowReplyWhenDone(): Unit {
        // 回合完成：echo + 空行 + 回复；思考块位于回复下方（末尾，底部可见）
        let ov = OutputView()
        ov.append("❯ 用户问题")
        ov.append("")
        ov.append("最终回复文本")
        ov.setThinking("分析过程……", true)  // 思考已结束
        let flushed = this.renderText(ov, 12, 40)
        let echoIdx = flushed.indexOf("❯ 用户问题")
        let thinkIdx = flushed.indexOf("💭")
        let replyIdx = flushed.indexOf("最终回复文本")
        @Assert(echoIdx.isSome(), true)
        @Assert(thinkIdx.isSome(), true)
        @Assert(replyIdx.isSome(), true)
        // 顺序：用户消息 < 回复 < 思考块（末尾）
        @Assert(echoIdx.getOrThrow() < replyIdx.getOrThrow(), true)
        @Assert(replyIdx.getOrThrow() < thinkIdx.getOrThrow(), true)
    }

    @TestCase
    public func testThinkingBelowStreamingText(): Unit {
        // 流式中：内容已 appendDelta 到输出，思考块仍在末尾（流式内容下方）
        let ov = OutputView()
        ov.append("❯ 用户问题")
        ov.append("")
        ov.appendDelta("流式内容第一段")  // 流式进行中
        ov.setThinking("正在分析……", false)
        let flushed = this.renderText(ov, 12, 40)
        let thinkIdx = flushed.indexOf("💭")
        let streamIdx = flushed.indexOf("流式内容第一段")
        @Assert(thinkIdx.isSome(), true)
        @Assert(streamIdx.isSome(), true)
        @Assert(streamIdx.getOrThrow() < thinkIdx.getOrThrow(), true)
    }

    @TestCase
    public func testThinkingOmpColors(): Unit {
        // 思考颜色精确对齐 omp（collab-web transcript.css）：
        // 内容 = --fg-muted ≈ 249 #aaaaaa + 斜体；标签 = --fg-faint ≈ 244 #787878
        // 比正文素白暗一档（可区分），比中灰 MUTED 亮（不闷）——用户对比 omp 实测认可
        let ov = OutputView()
        ov.append("回复文本")
        ov.setThinking("分析内容……", true)
        ov.toggleThinking()  // 展开：渲染内容行（前缀 "› "）
        let flushed = this.renderText(ov, 12, 40)
        @Assert(flushed.contains(Ansi.fg(249) + Ansi.italic() + "›"), true)  // 内容 omp muted 斜体
        @Assert(flushed.contains(Ansi.fg(Ansi.COLOR_TEXT) + Ansi.italic() + "›"), false)  // 非正文色
        @Assert(flushed.contains(Ansi.fg(Ansi.THEME_MUTED) + Ansi.italic() + "›"), false)  // 非中灰
        @Assert(flushed.contains(Ansi.fg(244) + "💭"), true)  // 标签 omp faint
    }

    @TestCase
    public func testNoThinkingNoChange(): Unit {
        // 无思考内容：输出原样渲染（无 💭 行）
        let ov = OutputView()
        ov.append("❯ 用户问题")
        ov.append("")
        ov.append("回复文本")
        let flushed = this.renderText(ov, 12, 40)
        @Assert(flushed.indexOf("💭").isNone(), true)
        @Assert(flushed.indexOf("回复文本").isSome(), true)
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
    public func testTableNewlineAfterBottomBorder(): Unit {
        // 表格后内容另起一行：底边框 └──┘ 后必须换行（旧实现直接贴边）
        let m = MarkdownRender()
        let out = m.process("| A | B |\n|---|---|\n| 1 | 2 |\n") +
            m.process("表格后的正文内容") + m.finish()
        let lines = out.split("\n", -1)
        // 底边框行（└）后是独立一行正文，而非贴边拼接
        var bottomIdx: Int64 = -1
        for (i in 0..lines.size) {
            if (lines[i].contains("└")) {
                bottomIdx = i
            }
        }
        @Assert(bottomIdx >= 0, true)
        // 底边框后的下一行是正文（非贴边拼接在 └ 行尾）
        @Assert(bottomIdx + 1 < Int64(lines.size), true)
        @Assert(stripAnsi(lines[bottomIdx + 1]).contains("表格后的正文内容"), true)
    }

    /** 表格边框 UTF-8 主路径（默认）：圆角直角齐全 */
    @TestCase
    public func testTableBordersUtf8Default(): Unit {
        let m = MarkdownRender()
        let out = m.process("| A | B |\n") +
            m.process("|---|---|\n") +
            m.process("| 1 | 2 |\n") + m.finish()
        @Assert(out.contains("┌"), true)   // 顶边框
        @Assert(out.contains("┐"), true)
        @Assert(out.contains("├"), true)   // 分隔线
        @Assert(out.contains("┼"), true)
        @Assert(out.contains("└"), true)   // 底边框
        @Assert(out.contains("│"), true)   // 数据行竖线
    }

    /**
     * 表格边框非 UTF-8 降级（v1.3.16 Windows 框线混排修复）：
     * setUtf8(false) 后表格边框全部走 ASCII，不再硬编码 ┌┬┐
     */
    @TestCase
    public func testTableBordersAsciiFallback(): Unit {
        let m = MarkdownRender()
        m.setUtf8(false)
        let out = m.process("| A | B |\n") +
            m.process("|---|---|\n") +
            m.process("| 1 | 2 |\n") + m.finish()
        @Assert(out.contains("┌"), false)
        @Assert(out.contains("┐"), false)
        @Assert(out.contains("├"), false)
        @Assert(out.contains("┼"), false)
        @Assert(out.contains("└"), false)
        @Assert(out.contains("│"), false)
        @Assert(out.contains("+---"), true)  // 顶/底/分隔线 ASCII
        @Assert(out.contains("|"), true)     // 数据行竖线 ASCII
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

/**
 * InputBox 输入历史 + 大粘贴折叠测试（对齐 omp/通用 CLI）
 */
@Test
public class InputBoxHistoryTest {

    @TestCase
    public func testHistoryUpDown(): Unit {
        let ib = InputBox()
        ib.handleKey(KeyEvent(104))  // h
        ib.handleKey(KeyEvent(105))  // i
        ib.handleKey(KeyEvent(13))   // Enter 提交 "hi"（app.cj 提交后 clear）
        ib.clear()
        ib.handleKey(KeyEvent(119))  // w
        ib.handleKey(KeyEvent(13))   // Enter 提交 "w"（app.cj 提交后 clear）
        ib.clear()
        // ↑：最新 "w"
        ib.handleKey(KeyEvent(27, TermEsc.UP))
        @Assert(ib.text(), "w")
        // ↑：更旧 "hi"
        ib.handleKey(KeyEvent(27, TermEsc.UP))
        @Assert(ib.text(), "hi")
        // ↓：回到 "w"
        ib.handleKey(KeyEvent(27, TermEsc.DOWN))
        @Assert(ib.text(), "w")
        // ↓：回到底部恢复 draft（提交后输入框为空）
        ib.handleKey(KeyEvent(27, TermEsc.DOWN))
        @Assert(ib.text(), "")
    }

    @TestCase
    public func testHistoryDedupAndCap(): Unit {
        let ib = InputBox()
        // 相同内容不重复
        ib.addToHistory("aaa")
        ib.addToHistory("aaa")
        ib.addToHistory("bbb")
        @Assert(ib.historyList().size, 2)
        // 上限 50：加入 55 条裁剪
        let ib2 = InputBox()
        for (i in 0..55) {
            ib2.addToHistory("msg-${i}")
        }
        @Assert(ib2.historyList().size, 50)
        @Assert(ib2.historyList()[0], "msg-5")   // 最旧被裁剪
        @Assert(ib2.historyList()[49], "msg-54") // 最新保留
    }

    @TestCase
    public func testHistoryDraftRestore(): Unit {
        let ib = InputBox()
        ib.addToHistory("历史一")
        // 输入半截内容后按 ↑：draft 保存当前输入
        ib.handleKey(this.keyChar(120))  // x
        ib.handleKey(KeyEvent(27, TermEsc.UP))
        @Assert(ib.text(), "历史一")
        ib.handleKey(KeyEvent(27, TermEsc.DOWN))  // ↓ 回底部恢复 draft
        @Assert(ib.text(), "x")
    }

    @TestCase
    public func testPasteKeepsNewlines(): Unit {
        // v1.3.20：粘贴保留真实换行（旧版剥离），CRLF→LF 归一化；
        // 2 个换行 ≤3 → 不折叠，原文软换行显示
        let ib = InputBox()
        ib.handleKey(KeyEvent("line1\nline2\r\nline3"))
        @Assert(ib.text(), "line1\nline2\nline3")
    }

    @TestCase
    public func testPasteLargeSingleLine(): Unit {
        // v1.3.20：单行长粘贴（0 换行，不触发 >3 行折叠）——原文全部进入输入框，
        // 按显示宽度自动软换行多行显示
        let ib = InputBox()
        // 注意：仓颉 @Test 宏不支持 for(i in 0..N) 循环（§3.22），用 while 构建数据
        var big = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 500) {
            big.append("a")
            cnt += 1
        }
        ib.handleKey(KeyEvent(big.toString()))  // 500 码点长粘贴
        @Assert(Int64(ib.text().size), 500)
        @Assert(ib.text().contains("[Paste"), false)  // 无折叠 marker
        // 显示行数：首行预算 80-5=75，续行 78 → 1+ceil(425/78)=7 → 上限 5
        @Assert(ib.displayHeight(80), 5)
        // 短内容保持 1 行
        let ib2 = InputBox()
        ib2.handleKey(KeyEvent("hello"))
        @Assert(ib2.displayHeight(80), 1)
    }

    @TestCase
    public func testPasteSmallNormal(): Unit {
        let ib = InputBox()
        ib.handleKey(KeyEvent("hello 世界"))
        @Assert(ib.text(), "hello 世界")
        @Assert(ib.displayHeight(80), 1)
    }

    @TestCase
    public func testPasteKeepsPrefix(): Unit {
        // v1.3.20：单行长粘贴（0 换行不折叠）在光标处追加，保留已输入前缀
        let ib = InputBox()
        this.typeText(ib, "hello ")
        var big = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 300) {
            big.append("a")
            cnt += 1
        }
        ib.handleKey(KeyEvent(big.toString()))  // 300 码点长粘贴
        @Assert(ib.text().startsWith("hello a"), true)
        @Assert(ib.text().contains("[Paste"), false)
        @Assert(Int64(ib.text().size), 6 + 300)  // "hello " 6 字节 + 300 个 a
    }

    @TestCase
    public func testPasteSequential(): Unit {
        // v1.3.20：连续两次单行粘贴（均不折叠）按序插入光标处
        let ib = InputBox()
        var a = StringBuilder()
        var b = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 250) {
            a.append("a")
            b.append("b")
            cnt += 1
        }
        ib.handleKey(KeyEvent(a.toString()))
        ib.handleKey(KeyEvent(b.toString()))
        @Assert(Int64(ib.text().size), 500)           // 250 a + 250 b
        @Assert(ib.text().contains("[Paste"), false)  // 无折叠 marker
        @Assert(ib.text()[250..500].startsWith("b"), true)  // 后段全 b（顺序正确）
    }

    @TestCase
    public func testPasteUtf8Safe(): Unit {
        // v1.3.20：中文前缀 + 长中文粘贴（单行不折叠）：UTF-8 边界切片/软换行安全，
        // 退格按字符删（3 字节/字）保留前缀
        let ib = InputBox()
        ib.handleKey(KeyEvent("中文前缀"))  // 4 字 = 12 字节
        @Assert(Int64(ib.text().size), 12)
        var big = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 250) {
            big.append("长")
            cnt += 1
        }
        ib.handleKey(KeyEvent(big.toString()))  // 250 码点长粘贴
        @Assert(ib.text().startsWith("中文前缀长"), true)
        @Assert(ib.text().contains("[Paste"), false)
        @Assert(Int64(ib.text().size), 12 + 250 * 3)  // 中文 12 字节 + 250×3
        // 退格删一个字（3 字节）
        ib.handleKey(KeyEvent(127))
        @Assert(Int64(ib.text().size), 12 + 249 * 3)
        @Assert(ib.text().startsWith("中文前缀长"), true)
    }

    @TestCase
    public func testDisplayHeightWrap(): Unit {
        // 软换行行数：首行预算 74（80-提示符 6），续行 78；真实换行也计行
        let ib = InputBox()
        var t = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 150) {
            t.append("a")
            cnt += 1
        }
        ib.handleKey(KeyEvent(t.toString()))
        @Assert(ib.displayHeight(80), 2)  // 150 = 74 + 76 → 2 行
        let ib2 = InputBox()
        ib2.handleKey(KeyEvent("l1\nl2\nl3\n"))
        @Assert(ib2.displayHeight(80), 4)  // 3 行 + 末尾换行的空尾行
    }

    @TestCase
    public func testPasteCollapseOverThreeLines(): Unit {
        // v1.3.20：>3 行粘贴折叠为 [Paste #N, +X lines] marker（对齐 atomcode/omp），
        // 原文存入 pasteStore 不进输入框；marker 是原子 token
        let ib = InputBox()
        ib.handleKey(KeyEvent("l1\nl2\nl3\nl4"))  // 4 有效行 > 3 → 折叠
        @Assert(ib.text(), "[Paste #1, +4 lines]")
        // 展开提交文本 = 原文（换行保留）
        @Assert(ib.expandedText(), "l1\nl2\nl3\nl4")
        // 显示高度 1 行（marker 单行），不撑高输入区
        @Assert(ib.displayHeight(80), 1)
    }

    @TestCase
    public func testPasteNoCollapseAtThreeLines(): Unit {
        // 边界：恰好 3 行（末尾无换行）不折叠，原文软换行显示
        let ib = InputBox()
        ib.handleKey(KeyEvent("l1\nl2\nl3"))
        @Assert(ib.text(), "l1\nl2\nl3")
        @Assert(ib.text().contains("[Paste"), false)
        @Assert(ib.displayHeight(80), 3)
        // 3 行 + 末尾换行：末尾换行不计新行，仍不折叠（显示 4 行含空尾行）
        let ib2 = InputBox()
        ib2.handleKey(KeyEvent("l1\nl2\nl3\n"))
        @Assert(ib2.text(), "l1\nl2\nl3\n")
        @Assert(ib2.text().contains("[Paste"), false)
    }

    @TestCase
    public func testPasteCollapseCrlfAndPrefix(): Unit {
        // CRLF 归一化后判行数；折叠 marker 插入光标处保留前缀
        let ib = InputBox()
        this.typeText(ib, "pre ")
        ib.handleKey(KeyEvent("a\r\nb\r\nc\r\nd"))  // 4 有效行 → 折叠
        @Assert(ib.text(), "pre [Paste #1, +4 lines]")
        @Assert(ib.expandedText(), "pre a\nb\nc\nd")
    }

    @TestCase
    public func testPasteCollapseSubmitAndAtomicBackspace(): Unit {
        // 折叠 marker：Enter 展开原文提交（换行保留）+ 历史存原文；
        // 光标在末尾时退格整体删除（原子 token，不逐字删）
        let ib = InputBox()
        ib.handleKey(KeyEvent("a\nb\nc\nd\ne"))  // 5 有效行 → 折叠
        // 仓颉坑：捕获可变 var 的 lambda 不能作为回调存储——用 let 容器承接提交值
        let submitted = ArrayList<String>()
        ib.onSubmit = { s =>
            submitted.add(s)
        }
        ib.handleKey(KeyEvent(13))  // Enter
        @Assert(submitted[0], "a\nb\nc\nd\ne")
        @Assert(ib.text(), "")  // 提交后清空
        // 原子退格：marker 整体删
        ib.handleKey(KeyEvent("x\ny\nz\nw"))  // 4 行 → 折叠
        @Assert(ib.text().contains("[Paste #"), true)
        ib.handleKey(KeyEvent(127))  // 退格
        @Assert(ib.text(), "")
        // 历史存的是展开原文（供 ↑ 恢复）
        let hist = ib.historyList()
        @Assert(Int64(hist.size) >= 1, true)
        @Assert(hist[0], "a\nb\nc\nd\ne")
    }

    @TestCase
    public func testPasteCollapseCursorAtEnd(): Unit {
        // 粘贴后光标置尾：折叠 marker 光标在 marker 末尾（render CUP 列=提示符+marker 宽）
        let ib = InputBox()
        ib.handleKey(KeyEvent("a\nb\nc\nd"))  // 折叠 "[Paste #1, +4 lines]" 21 码点
        let canvas = TuiCanvas()
        canvas.begin(4, 80, true)
        ib.render(canvas, 0, 80, 5)
        let flushed = canvas.flush()
        // CUP: ESC[row;colH——光标行 1（首行）、列 = 提示符 5 + marker 21 = 26
        @Assert(flushed.contains(Rune(27).toString() + "[1;26H"), true)
    }

    @TestCase
    public func testPasteCjkCursorScroll(): Unit {
        // 光标 bug 回归（2026-09-09）：CJK+markdown 多段落 ≤3 行不折叠，
        // 软换行视口滚动后光标仍落在末行末列（旧版行段截断→光标错位首行）
        let ib = InputBox()
        // 2 个换行（≤3 不折叠）：第一段落 60 字 CJK（宽 120 > 74 预算→软换行 2 行），
        // 第二段落 **bold** 长文 100 码点（软换行 2 行）→ 总 4 显示行
        var para = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 60) {
            para.append("长")
            cnt += 1
        }
        var tail = StringBuilder()
        cnt = 0
        while (cnt < 100) {
            tail.append("*")
            cnt += 1
        }
        ib.handleKey(KeyEvent(para.toString() + "\n\n" + tail.toString()))
        @Assert(ib.text().contains("[Paste"), false)  // 2 换行 ≤3 → 不折叠
        let canvas = TuiCanvas()
        canvas.begin(6, 80, true)
        ib.render(canvas, 0, 80, 5)
        let flushed = canvas.flush()
        // 光标在末显示行（4 行，1-based 行 4）——旧版截断 bug 会让光标落第 1/2 行
        @Assert(flushed.contains(Rune(27).toString() + "[4;"), true)
    }

    @TestCase
    public func testBackspaceAcrossNewlines(): Unit {
        // 退格在行首删真实换行（两行合并），换行保留于 text
        let ib = InputBox()
        ib.handleKey(KeyEvent("ab\ncd"))
        ib.handleKey(KeyEvent(127))
        @Assert(ib.text(), "ab\nc")
        ib.handleKey(KeyEvent(127))
        @Assert(ib.text(), "ab\n")
        ib.handleKey(KeyEvent(127))  // 删 \n
        @Assert(ib.text(), "ab")
        @Assert(ib.displayHeight(80), 1)
    }

    @TestCase
    public func testRenderMultiLineViewport(): Unit {
        // render 多行输出 + 视口跟随：500 码点 → 光标在第 7 行（超视口 5），
        // 光标定位落在视口末行（1-based 行 5）；首行连续 74 个 a（首行预算）
        let ib = InputBox()
        var big = StringBuilder()
        var cnt: Int64 = 0
        while (cnt < 500) {
            big.append("a")
            cnt += 1
        }
        ib.handleKey(KeyEvent(big.toString()))
        let canvas = TuiCanvas()
        canvas.begin(8, 80, true)
        let used = ib.render(canvas, 0, 80, 5)
        @Assert(used, 5)
        let flushed = canvas.flush()
        @Assert(flushed.contains("[Paste"), false)
        var seg74 = StringBuilder()
        var k: Int64 = 0
        while (k < 74) {
            seg74.append("a")
            k += 1
        }
        @Assert(flushed.contains(seg74.toString()), true)
        @Assert(flushed.contains(Rune(27).toString() + "[5;"), true)  // 光标 CUP 在视口末行
    }

    /** 逐字符输入（模拟按键，光标随输入前移）。
     *  用 while + 字节索引遍历（@Test 宏不支持 for-in 循环，§3.22） */
    private func typeText(ib: InputBox, s: String): Unit {
        var i: Int64 = 0
        while (i < Int64(s.size)) {
            let b0 = Int32(s[i])
            var len: Int64 = 1
            if (b0 >= 0xF0) { len = 4 } else if (b0 >= 0xE0) { len = 3 } else if (b0 >= 0xC0) { len = 2 }
            let ch = s[i..i + len]
            let arr = ch.toArray()
            let first: Int32 = if (arr.size > 0) { Int32(arr[0]) } else { 0 }
            ib.handleKey(KeyEvent(first, ch))
            i += len
        }
    }

    private func keyChar(c: Int32): KeyEvent {
        return KeyEvent(c, Rune(c).toString())
    }

    @TestCase
    public func testSlashHistoryFiltered(): Unit {
        // / 开头输入 → ↑ 只翻 / 命令历史（对齐 shell 前缀过滤）
        let ib = InputBox()
        ib.addToHistory("普通消息")
        ib.addToHistory("/help")
        ib.addToHistory("/new")
        ib.handleKey(this.keyChar(47))  // /
        ib.handleKey(KeyEvent(27, TermEsc.UP))
        @Assert(ib.text(), "/new")      // 只翻 / 历史（最新 / 命令）
        ib.handleKey(KeyEvent(27, TermEsc.UP))
        @Assert(ib.text(), "/help")
        ib.handleKey(KeyEvent(27, TermEsc.DOWN))
        @Assert(ib.text(), "/new")
        ib.handleKey(KeyEvent(27, TermEsc.DOWN))
        @Assert(ib.text(), "/")         // 回到底部恢复 draft
    }

    @TestCase
    public func testCtrlRSearch(): Unit {
        // Ctrl+R：子串过滤历史，实时跳转最近匹配
        let ib = InputBox()
        ib.addToHistory("测试 markdown 渲染")
        ib.addToHistory("修复 bash 超时")
        ib.addToHistory("markdown 表格优化")
        ib.handleKey(KeyEvent(18))              // Ctrl+R 进入搜索
        @Assert(ib.text(), "markdown 表格优化")  // 空子串：最近一条
        ib.handleKey(this.keyChar(109))          // m → 子串过滤
        @Assert(ib.text().contains("markdown"), true)
        @Assert(ib.text().contains("markdown 表格优化"), true)  // 最近匹配
        ib.handleKey(KeyEvent(27, TermEsc.UP))   // ↑ 更旧匹配
        @Assert(ib.text().contains("markdown 渲染"), true)
        ib.handleKey(KeyEvent(18))               // Ctrl+R 退出搜索
        @Assert(ib.text(), "")
    }
}
