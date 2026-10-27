/**
 * TasksPanel 单测：左右分栏布局（用户要求）——Tasks 固定左侧、Agents 保持右侧。
 * 覆盖：左对齐断言（面板行无前导空格）+ 边框对齐（顶/底/内容行等宽）+ 状态符号。
 * 渲染取证方式与 agentspanel_test 同款：按 ESC[r;1H 光标定位序列切真实屏幕行
 * （直接 stripAnsi 会把所有行拼成一行，位置/等宽断言会虚绿）。
 */
package cjterm

import std.collection.*

@Test
public class TasksPanelTest {
    private func renderLines(panel: TasksPanel, cols: Int64, outH: Int64): ArrayList<String> {
        let canvas = TuiCanvas()
        canvas.begin(14, cols, true)
        let _ = panel.render(canvas, 13, cols, outH)
        let raw = canvas.flush()
        let lines = ArrayList<String>()
        var cur = StringBuilder()
        var inEsc = false
        for (r in raw.toRuneArray()) {
            let ch = r.toString()
            if (inEsc) {
                if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) {
                    inEsc = false
                    if (ch == "H") {
                        lines.add(stripAnsi(cur.toString()))
                        cur = StringBuilder()
                    }
                }
                continue
            }
            if (ch == "\u{1b}") {
                inEsc = true
                continue
            }
            cur.append(ch)
        }
        if (cur.size > 0) {
            lines.add(stripAnsi(cur.toString()))
        }
        let out = ArrayList<String>()
        for (l in lines) {
            if (l.size > 0) {
                out.add(l)
            }
        }
        return out
    }

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

    private func findLine(lines: ArrayList<String>, needle: String): Int64 {
        var row: Int64 = 0
        for (l in lines) {
            if (l.contains(needle)) {
                return row
            }
            row += 1
        }
        return -1
    }

    @TestCase
    public func testTasksPanelLeftAligned(): Unit {
        // 左右分栏（用户要求）：Tasks 面板固定左侧——面板行前导空格必须为 0
        let panel = TasksPanel()
        panel.setUtf8(true)
        var snaps = ArrayList<TaskSnapshot>()
        snaps.add(TaskSnapshot(1, "统计文件数", TaskState.Completed))
        snaps.add(TaskSnapshot(2, "读 cjpm.toml", TaskState.InProgress))
        snaps.add(TaskSnapshot(3, "汇总输出", TaskState.Pending))
        panel.updateSnapshots(snaps)
        @Assert(panel.shouldShow(), true)
        @Assert(panel.height(16), 5)  // 3 任务 + 上下边框
        let lines = this.renderLines(panel, 120, 16)
        var topLine: String = ""
        var bottomLine: String = ""
        var rowLine: String = ""
        for (l in lines) {
            if (l.contains("Tasks")) { topLine = l }
            if (l.contains("╰")) { bottomLine = l }
            if (l.contains("统计文件数")) { rowLine = l }
        }
        @Assert(topLine.size > 0, true)
        @Assert(bottomLine.size > 0, true)
        // 左对齐：顶行不以空格开头
        @Assert(topLine.toRuneArray()[0].toString() != " ", true)
        // 边框对齐：顶/底/内容行显示宽度一致
        @Assert(TuiCanvas.displayWidth(topLine), TuiCanvas.displayWidth(bottomLine))
        @Assert(TuiCanvas.displayWidth(rowLine), TuiCanvas.displayWidth(bottomLine))
        // 状态符号：✓ 完成 / ▶ 进行中 / … 待办
        @Assert(rowLine.contains("✓"), true)
        @Assert(findLine(lines, "▶") >= 0, true)
        @Assert(findLine(lines, "☐") >= 0, true)
    }

    @TestCase
    public func testTasksPanelEmptyHidden(): Unit {
        // 无任务时面板不渲染（空面板不占屏）
        let panel = TasksPanel()
        @Assert(panel.shouldShow(), false)
        @Assert(panel.height(16), 0)
    }
}
