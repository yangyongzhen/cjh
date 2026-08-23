package cjterm

import std.collection.*
import std.sync.*
import std.io.*

/**
 * 任务项数据（TUI 层的轻量副本，从 Agent.todos 拷贝）
 *
 * 与 cjh.agent.TodoItem 解耦：TUI 层只读渲染，不持有 Agent 引用。
 * Agent 通过 onTodosChanged 回调通知 TUI 刷新快照。
 */
public class TaskSnapshot {
    public let id: Int64
    public var content: String
    public var status: TaskState

    public init(id: Int64, content: String, status: TaskState) {
        this.id = id
        this.content = content
        this.status = status
    }
}

/**
 * 任务状态（TUI 层枚举，与 Agent.TodoStatus 对应）
 */
public enum TaskState {
    | Pending
    | InProgress
    | Completed
}

/**
 * Tasks 面板：实时展示 Agent 内置任务列表
 *
 * 渲染样式（对齐 Claude Code TodoWrite 面板）：
 * ```
 * ╭─ Tasks (1 done, 1 in progress, 2 open) ─────────────╮
 * │  ✓ #1  输入队列：TuiApp isAgentRunning 标志位      │
 * │  ▶ #2  main.cj onSubmit 加队列逻辑                 │
 * │  ☐ #3  Agent 执行完毕后自动处理队列下一条         │
 * │  ☐ #4  构建验证 + 真实 LLM 端到端测试              │
 * ╰──────────────────────────────────────────────────────╯
 * ```
 *
 * 布局策略：
 * - 面板宽度：min(60, cols * 2 / 5)，固定足够展示任务内容
 * - 面板高度：任务数 + 2（上下边框），最大不超过输出区高度一半
 * - 渲染位置：输出区右下角，不遮挡输入框和状态行
 * - 可见性：有任务时显示，无任务时隐藏
 */
public class TasksPanel {
    // 任务快照（线程安全：Agent 线程写快照，主循环读渲染）
    private var snapshots: ArrayList<TaskSnapshot> = ArrayList<TaskSnapshot>()
    private var lock: Mutex = Mutex()

    public init() {}

    /**
     * 更新任务快照（Agent 线程通过 onTodosChanged 回调调用）
     * @param items Agent 的 TodoItem 列表
     */
    public func updateSnapshots(items: ArrayList<TaskSnapshot>): Unit {
        this.lock.lock()
        this.snapshots = items
        this.lock.unlock()
    }

    /**
     * 是否应该显示面板（有任务时显示）
     */
    public func shouldShow(): Bool {
        this.lock.lock()
        let count: Int64 = Int64(this.snapshots.size)
        this.lock.unlock()
        return count > 0
    }

    /**
     * 渲染面板到 canvas
     * @param canvas 画布
     * @param availRow 面板可用起始行（输出区底部）
     * @param cols 总列数
     * @param outH 输出区高度
     * @return 实际占用的行数（0=不渲染）
     */
    public func render(canvas: TuiCanvas, availRow: Int64, cols: Int64, outH: Int64): Int64 {
        this.lock.lock()
        if (this.snapshots.size == 0) {
            this.lock.unlock()
            return 0
        }
        // 复制快照到本地（避免持锁渲染）
        var items: ArrayList<TaskSnapshot> = ArrayList<TaskSnapshot>()
        for (snap in this.snapshots) {
            items.add(snap)
        }
        this.lock.unlock()

        // 统计各状态数量
        var doneCount: Int64 = 0
        var inProgressCount: Int64 = 0
        var openCount: Int64 = 0
        for (item in items) {
            match (item.status) {
                case TaskState.Completed => doneCount += 1
                case TaskState.InProgress => inProgressCount += 1
                case TaskState.Pending => openCount += 1
            }
        }

        // 面板宽度：min(60, cols * 2 / 5)
        let panelW: Int64 = if (cols * 2 / 5 < 60) { cols * 2 / 5 } else { 60 }
        if (panelW < 30) {
            return 0  // 终端太窄，不显示
        }

        // 面板高度：任务数 + 2（上下边框）
        let panelH: Int64 = Int64(items.size) + 2
        // 最大不超过输出区高度一半
        let maxH: Int64 = if (outH / 2 > 0) { outH / 2 } else { 1 }
        let actualH: Int64 = if (panelH > maxH) { maxH } else { panelH }

        // 渲染起始行：面板底部对齐输出区底部
        let startRow: Int64 = availRow - actualH
        if (startRow < 0) {
            return 0  // 空间不足，不显示
        }

        // 渲染起始列：右对齐
        let startCol: Int64 = cols - panelW
        if (startCol < 0) {
            return 0
        }

        // 渲染边框和任务行
        this.renderBox(canvas, startRow, startCol, panelW, actualH, items, doneCount, inProgressCount, openCount)
        return actualH
    }

    /**
     * 渲染面板边框 + 任务行
     */
    private func renderBox(canvas: TuiCanvas, startRow: Int64, startCol: Int64,
        panelW: Int64, panelH: Int64, items: ArrayList<TaskSnapshot>,
        doneCount: Int64, inProgressCount: Int64, openCount: Int64): Unit {
        let muted: String = Ansi.fg(Ansi.THEME_MUTED)
        let accent: String = Ansi.fg(Ansi.THEME_ACCENT)
        let ok: String = Ansi.fg(Ansi.THEME_OK)
        let warn: String = Ansi.fg(Ansi.COLOR_YELLOW)
        let reset: String = Ansi.reset()

        // 顶边框：╭─ Tasks (1 done, 1 in progress, 2 open) ───╮
        let title: String = "Tasks (${doneCount} done, ${inProgressCount} in progress, ${openCount} open)"
        var topLine: String = muted + "╭─ " + reset + accent + title + reset + muted + " "
        let used: Int64 = 4 + Int64(title.size) + 1  // ╭─ + title + 空格
        var dashCount: Int64 = panelW - used - 1  // -1 for ╮
        if (dashCount < 0) { dashCount = 0 }
        var i: Int64 = 0
        while (i < dashCount) {
            topLine += "─"
            i += 1
        }
        topLine += "╮" + reset
        canvas.setLine(startRow, topLine)

        // 任务行：│  ✓ #1  content   │
        var row: Int64 = startRow + 1
        var itemIdx: Int64 = 0
        while (row < startRow + panelH - 1 && itemIdx < Int64(items.size)) {
            let item: TaskSnapshot = items[itemIdx]
            var marker: String = ""
            var markerColor: String = muted
            match (item.status) {
                case TaskState.Completed =>
                    marker = "✓"
                    markerColor = ok
                case TaskState.InProgress =>
                    marker = "▶"
                    markerColor = warn
                case TaskState.Pending =>
                    marker = "☐"
                    markerColor = muted
            }
            // 截断 content 到面板宽度
            let maxContentW: Int64 = panelW - 12  // │ + 空格 + marker + 空格 + #id + 空格 + 内容 + 空格 + │
            var content: String = item.content
            if (Int64(content.size) > maxContentW) {
                content = content[0..maxContentW]
            }
            let line: String = muted + "│" + reset + "  " + markerColor + marker + reset + " " +
                muted + "#${item.id}" + reset + "  " + content +
                muted + "│" + reset
            canvas.setLine(row, line)
            row += 1
            itemIdx += 1
        }

        // 底边框：╰───╯
        var bottomLine: String = muted + "╰"
        i = 0
        while (i < panelW - 2) {
            bottomLine += "─"
            i += 1
        }
        bottomLine += "╯" + reset
        canvas.setLine(startRow + panelH - 1, bottomLine)
    }
}
