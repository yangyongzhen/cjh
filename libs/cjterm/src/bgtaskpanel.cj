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
 * 后台任务面板（B-2 TUI 侧）：展示进程级后台任务表
 *
 * 渲染样式：
 * ```
 * ╭─ 后台任务 (2 running · 1 succeeded) ─────────────────╮
 * │ ▶ bg-3  npm install        running 42s   12.4KB      │
 * │ ✓ bg-1  cargo build        succeeded 8s  2.1KB       │
 * ╰──────────────────────────────────────────────────────╯
 * ```
 *
 * 布局策略与 Agents 面板一致（snapshot + Mutex + height()/render()），但**全宽**渲染
 * 在 Tasks/Agents 面板带**上方**独立一行带：三块面板同底线并排会各自挤到不可读，
 * 而任务行本身只需要"ID + 标签 + 状态 + 耗时 + 输出量"，独占一行更省列宽。
 */
public class BgTaskPanel {
    private let lock: Mutex = Mutex()
    private var rows: ArrayList<BgTaskRow> = ArrayList<BgTaskRow>()
    private var utf8: Bool = true
    // 上次推送的行签名（updateRows 内部做变更检测）
    private var lastSig: String = ""

    public init() {}

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
        }
        this.lock.unlock()
        return changed
    }

    public func shouldShow(): Bool {
        this.lock.lock()
        let n = this.rows.size
        this.lock.unlock()
        return n > 0
    }

    /** 状态行心跳：无任务返回 ""；有任务返回 "2 bg (1 running)" */
    public func heartbeat(): String {
        this.lock.lock()
        var total: Int64 = this.rows.size
        var running: Int64 = 0
        for (r in this.rows) {
            if (!bgRowIsTerminal(r.state)) {
                running += 1
            }
        }
        this.lock.unlock()
        if (total == 0) {
            return ""
        }
        if (running > 0) {
            return "${total} bg (${running} running)"
        }
        return "${total} bg"
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
        if (this.rows.size == 0) {
            this.lock.unlock()
            return 0
        }
        // 高度上限 4：标题 + 2 行正文 + 底边；任务多时折 "+N more"
        let count: Int64 = Int64(this.rows.size)
        this.lock.unlock()
        let panelH: Int64 = if (count + 2 > 4) { 4 } else { count + 2 }
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
        if (this.rows.size == 0) {
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
        let panelH: Int64 = if (count + 2 > 4) { 4 } else { count + 2 }
        let maxH: Int64 = if (outH / 3 > 0) { outH / 3 } else { 1 }
        let actualH: Int64 = if (panelH > maxH) { maxH } else { panelH }
        if (actualH < 3) {
            return 0  // 连标题+一行正文都放不下：不画，避免半截框
        }
        let startRow: Int64 = availRow - actualH
        if (startRow < 0) {
            return 0
        }
        let panelW: Int64 = cols
        this.renderBox(canvas, startRow, panelW, actualH, sorted, useUtf8)
        return actualH
    }

    private func renderBox(canvas: TuiCanvas, startRow: Int64, panelW: Int64,
        panelH: Int64, items: ArrayList<BgTaskRow>, useUtf8: Bool): Unit {
        let muted: String = Ansi.fg(Ansi.THEME_MUTED)
        let accent: String = Ansi.fg(Ansi.THEME_ACCENT)
        let ok: String = Ansi.fg(Ansi.THEME_OK)
        let warn: String = Ansi.fg(Ansi.THEME_WARN)
        let reset: String = Ansi.reset()
        let bx = BoxChars(useUtf8)

        var running: Int64 = 0
        var done: Int64 = 0
        for (r in items) {
            if (bgRowIsTerminal(r.state)) {
                done += 1
            } else {
                running += 1
            }
        }
        // 顶边框：标题按显示宽度算填充（字节数会把横线补短——中文标题踩过）
        var title: String = "后台任务 (${running} running · ${done} done)"
        var titleW: Int64 = TuiCanvas.displayWidth(title)
        if (titleW + 5 > panelW) {
            title = "bg ${running}r/${done}d"
            titleW = TuiCanvas.displayWidth(title)
        }
        var topLine: String = muted + bx.tl + bx.hc + " " + reset + accent + title + reset + muted + " "
        var dashCount: Int64 = panelW - titleW - 5
        if (dashCount < 0) {
            dashCount = 0
        }
        var i: Int64 = 0
        while (i < dashCount) {
            topLine += bx.hc
            i += 1
        }
        topLine += bx.tr + reset
        canvas.setLine(startRow, topLine)

        // 正文行上限 = actualH - 2；超限时最后一行让位给 "+N more"
        let bodyRows: Int64 = panelH - 2
        var row: Int64 = startRow + 1
        var idx: Int64 = 0
        while (row < startRow + panelH - 1 && idx < Int64(items.size)) {
            let r: BgTaskRow = items[idx]
            if (idx == bodyRows - 1 && Int64(items.size) > bodyRows) {
                let moreText: String = "  +${Int64(items.size) - idx} more"
                var morePad: Int64 = (panelW - 2) - TuiCanvas.displayWidth(moreText)
                if (morePad < 0) {
                    morePad = 0
                }
                var moreSpaces: String = ""
                var mi: Int64 = 0
                while (mi < morePad) {
                    moreSpaces += " "
                    mi += 1
                }
                canvas.setLine(row, muted + bx.vc + reset + moreText + moreSpaces + muted + bx.vc + reset)
                row += 1
                break
            }
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
            // 固定列宽部分：边框 + 标记 + ID + 状态 + 耗时 + 输出量 + 分隔空格
            let fixedW: Int64 = 2 + TuiCanvas.displayWidth(marker) + 2 +
                TuiCanvas.displayWidth(r.taskId) + 2 +
                TuiCanvas.displayWidth(stateCol) + 1 +
                TuiCanvas.displayWidth(elapsedCol) + 2 +
                TuiCanvas.displayWidth(sizeCol)
            var labelBudget: Int64 = (panelW - 2) - fixedW
            if (labelBudget < 2) {
                labelBudget = 2
            }
            var label: String = r.label
            if (TuiCanvas.displayWidth(label) > labelBudget) {
                label = canvas.truncate(label, labelBudget)
            }
            var body: String = " " + marker + " " + r.taskId + "  " + label + "  " + stateCol + " " +
                elapsedCol + "  " + sizeCol
            var pad: Int64 = (panelW - 2) - TuiCanvas.displayWidth(body)
            if (pad < 0) {
                pad = 0
            }
            var padStr: String = ""
            i = 0
            while (i < pad) {
                padStr += " "
                i += 1
            }
            let line: String = muted + bx.vc + reset + " " + markerColor + marker + reset + " " +
                muted + r.taskId + reset + "  " + label + "  " +
                markerColor + stateCol + reset + " " + muted + elapsedCol + reset + "  " +
                muted + sizeCol + reset + padStr + muted + bx.vc + reset
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
