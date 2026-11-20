/**
 * 欢迎页：无历史会话时不显示 Recent sessions 噪声块。
 */
package cjterm

import std.collection.*

@Test
public class WelcomeViewTest {
    private func renderText(view: WelcomeView, rows: Int64, cols: Int64): String {
        let canvas = TuiCanvas()
        canvas.begin(rows, cols, true)
        let _ = view.render(canvas, 0, cols, rows)
        var sb = StringBuilder()
        let raw = canvas.flush()
        var inEsc = false
        for (r in raw.toRuneArray()) {
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

    @TestCase
    public func testEmptySessionsHidesRecentBlock(): Unit {
        let view = WelcomeView(false)
        view.setModel("test-model")
        let text = this.renderText(view, 30, 100)
        @Assert(text.contains("Tips"), true)
        @Assert(text.contains("Recent sessions"), false)
        @Assert(text.contains("暂无历史会话"), false)
    }

    @TestCase
    public func testSessionsShowRecentBlock(): Unit {
        let view = WelcomeView(false)
        let s = ArrayList<String>()
        s.add("hello session")
        view.setSessions(s)
        let text = this.renderText(view, 30, 100)
        @Assert(text.contains("Recent sessions"), true)
        @Assert(text.contains("hello session"), true)
    }
}
