/**
 * 工具结果折叠：明细默认隐藏、Ctrl+O 展开，content() 始终保留全文。
 */
package cjterm

@Test
public class OutputViewFoldTest {
    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc = false
        for (r in s.toRuneArray()) {
            let ch = r.toString()
            if (ch == "\u{1b}") { inEsc = true; continue }
            if (inEsc) {
                if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) { inEsc = false }
                continue
            }
            sb.append(ch)
        }
        return sb.toString()
    }

    private func renderText(view: OutputView, rows: Int64, cols: Int64): String {
        let canvas = TuiCanvas()
        canvas.begin(rows, cols, true)
        let _ = view.render(canvas, 0, cols, rows)
        return stripAnsi(canvas.flush())
    }

    private func renderRaw(view: OutputView, rows: Int64, cols: Int64): String {
        let canvas = TuiCanvas()
        canvas.begin(rows, cols, true)
        let _ = view.render(canvas, 0, cols, rows)
        return canvas.flush()
    }

    @TestCase
    public func testDetailHiddenThenExpanded(): Unit {
        let view = OutputView()
        view.append("before\n")
        view.appendFoldable("SUMMARY tool", "DETAIL one\nDETAIL two\n", false)
        view.append("after\n")
        // 存档不丢明细
        @Assert(view.content().contains("DETAIL one"), true)
        let folded = this.renderText(view, 8, 60)
        @Assert(folded.contains("SUMMARY tool"), true)
        @Assert(folded.contains("after"), true)
        @Assert(folded.contains("DETAIL one"), false)
        // 展开后明细回到消息流
        view.toggleToolFold()
        @Assert(view.toolDetailsCollapsed(), false)
        let expanded = this.renderText(view, 12, 60)
        @Assert(expanded.contains("DETAIL one"), true)
        @Assert(expanded.contains("DETAIL two"), true)
        @Assert(expanded.contains("after"), true)
    }

    @TestCase
    public func testNextContentNotSwallowedByHiddenDetail(): Unit {
        let view = OutputView()
        view.appendFoldable("SUMMARY only", "DETAIL\n", false)
        view.append("NEXT line\n")
        let folded = this.renderText(view, 6, 50)
        @Assert(folded.contains("SUMMARY only"), true)
        @Assert(folded.contains("NEXT line"), true)
    }

    @TestCase
    public func testFailedToolAutoExpandedEvenWhenFolded(): Unit {
        let view = OutputView()
        view.appendFoldable("✗ bash: FAILED", "ERROR detail one\nERROR detail two\n", true)
        view.appendFoldable("↳ bash: ok", "OK detail\n", false)
        let folded = this.renderText(view, 10, 70)
        @Assert(folded.contains("FAILED"), true)
        @Assert(folded.contains("ERROR detail one"), true)  // 失败明细默认可见
        @Assert(folded.contains("OK detail"), false)        // 成功明细仍折叠
        // 用户显式 Ctrl+O 两次（展开→折叠）后，失败明细也必须收起（显式操作优先）
        view.toggleToolFold()
        view.toggleToolFold()
        let collapsed = this.renderText(view, 10, 70)
        @Assert(collapsed.contains("ERROR detail one"), false)
    }

    @TestCase
    public func testExpandedThinkingHasNoRowBackground(): Unit {
        // 用户反馈：思考块整行色块与内容不贴合。对齐 omp thinkingText 后
        // 只保留灰斜体，不再铺 THEME_THINKING_BG。
        let prevNoColor = Ansi.noColor
        Ansi.noColor = false
        try {
            let view = OutputView()
            view.setThinking("第一行思考\n第二行思考", true)
            view.toggleThinking()
            let raw = this.renderRaw(view, 10, 60)
            @Assert(raw.contains("第一行思考"), true)
            @Assert(raw.contains(Ansi.bg(Ansi.THEME_THINKING_BG)), false)
        } finally {
            Ansi.noColor = prevNoColor
        }
    }
}
