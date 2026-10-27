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

    /**
     * 按行渲染：把差分输出的 ESC[r;1H 光标定位序列当作行分隔符——
     * 每个定位序列意味着"开始写新的一行"。返回按出现顺序的可见行列表
     * （行序 = 屏幕行序，供行序断言；行内容剥除 ANSI）。
     * （此前直接 stripAnsi 会把所有行拼成一行——行序与等宽断言全部失效，虚绿。）
     */
    private func renderLines(panel: AgentsPanel, cols: Int64, outH: Int64): ArrayList<String> {
        let canvas = TuiCanvas()
        canvas.begin(14, cols, true)
        let _ = panel.render(canvas, 14, cols, outH)
        let raw = canvas.flush()
        let lines = ArrayList<String>()
        var cur = StringBuilder()
        var inEsc = false
        for (r in raw.toRuneArray()) {
            let ch = r.toString()
            if (inEsc) {
                // 定位序列（H 结尾）= 新行开始；其余 ANSI 序列直接丢弃
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
        // 去掉首行残留（首定位序列前的内容通常为空）
        let out = ArrayList<String>()
        for (l in lines) {
            if (l.size > 0) {
                out.add(l)
            }
        }
        return out
    }

    private func lineIndexOf(lines: ArrayList<String>, needle: String): Int64 {
        var row: Int64 = 0
        for (l in lines) {
            if (l.contains(needle)) {
                return row
            }
            row += 1
        }
        return -1
    }

    /** 取第一条含 marker 的内容行（剥 ANSI 后的屏幕行） */
    private func rowLineOf(lines: ArrayList<String>, needle: String): String {
        for (l in lines) {
            if (l.contains(needle)) {
                return l
            }
        }
        return ""
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
        // 右对齐（修实测"贴左"问题）：cols=120、panelW=min(60,120*2/5)=48 → 起始列 72。
        // 全部基于 renderLines 的真实屏幕行（stripAnsi 拼行会导致断言虚绿/虚红）
        let lines = this.renderLines(panel, 120, 16)
        var panelLine: String = ""
        var bottomLine: String = ""
        var rowLine: String = ""
        for (l in lines) {
            if (l.contains("Agents (")) {
                panelLine = l
            }
            if (l.contains("╰")) {
                bottomLine = l
            }
            if (l.contains("找配置")) {
                rowLine = l
            }
        }
        @Assert(panelLine.size > 0, true)
        @Assert(bottomLine.size > 0, true)
        var leading: Int64 = 0
        for (r in panelLine.toRuneArray()) {
            if (r.toString() == " ") {
                leading += 1
            } else {
                break
            }
        }
        @Assert(leading, 72)
        // 边框对齐（修实测"边框不齐"）：顶行/底行/内容行显示宽度一致
        @Assert(TuiCanvas.displayWidth(panelLine), 120)      // 72 空格 + 48 面板
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

    @TestCase
    public func testAgentsPanelRunningFirst(): Unit {
        // 修实测"agent 多时不滚动到最新"：运行中排最前，终态靠后（高度有限时运行中稳定可见）
        let panel = AgentsPanel()
        panel.setUtf8(true)
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(41, "旧的完成", "explore", RowOk, 2, 100, 0, "", false))
        rows.add(AgentRow(42, "正在跑", "worker", RowRunning, 3, 200, 0, "", false))
        panel.updateRows(rows)
        let lines = this.renderLines(panel, 120, 30)
        let idxDone = this.lineIndexOf(lines, "旧的完成")
        let idxRun = this.lineIndexOf(lines, "正在跑")
        @Assert(idxDone > idxRun, true)   // 运行中的行先渲染（行号更小）
    }

    @TestCase
    public func testAgentsPanelHeartbeat(): Unit {
        // 状态行聚合心跳：空面板 ""；有节点 "2 agents (3/5 1/5) ↑300"
        let panel = AgentsPanel()
        @Assert(panel.heartbeat(), "")
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(51, "A", "explore", RowRunning, 3, 200, 0, "", false))
        rows.add(AgentRow(52, "B", "worker", RowRunning, 1, 100, 0, "", false))
        rows.add(AgentRow(53, "C", "explore", RowOk, 2, 300, 0, "", false))
        panel.updateRows(rows)
        @Assert(panel.heartbeat(), "3 agents (3/5 1/5) ↑600")
    }

    @TestCase
    public func testAgentsPanelNarrowWidthKeepsRightBorder(): Unit {
        // S3 复核 #4 收口：75/80/90 列 + 当前工具非空时，行内容曾超 panelW-2，
        // 被 Canvas.truncate 从右侧裁掉右边框（实测 body 以 "re"/"read_f" 结尾）
        let panel = AgentsPanel()
        panel.setUtf8(true)
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(61, "并发审批子任务", "explore", RowRunning, 2, 1200, 300, "read_file", false))
        panel.updateRows(rows)
        var w: Int64 = 75
        while (w <= 90) {
            let lines = this.renderLines(panel, w, 16)
            let rowLine = this.rowLineOf(lines, "▶")
            @Assert(rowLine.size > 0, true)
            @Assert(rowLine.endsWith("│"), true)        // 右边框必须在（此前被裁）
            @Assert(TuiCanvas.displayWidth(rowLine), w)  // 整行恰好铺满终端宽
            @Assert(rowLine.contains("并"), true)        // 标签没被挤没（此前 80 列只剩 1 字）
            w += 5
        }
        // 宽度够（110 列 → panelW=44）时工具列恢复显示（低信息列只是让位，不是永久丢弃）
        let wide = this.rowLineOf(this.renderLines(panel, 110, 16), "▶")
        @Assert(wide.contains("read_file"), true)
        @Assert(wide.endsWith("│"), true)
    }

    @TestCase
    public func testAgentsPanelAsciiFallback(): Unit {
        // S3 复核 #3：非 UTF-8 终端必须整体降级（TuiApp 此前漏接 setUtf8，
        // 面板永远画 UTF-8 框线与状态符 → logo/弹窗 ASCII 而面板仍 UTF-8 的混排）
        let panel = AgentsPanel()
        panel.setUtf8(false)
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(71, "找配置", "explore", RowRunning, 1, 100, 0, "", false))
        panel.updateRows(rows)
        let text = this.renderToText(panel, 120, 16)
        @Assert(text.contains("+"), true)      // 边框降级
        @Assert(text.contains(">"), true)      // 运行中状态符降级
        @Assert(text.contains("╭"), false)
        @Assert(text.contains("│"), false)
        @Assert(text.contains("▶"), false)
    }

    @TestCase
    public func testAgentsPanelHeightRespectsCols(): Unit {
        // S3 复核 #9：太窄（cols*2/5 < 30，即 cols < 75）面板根本不渲染，
        // 高度必须为 0——否则白占布局行、动态状态行被顶上去留一片空白
        let panel = AgentsPanel()
        var rows = ArrayList<AgentRow>()
        rows.add(AgentRow(81, "A", "explore", RowRunning, 1, 100, 0, "", false))
        panel.updateRows(rows)
        @Assert(panel.height(16, 60), 0)
        @Assert(panel.height(16, 74), 0)   // 边界：74*2/5 = 29 < 30
        @Assert(panel.height(16, 80), 3)   // 1 行 + 上下边框
        @Assert(panel.height(16), 3)       // 不传 cols 的旧调用行为不变
    }
}
