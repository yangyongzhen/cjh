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

    /**
     * 状态行聚合心跳（S3 修实测"干活时主界面啥也没有"）：
     * 无节点返回 ""；有节点返回 "3 agents (2/5 4/5 1/5) ↑3.2k"
     * （运行中轮次最多展示 3 个，token 为全树 prompt 累计）。
     * 状态行每秒 tick 刷新，零刷屏成本；整体状态仍看右下面板。
     */
    public func heartbeat(): String {
        this.lock.lock()
        let total = this.rows.size
        var running: Int64 = 0
        var totalTokens: Int64 = 0
        var iters: String = ""
        var shown: Int64 = 0
        for (r in this.rows) {
            totalTokens += r.promptTokens
            match (r.state) {
                case RowRunning =>
                    running += 1
                    if (shown < 3) {
                        if (shown > 0) {
                            iters += " "
                        }
                        iters += "${r.iterations}/5"
                        shown += 1
                    }
                case _ => ()
            }
        }
        this.lock.unlock()
        if (total == 0) {
            return ""
        }
        var s = "${total} agents"
        if (running > 0) {
            s += " (${iters})"
        }
        s += " ↑${fmtTokenCount(totalTokens)}"
        return s
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

    /**
     * 预计算面板高度（不渲染）：min(节点数+2, 7)——不看列宽的旧签名
     * （单测/不想占布局行的调用方用；TUI 请用带 cols 的重载）
     */
    public func height(outH: Int64): Int64 {
        return this.height(outH, 1000)
    }

    /**
     * 预计算面板高度（不渲染），cols 版与 render 同一"太窄不渲染"判据。
     *
     * 此前 height 不看列宽，窄终端上 render 直接 return 0 却照样占掉布局行
     * （S3 复核 #9：cols=60 实测 height=4、渲染 0 行，动态状态行被顶上去留空白）
     */
    public func height(outH: Int64, cols: Int64): Int64 {
        let panelW: Int64 = if (cols * 2 / 5 < 60) { cols * 2 / 5 } else { 60 }
        if (panelW < 30) {
            return 0  // 渲染器同样放弃（见 render），此处不能预先占位
        }
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

        // 运行中排最前（修实测"agent 多时不滚动到最新"）：高度上限 7 只显示前几行，
        // 运行中的节点最有信息量，必须稳定可见；终态靠后、超出折叠 "+N more"
        var runningRows = ArrayList<AgentRow>()
        var otherRows = ArrayList<AgentRow>()
        for (r in items) {
            match (r.state) {
                case RowRunning => runningRows.add(r)
                case _ => otherRows.add(r)
            }
        }
        var sorted = ArrayList<AgentRow>()
        for (r in runningRows) {
            sorted.add(r)
        }
        for (r in otherRows) {
            sorted.add(r)
        }
        items = sorted

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

        // 列定位（S3 修实测问题）：与 Tasks 面板同款 setOffset 机制整体右移，
        // 此前 startCol 被忽略导致面板贴左
        canvas.setOffset(startCol)
        this.renderBox(canvas, startRow, startCol, panelW, actualH, items, focus)
        canvas.setOffset(0)
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

        // 顶边框：╭─ Agents (N running · M done · ↑xxk) ───╮
        // 显示宽度算填充（修实测"边框不齐"）：title.size 是字节数，中文/·/↑ 都是多字节，
        // 字节数 > 显示宽度会把横线补短；且原公式总数差 1 列（顶 panelW-1 vs 底 panelW）
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
        var title: String = "Agents (${running} running · ${done} done · ↑${fmtTokenCount(totalTokens)})"
        var titleW: Int64 = TuiCanvas.displayWidth(title)
        // 窄面板降级（修实测 80 列下框顶溢出被截）：标题 + 边框 5 列装不下时改短标题
        if (titleW + 5 > panelW) {
            title = "Agents ${running}↑${fmtTokenCount(totalTokens)}"
            titleW = TuiCanvas.displayWidth(title)
        }
        var topLine: String = muted + bx.tl + bx.hc + " " + reset + accent + title + reset + muted + " "
        var dashCount: Int64 = panelW - titleW - 5
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
                // 最后一行让位给 "+N more"（同款显示宽度补齐，右边框对齐）
                let moreText: String = "  +${Int64(items.size) - idx} more"
                var morePad: Int64 = (panelW - 2) - TuiCanvas.displayWidth(moreText)
                if (morePad < 0) { morePad = 0 }
                var moreSpaces: String = ""
                var mi: Int64 = 0
                while (mi < morePad) {
                    moreSpaces += " "
                    mi += 1
                }
                let more: String = muted + bx.vc + reset + moreText + moreSpaces + muted + bx.vc + reset
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
            var toolCol: String = r.currentTool
            let prefixW: Int64 = 1 + TuiCanvas.displayWidth(marker) + 1 + TuiCanvas.displayWidth(r.kind) +
                TuiCanvas.displayWidth(focusMark) + 2
            let tokStr: String = fmtTokenCount(r.promptTokens)
            // 窄面板逐级丢列（S3 复核 #4 收口）：panelW 内放不下时按"信息量从低到高"放弃——
            // 先丢当前工具列、再丢 ↑token 列，把宽度让给 label。此前只把 labelBudget 钳到 2、
            // 工具列永不丢弃，行内容必超 panelW-2 → Canvas.truncate 从右侧裁掉右边框
            // （实测 75/80/90 列 + 当前工具非空时必现；无工具列时 80 列正常）
            var showTool: Bool = toolCol.size > 0
            var showTok: Bool = true
            var labelBudget: Int64 = 0
            var guard: Int64 = 0
            while (guard < 3) {
                guard += 1
                let suffixW: Int64 = 2 + TuiCanvas.displayWidth(iterCol) +
                    (if (showTok) { 3 + TuiCanvas.displayWidth(tokStr) } else { 0 })
                let toolW: Int64 = if (showTool) { 2 + TuiCanvas.displayWidth(toolCol) } else { 0 }
                labelBudget = (panelW - 2) - prefixW - suffixW - toolW
                if (labelBudget >= 4) {
                    break
                }
                if (showTool) {
                    showTool = false
                } else if (showTok) {
                    showTok = false
                } else {
                    break
                }
            }
            if (labelBudget < 2) {
                labelBudget = 2
            }
            // 工具列按显示宽截断（字节截断在中文/宽字符工具名上会错位）
            if (showTool && TuiCanvas.displayWidth(toolCol) > 16) {
                toolCol = canvas.truncate(toolCol, 16)
            }
            var label: String = r.label
            if (TuiCanvas.displayWidth(label) > labelBudget) {
                label = canvas.truncate(label, labelBudget)
            }
            // 行内容按显示宽度补齐到 panelW-2 再补右边框（修实测"每行右端参差"）
            var body: String = " " + marker + " " + r.kind + focusMark + "  " + label + "  " + iterCol
            if (showTok) {
                body += "  ↑" + tokStr
            }
            if (showTool) {
                body += "  " + toolCol
            }
            var pad: Int64 = (panelW - 2) - TuiCanvas.displayWidth(body)
            if (pad < 0) { pad = 0 }
            var padStr: String = ""
            i = 0
            while (i < pad) {
                padStr += " "
                i += 1
            }
            let line: String = muted + bx.vc + reset + " " + markerColor + marker + reset + " " +
                r.kind + focusMark + "  " + label + "  " +
                muted + iterCol + reset +
                (if (showTok) { muted + "  ↑" + tokStr + reset } else { "" }) +
                (if (showTool) { "  " + muted + toolCol + reset } else { "" }) +
                padStr + muted + bx.vc + reset
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
