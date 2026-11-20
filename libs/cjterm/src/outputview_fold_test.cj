/**
 * 工具结果折叠：明细默认隐藏、Ctrl+O 展开，content() 始终保留全文。
 */
package cjterm

import std.collection.*

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

    @TestCase
    public func testDetailHiddenThenExpanded(): Unit {
        let view = OutputView()
        view.append("before\n")
        view.appendFoldable("SUMMARY tool", "DETAIL one\nDETAIL two\n")
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
        view.appendFoldable("SUMMARY only", "DETAIL\n")
        view.append("NEXT line\n")
        let folded = this.renderText(view, 6, 50)
        @Assert(folded.contains("SUMMARY only"), true)
        @Assert(folded.contains("NEXT line"), true)
    }
}
