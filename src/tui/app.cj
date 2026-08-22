package cjh.tui

import std.env.*
import std.fs.*
import std.sync.*
import std.collection.*
import stdx.log.*
import stdx.logger.*
import cjterm.*

/**
 * TUI 应用：对话界面（组件化编排）
 *
 * 布局（0-based 行，TuiCanvas 差分渲染）：
 *   0..4  logo 区
 *   5     标题栏（含模型徽章）
 *   6     分隔线
 *   7..   输出区（OutputView，可滚动）
 *   rows-2 状态行（StatusBar）
 *   rows-1 输入行（InputBox）
 *   （可选）picker 下拉补全框覆盖在输入行上方
 *
 * 组件：OutputView / InputBox / StatusBar / ListPicker 由 cjterm 提供，
 * TuiApp 只做编排（布局 + 输入分发 + 线程安全包装），不再持有渲染细节。
 *
 * 线程模型（保持原语义）：
 * - agent 在 spawn 线程写入：appendOutput/appendDelta/endStream/setStatus
 * - 主循环读键 + 渲染；outputLock 保护 OutputView 的读写
 */
public class TuiApp {
    private let term: Term
    // 组件（cjterm 可复用件）
    private var outputView: OutputView = OutputView()
    private var inputBox: InputBox = InputBox()
    private var statusBar: StatusBar = StatusBar()
    private var canvas: TuiCanvas = TuiCanvas()
    // / 命令下拉补全框（ListPicker 组件）
    private var picker: ListPicker = ListPicker()
    // 输出锁（agent 线程写、主循环读）
    private var outputLock: Mutex = Mutex()
    private var running: Bool = true
    private var dirty: Bool = true
    private var dirtyLock: Mutex = Mutex()
    private var renderLock: Mutex = Mutex()
    private var modelName: String = ""
    // 文件日志（TUI stderr 被屏蔽，写文件排查按键/下拉框问题）
    private var logger: Logger = NoopLogger()
    // 流式加载指示器（agent 回复中显示）
    private var spinner: Spinner = Spinner()
    // 审批/确认弹窗（替代旧的状态行内联审批 UI）
    private var confirmDialog: ConfirmDialog = ConfirmDialog()

    // ── 审批链（危险操作需人工确认）──
    // agent 线程 requestApproval() 阻塞等待；主循环读 y/n 后写回结果
    private var approvalLock: Mutex = Mutex()
    private var pendingApproval: Option<String> = None
    private var approvalResult: Option<Bool> = None

    // 斜杠命令候选（对齐 main.cj handleSlashCommand 支持的命令）
    private static let SLASH_COMMANDS: Array<String> = [
        "/help", "/new", "/resume", "/model", "/settings", "/quit",
    ]

    // 事件回调：提交输入时触发（外部接线）
    public var onSubmit: (String) -> Unit = { _ => }

    public init() {
        this.term = Term()
        // 流式指示器 / 审批弹窗按终端能力初始化
        this.spinner = Spinner(this.term.isUtf8(), "思考中…")
        this.confirmDialog = ConfirmDialog(this.term.isUtf8())
        // 审批弹窗回调：把 y/n 结果写回等待中的 agent 线程
        this.confirmDialog.onResult = { ok =>
            this.approvalLock.lock()
            this.approvalResult = Some(ok)
            // 审批完成：清除待审批状态，后续按键恢复正常分发
            this.pendingApproval = None
            this.approvalLock.unlock()
            this.markDirty()
        }
        // 初始化文件日志（CJH_TUI_LOG 可覆盖路径；失败则降级 NoopLogger）
        try {
            let logPath = TermEnv.getenv("CJH_TUI_LOG") ?? "/tmp/cjh_tui.log"
            let f = File(logPath, OpenMode.Append)
            let tl = TextLogger(f)
            tl.level = LogLevel.DEBUG
            this.logger = tl
        } catch (e: Exception) {
            this.logger = NoopLogger()
        }
        // 输入框回调接线
        // 变更 → 刷新 / 命令候选
        this.inputBox.onChange = { _ =>
            this.refreshCandidates()
        }
        // 提交（Enter）→ 下拉确认 + 输出回显 + 外部 onSubmit
        this.inputBox.onSubmit = { line =>
            // 下拉框可见时：Enter 确认当前选中项（否则提交原始输入）
            var finalLine = line
            if (this.picker.isVisible()) {
                let cur = this.picker.current()
                if (cur.size > 0) {
                    finalLine = cur
                }
                this.logger.debug("enter+pick: 选中项='${cur}' -> inputLine='${finalLine}'")
            }
            this.inputBox.clear()
            this.picker.hide()
            if (finalLine.size > 0) {
                this.logger.info("submit: '${finalLine}'")
                this.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + finalLine)
                this.onSubmit(finalLine)
            }
            this.markDirty()
        }
    }

    public func run(): Unit {
        this.term.enableRaw()
        // 注意：不用备用缓冲区（enterAltScreen）——alt screen 下很多终端会把
        // 滚轮从"原生滚动"改为"发送转义序列"（如 ESC[B 方向键），时序拆分会
        // 残留字符输入（"滚轮触发字母 B"）。保持主屏幕 + clearScreen 全量重绘，
        // 滚轮恢复终端原生滚动行为。
        print(Ansi.clearScreen(), flush: true)
        print(Ansi.hideCursor(), flush: true)
        this.render()

        while (this.running) {
            if (let Some(key) <- this.term.readKey()) {
                this.handleKey(key)
            }
            if (this.takeDirty()) {
                this.render()
            }
            sleep(Duration.millisecond * 5)
        }

        this.term.disableRaw()
        print(Ansi.showCursor(), flush: true)
        print(Ansi.clearScreen(), flush: true)
    }

    /**
     * 请求人工审批（agent 线程调用，阻塞直到用户在 TUI 中按 y/n）。
     * 返回 true=同意执行，false=拒绝。
     */
    public func requestApproval(prompt: String): Bool {
        this.approvalLock.lock()
        this.pendingApproval = Some(prompt)
        this.approvalResult = None
        this.approvalLock.unlock()
        // 弹出确认对话框（模态，渲染与按键由 ConfirmDialog 组件负责）
        this.confirmDialog.show("审批", prompt, "[y]=同意 [n]/[Esc]=拒绝")
        this.markDirty()
        // 等待主循环读键写回结果
        while (true) {
            this.approvalLock.lock()
            let result = this.approvalResult
            this.approvalLock.unlock()
            if (let Some(r) <- result) {
                return r
            }
            sleep(Duration.millisecond * 5)
        }
        return false  // 不可达（while true 仅被 return 退出）
    }

    /**
     * 退出 TUI（供 slash 命令 /quit 调用；线程安全）
     */
    public func quit(): Unit {
        this.running = false
        this.markDirty()
    }

    /**
     * 追加一行到输出区（线程安全）
     */
    public func appendOutput(text: String): Unit {
        this.outputLock.lock()
        try {
            this.outputView.append(text)
        } finally {
            this.outputLock.unlock()
        }
        this.markDirty()
    }

    /**
     * 流式追加：追加到当前输出行末尾（不换行），用于 LLM 增量渲染
     */
    public func appendDelta(text: String): Unit {
        this.outputLock.lock()
        try {
            this.outputView.appendDelta(text)
        } finally {
            this.outputLock.unlock()
        }
        this.markDirty()
        // 由主循环统一渲染（跨线程直接 render 会导致并发写 stdout、光标错乱）
    }

    /**
     * 流式结束：用最终完整文本替换整个流式段。
     * 用于 mojibake 整体修复 / markdown 状态收尾（agent 在 spawn 线程调用，线程安全）
     */
    public func endStream(text: String): Unit {
        this.outputLock.lock()
        try {
            this.outputView.endStream(text)
        } finally {
            this.outputLock.unlock()
        }
        this.markDirty()
    }

    /**
     * 设置底部状态行（线程安全）
     */
    public func setStatus(text: String): Unit {
        this.statusBar.setStatus(text)
        this.markDirty()
    }

    /**
     * 会话分隔线（每轮对话结束后调用，增强层次感）
     */
    public func appendDivider(cols: Int64): Unit {
        let ch = if (this.term.isUtf8()) { "─" } else { "-" }
        var sb = StringBuilder()
        for (i in 0..cols) {
            sb.append(ch)
        }
        this.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + sb.toString() + Ansi.reset())
    }

    /**
     * 设置模型名（状态徽章显示）
     */
    public func setModel(name: String): Unit {
        this.modelName = name
        this.markDirty()
    }

    /**
     * 标记需要渲染（线程安全：spawn 线程调用）
     */
    public func markDirty(): Unit {
        this.dirtyLock.lock()
        try {
            this.dirty = true
        } finally {
            this.dirtyLock.unlock()
        }
    }

    /**
     * 读取并清除渲染标记（主循环调用）
     */
    private func takeDirty(): Bool {
        this.dirtyLock.lock()
        try {
            let d = this.dirty
            this.dirty = false
            return d
        } finally {
            this.dirtyLock.unlock()
        }
    }

    private func handleKey(key: KeyEvent): Unit {
        // Ctrl+C 最高优先级：任何模式（含审批等待中）下都退出
        if (key.isCtrlC) {
            // 若有等待中的审批：写回 false 让其解除阻塞（避免 agent 线程悬挂）
            this.approvalLock.lock()
            if (this.pendingApproval.isSome()) {
                this.approvalResult = Some(false)
                this.pendingApproval = None
            }
            this.approvalLock.unlock()
            this.running = false
            return
        }
        // 审批模式：等待用户 y/n 决策（危险操作审批链）
        this.approvalLock.lock()
        let hasPending = this.pendingApproval.isSome()
        this.approvalLock.unlock()
        if (hasPending) {
            // 审批模式：按键交给 ConfirmDialog 组件处理
            // （y/n/Esc/Enter 命中时触发 onResult 写回审批结果）
            if (this.confirmDialog.handleKey(key)) {
                this.markDirty()
            }
            return
        }
        // 文件日志：记录每个按键的完整形态（排查方向键/下拉框问题）
        this.logger.debug(
            "key ch=${key.ch} esc=${key.escapeSeq} text='${key.text}' " +
            "up=${key.isArrowUp} down=${key.isArrowDown} tab=${key.isTab} " +
            "enter=${key.isEnter} back=${key.isBackspace} mouse=${key.isMouse} " +
            "picker=${this.picker.isVisible()}")
        if (key.escapeSeq == TermEsc.ESC) {
            // 裸 Esc（仅单个 ESC；方向键/功能键序列 ESC[A 等 ch 也是 27，但 escapeSeq 更长）
            // 关闭下拉框（不退出）
            if (this.picker.isVisible()) {
                this.picker.hide()
                this.markDirty()
            }
            return
        }
        // 下拉框可见时：方向键选择、Tab 补全优先于滚动
        if (this.picker.isVisible()) {
            if (key.isArrowUp) {
                this.picker.prev()
                this.markDirty()
                return
            }
            if (key.isArrowDown) {
                this.picker.next()
                this.markDirty()
                return
            }
            if (key.isTab) {
                let cur = this.picker.current()
                if (cur.size > 0) {
                    this.inputBox.setTextSilent(cur)
                }
                this.picker.hide()
                this.refreshCandidates()
                this.markDirty()
                return
            }
        }
        // 组件分发：滚动键（OutputView）→ 输入键（InputBox 消费字符/退格/回车）
        if (this.outputView.handleKey(key)) {
            this.markDirty()
            return
        }
        if (this.inputBox.handleKey(key)) {
            this.markDirty()
            return
        }
    }

    /**
     * 根据当前输入刷新 / 命令下拉候选（输入以 "/" 开头且无空格时弹出）
     */
    private func refreshCandidates(): Unit {
        let line = this.inputBox.text()
        if (line.startsWith("/") && !line.contains(" ")) {
            var list = ArrayList<String>()
            for (cmd in TuiApp.SLASH_COMMANDS) {
                if (cmd.startsWith(line)) {
                    list.add(cmd)
                }
            }
            if (list.size > 0) {
                this.picker.show(list)
                this.logger.debug("candidates input='${line}' -> ${list.size} 项: ${list}")
            } else {
                this.picker.hide()
                this.logger.debug("candidates input='${line}' -> 无匹配，隐藏")
            }
        } else {
            this.picker.hide()
        }
    }

    private func render(): Unit {
        this.renderLock.lock()
        try {
            this.renderInner()
        } finally {
            this.renderLock.unlock()
        }
    }

    private func renderInner(): Unit {
        let (rows, cols) = TermSize.get()
        if (rows < 4) {
            return
        }

        // 开始新帧（尺寸变化时清缓存强制全量重绘）
        this.canvas.begin(rows, cols, this.term.sizeChanged())
        let utf8 = this.term.isUtf8()

        // logo 区（5 行，box-drawing CJ 徽标）
        let logoLines = Logo.renderLines(utf8)
        var li: Int64 = 0
        for (l in logoLines) {
            this.canvas.setLine(li, l)
            li += 1
        }
        // 标题栏（logo 下方独立行）
        this.canvas.setLine(5, Logo.titleBar(utf8, this.modelName))
        // 分隔线
        this.canvas.setLine(6, Logo.separator(cols, utf8))

        // 输出区（行 7 起，高度 = rows - 9：留给状态行 + 输入行）
        let outHeight = if (rows - 9 > 0) { rows - 9 } else { 0 }
        this.outputLock.lock()
        try {
            this.outputView.render(this.canvas, 7, cols, outHeight)
        } finally {
            this.outputLock.unlock()
        }

        // 底部区域（rows-2 起）：审批弹窗 / 流式 spinner / 状态行 三选一
        if (this.confirmDialog.isVisible()) {
            // 审批弹窗：模态覆盖，弹窗 4 行，紧贴输入行上方渲染
            let dlgRow = if (rows - 5 > 0) { rows - 5 } else { 0 }
            this.confirmDialog.render(this.canvas, dlgRow, cols, 4)
        } else {
            // 流式判定需要 outputLock（agent 线程写流式段，可能竞态）
            this.outputLock.lock()
            let streaming = this.outputView.isStreaming()
            this.outputLock.unlock()
            if (streaming) {
                // 流式回复中：状态行显示加载指示器（每次渲染推进一帧）
                this.spinner.tick()
                this.spinner.render(this.canvas, rows - 2, cols, 1)
            } else {
                this.statusBar.render(this.canvas, rows - 2, cols, 1)
            }
        }

        // 输入行（InputBox 内部会设置光标）
        this.inputBox.render(this.canvas, rows - 1, cols, 1)

        // / 命令下拉补全框：紧贴输入行上方渲染（覆盖状态行区域，最多 6 行）
        if (this.picker.isVisible() && this.picker.size() > 0) {
            let pickerRows = if (this.picker.size() > 6) { 6 } else { this.picker.size() }
            let rendered = this.picker.render(pickerRows)
            for (pi in 0..pickerRows) {
                let lineIdx = rows - 1 - pickerRows + pi
                if (lineIdx >= 8 && lineIdx <= rows - 1) {
                    this.canvas.setLine(lineIdx, rendered[pi])
                }
            }
        }

        // 差分渲染：只输出变化行 + 光标定位（InputBox 已设置）
        print(this.canvas.flush(), flush: true)
    }
}
