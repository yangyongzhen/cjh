package cjterm

import std.collection.*
import std.sync.*
import std.time.*

/**
 * 后台任务行状态（TUI 层枚举，与 cjh.tools.BgTaskState 对应）
 *
 * 与任务层解耦：面板只读渲染，不持有 BackgroundTask 引用。
 * 装配层经「任务表快照 → 转换」推送，与 Agents 面板同一套 snapshot + Mutex 模式。
 */
public enum BgTaskRowState {
    | BgRowRunning
    | BgRowSucceeded
    | BgRowFailed
    | BgRowTimeout
    | BgRowKilled
}

/** 后台任务行快照（TUI 层轻量副本，从 cjh.tools.BackgroundTask 转换） */
public class BgTaskRow {
    public let taskId: String
    public let label: String
    public var state: BgTaskRowState
    /** 推送那一刻的耗时（终态行用；运行中行改用 startedAt 实时算） */
    public var elapsedMs: Int64
    public var outputBytes: Int64
    /**
     * 任务启动时刻（wall clock）：运行中行的耗时 = now - startedAt 实时算。
     *
     * 为什么不用快照里的 elapsedMs：主循环重绘时快照不会跟着变，运行中的行会
     * 永远停在推送那一刻的 "42s"。口径与任务层一致（background_task 的 elapsedMs
     * 同样走 DateTime 差值），不另造时钟。
     */
    public let startedAt: DateTime

    public init(taskId: String, label: String, state: BgTaskRowState,
        elapsedMs: Int64, outputBytes: Int64, startedAt: DateTime) {
        this.taskId = taskId
        this.label = label
        this.state = state
        this.elapsedMs = elapsedMs
        this.outputBytes = outputBytes
        this.startedAt = startedAt
    }
}

/** 状态词（与 Web 协议 v6 的 state 字段同一口径，避免两端口径漂移） */
public func bgRowStateWire(s: BgTaskRowState): String {
    match (s) {
        case BgRowRunning => return "running"
        case BgRowSucceeded => return "succeeded"
        case BgRowFailed => return "failed"
        case BgRowTimeout => return "timeout"
        case BgRowKilled => return "killed"
    }
}

/** 是否终态（终态行耗时固定，签名不再变化） */
public func bgRowIsTerminal(s: BgTaskRowState): Bool {
    match (s) {
        case BgRowRunning => return false
        case _ => return true
    }
}

/**
 * 字节数 → 人读格式（12.4KB / 820B / 1.2MB）
 *
 * 整数运算求一位小数，避免浮点精度噪声（与 fmtTokenCount 同一约定）。
 */
public func fmtByteSize(n: Int64): String {
    if (n < 0) {
        return "0B"
    }
    if (n < 1024) {
        return "${n}B"
    }
    if (n < 1024 * 1024) {
        let tenths: Int64 = n * 10 / 1024
        return "${tenths / 10}.${tenths % 10}KB"
    }
    if (n < 1024 * 1024 * 1024) {
        let tenths: Int64 = n * 10 / (1024 * 1024)
        return "${tenths / 10}.${tenths % 10}MB"
    }
    let tenths: Int64 = n / (1024 * 1024 * 1024 / 10)
    return "${tenths / 10}.${tenths % 10}GB"
}

/** 耗时 → 人读格式（42s / 1m02s / 1h02m），与 Web 端 formatBgElapsed 同一口径 */
public func fmtBgElapsed(ms: Int64): String {
    if (ms < 0) {
        return "0s"
    }
    let sec: Int64 = ms / 1000
    if (sec < 60) {
        return "${sec}s"
    }
    let min: Int64 = sec / 60
    if (min < 60) {
        let s: Int64 = sec % 60
        let pad: String = if (s < 10) { "0${s}" } else { "${s}" }
        return "${min}m${pad}s"
    }
    let h: Int64 = min / 60
    let m: Int64 = min % 60
    let pad: String = if (m < 10) { "0${m}" } else { "${m}" }
    return "${h}h${pad}m"
}

/**
 * 槽位占用快照：**两本账**——bash 后台任务与子代理各有一套上限，互不占用
 *
 * 为什么要显示账：两个上限分属不同配置键（`max_background_tasks` 默认 8 /
 * `max_subagents` 默认 4）。用户撞到"后台起不动"时，只有账在眼前才分得清
 * 是哪一本满了——否则只会看到一句"槽位已满"，然后去猜是哪个配置。
 */
public class BgSlots {
    public let bgUsed: Int64
    public let bgMax: Int64
    public let agentsUsed: Int64
    public let agentsMax: Int64

    public init(bgUsed: Int64, bgMax: Int64, agentsUsed: Int64, agentsMax: Int64) {
        this.bgUsed = bgUsed
        this.bgMax = bgMax
        this.agentsUsed = agentsUsed
        this.agentsMax = agentsMax
    }

    public func sameAs(o: BgSlots): Bool {
        return this.bgUsed == o.bgUsed && this.bgMax == o.bgMax &&
            this.agentsUsed == o.agentsUsed && this.agentsMax == o.agentsMax
    }
}

/** 账上"用量/上限"；上限 <= 0 表示不限（settings 四键 0 的语义），只显示用量 */
private func slotPair(used: Int64, max: Int64): String {
    if (max <= 0) {
        return "${used}"
    }
    return "${used}/${max}"
}

/**
 * 两本账文本：`bg 3/8  agents 2/4`
 *
 * 子代理未启用（上限 0 且用量 0）时省略该段——否则每一帧都挂一个恒为
 * `agents 0` 的尾巴，白占列宽。
 */
public func fmtSlotLedger(bgUsed: Int64, bgMax: Int64, agentsUsed: Int64, agentsMax: Int64): String {
    let bgPart: String = "bg " + slotPair(bgUsed, bgMax)
    if (agentsMax <= 0 && agentsUsed == 0) {
        return bgPart
    }
    return bgPart + "  agents " + slotPair(agentsUsed, agentsMax)
}

/**
 * 子代理归账文本：`3/4 agents`；上限 <= 0（不限）只写用量
 *
 * 与 fmtSlotLedger 的 agents 段同一口径，差别是这里带单位——回合总结条以
 * "N/4 agents (x✓ y✗)" 出现，让用户知道 4 是天花板而不是随机数。
 */
public func fmtAgentLedger(total: Int64, max: Int64): String {
    if (max <= 0) {
        return "${total} agents"
    }
    return "${total}/${max} agents"
}

/**
 * 行快照签名：变更检测用
 *
 * **必须做变更检测**（`scheduler.cj:225` 那次"高频回调淹没主循环"的教训）：
 * 任务未变化时重复 markDirty 就是每秒几十次全屏重绘。
 * 耗时按**秒**取整参与签名——运行中的行每秒变一次（1Hz 刷新足够，且能显示实时耗时），
 * 终态行耗时固定，签名不再变。
 */
public func bgTaskRowsSignature(rows: ArrayList<BgTaskRow>): String {
    var sb = StringBuilder()
    for (r in rows) {
        sb.append(r.taskId)
        sb.append("|")
        sb.append(bgRowStateWire(r.state))
        sb.append("|")
        sb.append(r.label)
        sb.append("|")
        // 运行中行的耗时由渲染时按单调时钟实时算，**不进签名**：
        // 进了签名就等于每秒都"有变化"，把主循环拖成 1Hz 全量重绘却什么也没变
        if (bgRowIsTerminal(r.state)) {
            sb.append("${r.elapsedMs / 1000}")
        }
        sb.append("|")
        sb.append("${r.outputBytes}")
        sb.append("\n")
    }
    return sb.toString()
}

/**
 * 各状态计数 → 人读摘要（`1 running  1 failed  1 killed  1 timeout  1 succeeded`）
 *
 * 只列非零项；顺序 running → failed → killed → timeout → succeeded
 * （先报在跑的，再报没成功的，最后报成功的）。
 *
 * 历史教训：面板标题曾把非 running 一律算成 "done"，被 kill 的任务显示成
 * "1 done"，用户以为任务跑完了——终态必须各有其名。
 */
public func fmtBgStateSummary(running: Int64, succeeded: Int64, failed: Int64,
    timeout: Int64, killed: Int64): String {
    var parts = ArrayList<String>()
    if (running > 0) {
        parts.add("${running} running")
    }
    if (failed > 0) {
        parts.add("${failed} failed")
    }
    if (killed > 0) {
        parts.add("${killed} killed")
    }
    if (timeout > 0) {
        parts.add("${timeout} timeout")
    }
    if (succeeded > 0) {
        parts.add("${succeeded} succeeded")
    }
    var sb = StringBuilder()
    var i = 0
    while (i < parts.size) {
        if (i > 0) {
            sb.append("  ")
        }
        sb.append(parts[i])
        i += 1
    }
    return sb.toString()
}

/**
 * 后台任务面板（B-2 TUI 侧）：展示进程级后台任务表
 *
 * 渲染样式（无边框紧凑条，最多 2 行）：
 * ```
 * ▶ bg-3  npm install        running 42s   12.4KB
 * ✓ bg-1  cargo build        succeeded 8s  2.1KB
 * ```
 *
 * 布局策略与 Agents 面板一致（snapshot + Mutex + height()/render()），全宽渲染
 * 在 Tasks/Agents 面板带**上方**。**不画边框与标题**：带框时最多占 4 行，
 * 一整条大框压在 todo 之上观感很重（用户反馈），而无边框一行一条已经够读；
 * 槽位账与状态计数改由状态行心跳承载（见 heartbeat）。
 */
public class BgTaskPanel {
    private let lock: Mutex = Mutex()
    private var rows: ArrayList<BgTaskRow> = ArrayList<BgTaskRow>()
    private var utf8: Bool = true
    // 上次推送的行签名（updateRows 内部做变更检测）
    private var lastSig: String = ""
    // 两本槽位账（标题行显示；变更检测在 setSlots 里做，槽位是低频变化量）
    private var slots: BgSlots = BgSlots(0, 0, 0, 0)
    /**
     * 全终态自动收起：无运行中任务后等这么多秒再淡出（<=0 表示永不淡出）
     *
     * 为什么要有：终态行本身有回看价值（`bash_poll` 读结果、看成功/失败与耗时），
     * 但一个 3 秒就跑完的任务会让面板一直占着底部最多 4 行，直到进程退出——
     * 观感上就是"框赖着不走"。折中成"留够回看时间再收起"，比"立刻消失"
     * （结果一眼没看到）和"永不消失"（长期占屏）都更贴直觉。
     */
    public var fadeAfterSecs: Int64 = 8
    // 全终态起始时刻（秒；0 = 无计时：仍有任务在跑，或表为空）
    private var allDoneAtSec: Int64 = 0
    // 已淡出（到点收起；有新任务推送或表被清空时复位）
    private var faded: Bool = false
    // 时钟（秒）：可注入，测试不必依赖真实时间
    private var clockSec: () -> Int64

    public init() {
        this.clockSec = { => DateTime.now().toUnixTimeStamp().toSeconds() }
    }

    /** 注入时钟（测试用）：返回秒级时间戳 */
    public func setClock(f: () -> Int64): Unit {
        this.lock.lock()
        this.clockSec = f
        this.lock.unlock()
    }

    /**
     * 更新槽位账
     * @return true = 账有变化（调用方据此 markDirty）；false = 无变化，不必重绘
     */
    public func setSlots(s: BgSlots): Bool {
        this.lock.lock()
        let changed: Bool = !this.slots.sameAs(s)
        if (changed) {
            this.slots = s
        }
        this.lock.unlock()
        return changed
    }

    public func currentSlots(): BgSlots {
        this.lock.lock()
        let s = this.slots
        this.lock.unlock()
        return s
    }

    public func setUtf8(v: Bool): Unit {
        this.lock.lock()
        this.utf8 = v
        this.lock.unlock()
    }

    /**
     * 更新行快照
     * @return true = 快照有变化（调用方据此决定是否 markDirty）；false = 无变化，不必重绘
     */
    public func updateRows(rows: ArrayList<BgTaskRow>): Bool {
        let sig = bgTaskRowsSignature(rows)
        this.lock.lock()
        var changed = true
        if (sig == this.lastSig) {
            changed = false
        } else {
            this.lastSig = sig
            this.rows = rows
            // 自动收起的计时起点：有 running 或表为空 → 复位（新任务出现必须重新可见）
            var running: Int64 = 0
            for (r in rows) {
                if (!bgRowIsTerminal(r.state)) {
                    running += 1
                }
            }
            if (rows.size == 0 || running > 0) {
                this.allDoneAtSec = 0
                this.faded = false
            } else if (this.allDoneAtSec == 0) {
                // 首次观察到"全终态"：从这个时刻开始计时，等到点再收起
                this.allDoneAtSec = this.clockSec()
                this.faded = false
            }
        }
        this.lock.unlock()
        return changed
    }

    /**
     * 驱动自动收起（主循环按秒调用一次）
     * @param nowSec 当前时刻（秒）。由调用方传入而非面板自取时钟，测试才能断言"到点"。
     * @return true = 可见性翻转（调用方据此 markDirty）；false = 无变化
     */
    public func tick(nowSec: Int64): Bool {
        this.lock.lock()
        if (this.rows.size == 0 || this.faded || this.fadeAfterSecs <= 0 || this.allDoneAtSec == 0) {
            this.lock.unlock()
            return false
        }
        if (nowSec - this.allDoneAtSec < this.fadeAfterSecs) {
            this.lock.unlock()
            return false
        }
        this.faded = true
        this.lock.unlock()
        return true
    }

    /** 主循环是否还需要按秒驱动：有可见行且尚未淡出（淡出后就不必再空转重绘） */
    public func needsTick(): Bool {
        this.lock.lock()
        let need: Bool = this.rows.size > 0 && !this.faded
        this.lock.unlock()
        return need
    }

    /** 是否已淡出：高度/渲染/心跳统一按"不显示"处理 */
    public func isFaded(): Bool {
        this.lock.lock()
        let f = this.faded
        this.lock.unlock()
        return f
    }

    public func shouldShow(): Bool {
        this.lock.lock()
        let n = this.rows.size
        let f = this.faded
        this.lock.unlock()
        return n > 0 && !f
    }

    /**
     * 状态行心跳：槽位账 + 各状态真实计数；无任务或已淡出返回 ""
     *
     * 形态：`bg 0/8  agents 0/4  1 running  1 killed`
     *
     * 为什么计数与账都在这里：面板改成无边框紧凑条后没有标题行了，
     * 用户撞到"后台起不动"时必须仍能一眼看出是哪本账满了；
     * 终态又必须按 killed/failed/timeout 分类报——笼统 "done" 会误导。
     */
    public func heartbeat(): String {
        this.lock.lock()
        var running: Int64 = 0
        var succeeded: Int64 = 0
        var failed: Int64 = 0
        var timeout: Int64 = 0
        var killed: Int64 = 0
        let total: Int64 = Int64(this.rows.size)
        for (r in this.rows) {
            match (r.state) {
                case BgRowRunning => running += 1
                case BgRowSucceeded => succeeded += 1
                case BgRowFailed => failed += 1
                case BgRowTimeout => timeout += 1
                case BgRowKilled => killed += 1
            }
        }
        let ledger: String = fmtSlotLedger(this.slots.bgUsed, this.slots.bgMax,
            this.slots.agentsUsed, this.slots.agentsMax)
        let f = this.faded
        this.lock.unlock()
        if (total == 0 || f) {
            return ""
        }
        let summary: String = fmtBgStateSummary(running, succeeded, failed, timeout, killed)
        if (summary.size == 0) {
            return ledger
        }
        return ledger + "  " + summary
    }

    /** 运行中任务数（回合总结条的存活提示用） */
    public func runningCount(): Int64 {
        this.lock.lock()
        var running: Int64 = 0
        for (r in this.rows) {
            if (!bgRowIsTerminal(r.state)) {
                running += 1
            }
        }
        this.lock.unlock()
        return running
    }

    /**
     * 预计算面板高度（不渲染），与 render 同一"太窄不渲染"判据
     * （窄终端上若 height 占位但 render 放弃，会顶出一片空白——S3 复核 #9 同款坑）
     */
    public func height(outH: Int64): Int64 {
        return this.height(outH, 1000)
    }

    public func height(outH: Int64, cols: Int64): Int64 {
        if (cols < 40) {
            return 0
        }
        this.lock.lock()
        if (this.rows.size == 0 || this.faded) {
            this.lock.unlock()
            return 0
        }
        // 紧凑条：一行一条，高度上限 2（超过时末行让位给 "+N more"）
        let count: Int64 = Int64(this.rows.size)
        this.lock.unlock()
        let panelH: Int64 = if (count > 2) { 2 } else { count }
        let maxH: Int64 = if (outH / 3 > 0) { outH / 3 } else { 1 }
        return if (panelH > maxH) { maxH } else { panelH }
    }

    /**
     * 渲染面板（全宽，左对齐）
     * @param availRow 可用区底沿（面板底边落在 availRow - 1）
     * @return 实际占用行数（0=不渲染）
     */
    public func render(canvas: TuiCanvas, availRow: Int64, cols: Int64, outH: Int64): Int64 {
        this.lock.lock()
        if (this.rows.size == 0 || this.faded) {
            this.lock.unlock()
            return 0
        }
        if (cols < 40) {
            this.lock.unlock()
            return 0
        }
        var items: ArrayList<BgTaskRow> = ArrayList<BgTaskRow>()
        for (r in this.rows) {
            items.add(r)
        }
        let useUtf8 = this.utf8
        this.lock.unlock()

        // 运行中排最前：行数受限时最有信息量的行必须稳定可见（同 Agents 面板约定）
        var runningRows = ArrayList<BgTaskRow>()
        var otherRows = ArrayList<BgTaskRow>()
        for (r in items) {
            if (bgRowIsTerminal(r.state)) {
                otherRows.add(r)
            } else {
                runningRows.add(r)
            }
        }
        var sorted = ArrayList<BgTaskRow>()
        for (r in runningRows) {
            sorted.add(r)
        }
        for (r in otherRows) {
            sorted.add(r)
        }

        let count: Int64 = Int64(sorted.size)
        // 与 height() 同一套判据（两边不一致会让 agent 运行时多差 1 行，顶掉输出区）
        let panelH: Int64 = if (count > 2) { 2 } else { count }
        let maxH: Int64 = if (outH / 3 > 0) { outH / 3 } else { 1 }
        let actualH: Int64 = if (panelH > maxH) { maxH } else { panelH }
        if (actualH < 1) {
            return 0
        }
        let startRow: Int64 = availRow - actualH
        if (startRow < 0) {
            return 0
        }
        let panelW: Int64 = cols
        this.renderRows(canvas, startRow, panelW, actualH, sorted, useUtf8)
        return actualH
    }

    /**
     * 渲染紧凑条（无边框）：一行一条任务，行数超限时末行让位 "+N more"
     *
     * 列宽预算 = cols - 1：末列写入会触发终端自动换行，多占一行把布局顶掉。
     */
    private func renderRows(canvas: TuiCanvas, startRow: Int64, panelW: Int64,
        panelH: Int64, items: ArrayList<BgTaskRow>, useUtf8: Bool): Unit {
        let muted: String = Ansi.fg(Ansi.THEME_MUTED)
        let accent: String = Ansi.fg(Ansi.THEME_ACCENT)
        let ok: String = Ansi.fg(Ansi.THEME_OK)
        let warn: String = Ansi.fg(Ansi.THEME_WARN)
        let reset: String = Ansi.reset()
        let budget: Int64 = panelW - 1
        var row: Int64 = startRow
        var idx: Int64 = 0
        while (row < startRow + panelH && idx < Int64(items.size)) {
            if (idx == panelH - 1 && Int64(items.size) > panelH) {
                // 末行只报还剩多少条：面板最多 2 行，塞不下的不硬挤
                let moreText: String = "  +${Int64(items.size) - idx} more"
                canvas.setLine(row, muted + moreText + reset)
                row += 1
                break
            }
            let r: BgTaskRow = items[idx]
            var marker: String
            var markerColor: String = muted
            match (r.state) {
                case BgRowRunning =>
                    marker = if (useUtf8) { "▶" } else { ">" }
                    markerColor = accent
                case BgRowSucceeded =>
                    marker = if (useUtf8) { "✓" } else { "x" }
                    markerColor = ok
                case BgRowFailed | BgRowTimeout =>
                    marker = if (useUtf8) { "✗" } else { "x" }
                    markerColor = warn
                case BgRowKilled =>
                    marker = if (useUtf8) { "⏹" } else { "s" }
                    markerColor = muted
            }
            let stateCol: String = bgRowStateWire(r.state)
            // 运行中按单调时钟实时算：主循环重绘时快照不会更新，
            // 直接用 r.elapsedMs 会让运行中的行永远停在推送那一刻
            let liveMs: Int64 = if (bgRowIsTerminal(r.state)) {
                r.elapsedMs
            } else {
                let d: Int64 = (DateTime.now() - r.startedAt).toMilliseconds()
                if (d < 0) { 0 } else { d }
            }
            let elapsedCol: String = fmtBgElapsed(liveMs)
            let sizeCol: String = fmtByteSize(r.outputBytes)
            // 固定列宽部分：行首空格 + 标记 + 空格 + ID + 状态 + 耗时 + 输出量 + 分隔空格
            let fixedW: Int64 = 1 + TuiCanvas.displayWidth(marker) + 1 +
                TuiCanvas.displayWidth(r.taskId) + 2 +
                TuiCanvas.displayWidth(stateCol) + 1 +
                TuiCanvas.displayWidth(elapsedCol) + 2 +
                TuiCanvas.displayWidth(sizeCol)
            var labelBudget: Int64 = budget - fixedW
            if (labelBudget < 2) {
                labelBudget = 2
            }
            var label: String = r.label
            if (TuiCanvas.displayWidth(label) > labelBudget) {
                label = canvas.truncate(label, labelBudget)
            }
            let idPart: String = " " + r.taskId + "  " + label + "  "
            let tailPart: String = " " + elapsedCol + "  " + sizeCol
            let lineW: Int64 = 1 + TuiCanvas.displayWidth(marker) + TuiCanvas.displayWidth(idPart) +
                TuiCanvas.displayWidth(stateCol) + TuiCanvas.displayWidth(tailPart)
            var pad: Int64 = budget - lineW
            if (pad < 0) {
                pad = 0
            }
            var padStr: String = ""
            var pi: Int64 = 0
            while (pi < pad) {
                padStr += " "
                pi += 1
            }
            let line: String = " " + markerColor + marker + reset + muted + idPart + reset +
                markerColor + stateCol + reset + muted + tailPart + reset + padStr
            canvas.setLine(row, line)
            row += 1
            idx += 1
        }
    }
}
