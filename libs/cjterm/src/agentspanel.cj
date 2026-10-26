package cjterm

import std.collection.*
import std.sync.*

/**
 * Agent 行快照（TUI 层轻量副本，从 cjh.agent.AgentNode 转换）
 *
 * 与 cjh.agent 解耦：TUI 层只读渲染，不持有 scheduler 引用。
 * 装配层经 scheduler.onChanged → snapshot() 深拷贝 → updateRows 推送。
 */
public class AgentRow {
    public let agentId: Int64
    public let label: String
    public let kind: String        // explore / worker
    public var state: AgentRowState
    public var iterations: Int64
    public var promptTokens: Int64
    public var completionTokens: Int64
    public var currentTool: String
    public var focused: Bool

    public init(agentId: Int64, label: String, kind: String, state: AgentRowState,
        iterations: Int64, promptTokens: Int64, completionTokens: Int64,
        currentTool: String, focused: Bool) {
        this.agentId = agentId
        this.label = label
        this.kind = kind
        this.state = state
        this.iterations = iterations
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
        this.currentTool = currentTool
        this.focused = focused
    }
}

/** Agent 行状态（TUI 层枚举，与 cjh.agent.AgentNodeState 对应） */
public enum AgentRowState {
    | RowPending
    | RowRunning
    | RowOk
    | RowFailed
    | RowTimeout
    | RowCancelled
    | RowBudgetExceeded
}

/**
 * Agents 面板（阶段 C S3，方案C §5 R4）：实时展示子代理树状态
 *
 * 渲染样式：
 * ```
 * ╭─ Agents (2 running · 1 done · ↑2.1k) ──────────────╮
 * │ ▶ explore  找配置*    2/5   ↑1.2k  read_file      │
 * │ ✓ explore  查依赖     2     ↑0.9k                 │
 * ╰────────────────────────────────────────────────────╯
 * ```
 *
 * 布局策略（照 TasksPanel 成熟模式：snapshot + Mutex + height()/render()）：
 * - 位置：输出区右下、Tasks 面板之上（TuiApp 渲染时先 Agents 后 Tasks）
 * - 高度 = min(节点数+2, 7)，超出折成 "+N more"
 * - 刷新：scheduler.onChanged → updateRows（深拷贝快照），渲染零阻塞
 */
public class AgentsPanel {
    private var rows: ArrayList<AgentRow> = ArrayList<AgentRow>()
    private var lock: Mutex = Mutex()
    private var utf8: Bool = true
    // 焦点 agentId（0=父）：面板行打 * 标记；由 TuiApp 焦点循环维护
    private var focusId: Int64 = 0

    public init() {}

    public func setUtf8(v: Bool): Unit {
        this.utf8 = v
    }

    /** 设置焦点（TuiApp Ctrl+G 焦点循环调用；0=父） */
    public func setFocus(agentId: Int64): Unit {
        this.lock.lock()
        this.focusId = agentId
        this.lock.unlock()
    }

    public func currentFocus(): Int64 {
        this.lock.lock()
        let f = this.focusId
        this.lock.unlock()
        return f
    }

    /** 更新行快照（装配层从 scheduler.snapshot() 转换后推送；调用方持有的是拷贝） */
    public func updateRows(rows: ArrayList<AgentRow>): Unit {
        this.lock.lock()
        this.rows = rows
        this.lock.unlock()
    }

    public func shouldShow(): Bool {
        this.lock.lock()
        let n = this.rows.size
        this.lock.unlock()
        return n > 0
    }

    /** 预计算面板高度（不渲染）：min(节点数+2, 7) */
    public func height(outH: Int64): Int64 {
        this.lock.lock()
        if (this.rows.size == 0) {
            this.lock.unlock()
            return 0
        }
        let count: Int64 = Int64(this.rows.size)
        this.lock.unlock()
        let panelH: Int64 = if (count + 2 > 7) { 7 } else { count + 2 }
        let maxH: Int64 = if (outH / 2 > 0) { outH / 2 } else { 1 }
        return if (panelH > maxH) { maxH } else { panelH }
    }

    /**
     * 渲染面板
     * @return 实际占用行数（0=不渲染）
     */
    public func render(canvas: TuiCanvas, availRow: Int64, cols: Int64, outH: Int64): Int64 {
        this.lock.lock()
        if (this.rows.size == 0) {
            this.lock.unlock()
            return 0
        }
        var items: ArrayList<AgentRow> = ArrayList<AgentRow>()
        for (r in this.rows) {
            items.add(r)
        }
        let focus = this.focusId
        this.lock.unlock()

        let panelW: Int64 = if (cols * 2 / 5 < 60) { cols * 2 / 5 } else { 60 }
        if (panelW < 30) {
            return 0
        }
        // 高度上限 7：行数超限时折 "+N more"
        let panelH: Int64 = if (Int64(items.size) + 2 > 7) { 7 } else { Int64(items.size) + 2 }
        let maxH: Int64 = if (outH / 2 > 0) { outH / 2 } else { 1 }
        let actualH: Int64 = if (panelH > maxH) { maxH } else { panelH }
        let startRow: Int64 = availRow - actualH
        if (startRow < 0) {
            return 0
        }
        let startCol: Int64 = cols - panelW
        if (startCol < 0) {
            return 0
        }

        this.renderBox(canvas, startRow, startCol, panelW, actualH, items, focus)
        return actualH
    }

    private func renderBox(canvas: TuiCanvas, startRow: Int64, _: Int64,
        panelW: Int64, panelH: Int64, items: ArrayList<AgentRow>, focus: Int64): Unit {
        let muted: String = Ansi.fg(Ansi.THEME_MUTED)
        let accent: String = Ansi.fg(Ansi.THEME_ACCENT)
        let ok: String = Ansi.fg(Ansi.THEME_OK)
        let warn: String = Ansi.fg(Ansi.THEME_WARN)
        let reset: String = Ansi.reset()
        let bx = BoxChars(this.utf8)

        // 标题：Agents (N running · M done · ↑xxk)
        var running: Int64 = 0
        var done: Int64 = 0
        var totalTokens: Int64 = 0
        for (r in items) {
            match (r.state) {
                case RowRunning => running += 1
                case RowOk => done += 1
                case _ => ()
            }
            totalTokens += r.promptTokens
        }
        let title: String = "Agents (${running} running · ${done} done · ↑${fmtTokenCount(totalTokens)})"
        var topLine: String = muted + bx.tl + bx.hc + " " + reset + accent + title + reset + muted + " "
        let used: Int64 = 4 + Int64(title.size) + 1
        var dashCount: Int64 = panelW - used - 1
        if (dashCount < 0) { dashCount = 0 }
        var i: Int64 = 0
        while (i < dashCount) {
            topLine += bx.hc
            i += 1
        }
        topLine += bx.tr + reset
        canvas.setLine(startRow, topLine)

        // 行：状态符 kind label* iter/tokens ↑ptok 当前工具
        var row: Int64 = startRow + 1
        var idx: Int64 = 0
        let bodyRows: Int64 = panelH - 2
        while (row < startRow + panelH - 1 && idx < Int64(items.size)) {
            let r: AgentRow = items[idx]
            if (idx == bodyRows - 1 && Int64(items.size) > bodyRows) {
                // 最后一行让位给 "+N more"
                let more: String = muted + bx.vc + reset + "  " + muted + "+${Int64(items.size) - idx} more" + reset + muted + bx.vc + reset
                canvas.setLine(row, more)
                row += 1
                break
            }
            var marker: String
            var markerColor: String = muted
            match (r.state) {
                case RowRunning =>
                    marker = if (this.utf8) { "▶" } else { ">" }
                    markerColor = accent
                case RowOk =>
                    marker = if (this.utf8) { "✓" } else { "x" }
                    markerColor = ok
                case RowFailed | RowTimeout | RowCancelled =>
                    marker = if (this.utf8) { "✗" } else { "x" }
                    markerColor = warn
                case RowBudgetExceeded =>
                    marker = if (this.utf8) { "⚠" } else { "!" }
                    markerColor = warn
                case RowPending =>
                    marker = if (this.utf8) { "…" } else { "." }
                    markerColor = muted
            }
            let focusMark: String = if (r.agentId == focus && focus != 0) { "*" } else { "" }
            // 轮次列：运行中显示 i/5（软顶），终态只显示轮数
            var isRunning = false
            match (r.state) {
                case RowRunning => isRunning = true
                case _ => ()
            }
            let iterCol: String = if (isRunning) { "${r.iterations}/5" } else { "${r.iterations}" }
            let maxContentW: Int64 = panelW - 30
            var label: String = r.label
            if (Int64(label.size) > maxContentW) {
                label = truncateUtf8(label, maxContentW)
            }
            var toolCol: String = r.currentTool
            if (Int64(toolCol.size) > 16) {
                toolCol = truncateUtf8(toolCol, 16)
            }
            let line: String = muted + bx.vc + reset + " " + markerColor + marker + reset + " " +
                r.kind + focusMark + "  " + label + "  " +
                muted + iterCol + "  ↑${fmtTokenCount(r.promptTokens)}" + reset +
                (if (toolCol.size > 0) { "  " + muted + toolCol + reset } else { "" }) +
                muted + bx.vc + reset
            canvas.setLine(row, line)
            row += 1
            idx += 1
        }

        var bottomLine: String = muted + bx.bl
        i = 0
        while (i < panelW - 2) {
            bottomLine += bx.hc
            i += 1
        }
        bottomLine += bx.br + reset
        canvas.setLine(startRow + panelH - 1, bottomLine)
    }
}
