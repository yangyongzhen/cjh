package cjterm

import std.collection.*

/**
 * AgentsPanel 渲染单元测试（S3c，方案C §5 R4）
 *
 * 覆盖：标题归账（running/done/token）、行渲染（状态符/kind/焦点星标/轮次/token/当前工具）、
 * 高度上限 7 与 "+N more" 折叠、空面板不渲染、焦点标记。
 *
 * 仓颉测试坑遵守：零参 lambda、enum 无等号运算符（走 name 比对）、块注释内禁写星斜序列。
 */

// 脚本化状态（仓颉 enum 无 ==，断言走可见文本）

@Test
public class AgentsPanelTest {

    /** 渲染面板到画布并剥离 ANSI，返回可见文本 */
    private func renderToText(panel: AgentsPanel, cols: Int64, outH: Int64): String {
        let canvas = TuiCanvas()
        canvas.begin(14, cols, true)
        let _ = panel.render(canvas, 14, cols, outH)
        return this.stripAnsi(canvas.flush())
    }

    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc: Bool = false
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

    @TestCase
    public func testAgentsPanelTitleAndRows(): Unit {
        let panel = AgentsPanel()
        panel.setUtf8(true)
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(11, "找配置", "explore", RowRunning, 2, 1200, 300, "read_file", true))
        rows.add(AgentRow(12, "查依赖", "explore", RowOk, 2, 900, 100, "", false))
        panel.updateRows(rows)
        panel.setFocus(11)
        @Assert(panel.shouldShow(), true)
        @Assert(panel.height(16), 4)
        let text = this.renderToText(panel, 120, 16)
        @Assert(text.contains("Agents (1 running · 1 done · ↑2.1k"), true)
        @Assert(text.contains("explore*  找配置"), true)  // 焦点行 kind 后带星标
        @Assert(text.contains("2/5"), true)               // 运行中轮次 i/5
        @Assert(text.contains("↑1.2k"), true)
        @Assert(text.contains("read_file"), true)         // 当前工具列
        @Assert(text.contains("查依赖"), true)
        @Assert(text.contains("✓"), true)                 // 终态符号
        // 右对齐（修实测"贴左"问题）：cols=120、panelW=min(60,120*2/5)=48 → 起始列 72
        var panelLine: String = ""
        for (l in text.split("\n", -1)) {
            if (l.contains("Agents (")) {
                panelLine = l
                break
            }
        }
        var leading: Int64 = 0
        for (r in panelLine.toRuneArray()) {
            if (r.toString() == " ") {
                leading += 1
            } else {
                break
            }
        }
        @Assert(leading, 72)
        // 边框对齐（修实测"边框不齐"）：顶行/底行/内容行显示宽度一致（= panelW 48）
        var bottomLine: String = ""
        for (l in text.split("\n", -1)) {
            if (l.contains("╰") || l.contains("+")) {
                bottomLine = l
                break
            }
        }
        var rowLine: String = ""
        for (l in text.split("\n", -1)) {
            if (l.contains("找配置")) {
                rowLine = l
                break
            }
        }
        @Assert(TuiCanvas.displayWidth(panelLine), TuiCanvas.displayWidth(bottomLine))
        @Assert(TuiCanvas.displayWidth(rowLine), TuiCanvas.displayWidth(bottomLine))
    }

    @TestCase
    public func testAgentsPanelHeightCapAndMore(): Unit {
        let panel = AgentsPanel()
        panel.setUtf8(true)
        var rows = ArrayList<AgentRow>()
        var i: Int64 = 0
        while (i < 8) {
            rows.add(AgentRow(20 + i, "任务${i}", "worker", RowOk, 1, 100, 10, "", false))
            i += 1
        }
        panel.updateRows(rows)
        // 高度上限 7（5 行 + 边框 2）；超出折 +N more
        @Assert(panel.height(40), 7)
        let text = this.renderToText(panel, 120, 40)
        @Assert(text.contains("任务0"), true)
        @Assert(text.contains("任务3"), true)
        @Assert(text.contains("+4 more"), true)
        @Assert(text.contains("任务5"), false)  // 折叠后不再渲染
    }

    @TestCase
    public func testAgentsPanelEmptyHidden(): Unit {
        let panel = AgentsPanel()
        @Assert(panel.shouldShow(), false)
        @Assert(panel.height(16), 0)
        let text = this.renderToText(panel, 120, 16)
        @Assert(text.contains("Agents"), false)
    }

    @TestCase
    public func testAgentsPanelFocusMark(): Unit {
        let panel = AgentsPanel()
        panel.setUtf8(true)
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(31, "A", "worker", RowRunning, 1, 100, 0, "", false))
        rows.add(AgentRow(32, "B", "worker", RowRunning, 1, 100, 0, "", false))
        panel.updateRows(rows)
        panel.setFocus(32)
        let text = this.renderToText(panel, 120, 30)
        @Assert(text.contains("worker*  B"), true)   // 焦点行 kind 后带星标
        @Assert(text.contains("worker  A"), true)    // 非焦点行无星标
        @Assert(text.contains("A*"), false)
    }
}
