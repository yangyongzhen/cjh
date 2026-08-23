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
    // provider 配置表单弹窗（/provider 无参数时弹出）
    private var providerDialog: FormDialog = FormDialog()
    // 视图切换标签栏（对话 / 帮助）
    private var tabBar: TabBar = TabBar()
    // 启动欢迎视图（两栏：左 logo+模型，右 Tips+会话；输出区为空时显示）
    private var welcomeView: WelcomeView = WelcomeView()
    // 当前视图：0=对话 1=帮助
    private var viewMode: Int64 = 0
    // 多行编辑模式（Ctrl+E 切换；Alt+Enter 提交，Esc 退出）
    private var editor: MultiLineEditor = MultiLineEditor()
    private var editMode: Bool = false

    // ── 审批链（危险操作需人工确认）──
    // agent 线程 requestApproval() 阻塞等待；主循环读 y/n 后写回结果
    private var approvalLock: Mutex = Mutex()
    private var pendingApproval: Option<String> = None
    private var approvalResult: Option<Bool> = None

    // 斜杠命令候选（对齐 main.cj handleSlashCommand 支持的命令）
    private static let SLASH_COMMANDS: Array<String> = [
        "/help", "/new", "/resume", "/model", "/provider", "/skills", "/tree", "/fork", "/settings", "/quit",
    ]

    // 事件回调：提交输入时触发（外部接线）
    public var onSubmit: (String) -> Unit = { _ => }

    // provider 配置表单提交回调（外部接线；参数：provider/baseUrl/model/apiKey）
    public var onProviderSubmit: (String, String, String, String) -> Unit = { _, _, _, _ => }

    public init() {
        this.term = Term()
        // 流式指示器 / 审批弹窗按终端能力初始化
        this.spinner = Spinner(this.term.isUtf8(), "思考中…")
        this.confirmDialog = ConfirmDialog(this.term.isUtf8())
        // 审批弹窗铺满终端宽度（对齐 TUI 全宽布局，避免半屏小窗）
        this.confirmDialog.fullWidth = true
        // 启动欢迎视图（utf8 能力对齐终端；模型/会话由外部 setModel/setSessions 注入）
        this.welcomeView = WelcomeView(this.term.isUtf8())
        // 多行编辑器（行号栏 + 多行编辑；Alt+Enter 由 TuiApp 拦截提交）
        this.editor = MultiLineEditor("输入…（Ctrl+E 多行，Alt+Enter 提交）")
        // 视图切换：对话 / 帮助（Tab/←→ 切换，Esc 回对话视图）
        let tabs = ArrayList<String>()
        tabs.add("对话")
        tabs.add("帮助")
        this.tabBar.setTabs(tabs)
        this.tabBar.onSelect = { _ => this.markDirty() }
        // 审批弹窗回调：把 y/n 结果写回等待中的 agent 线程
        this.confirmDialog.onResult = { ok =>
            this.approvalLock.lock()
            this.approvalResult = Some(ok)
            // 审批完成：清除待审批状态，后续按键恢复正常分发
            this.pendingApproval = None
            this.approvalLock.unlock()
            this.markDirty()
        }
        // provider 配置表单弹窗（utf8 能力对齐终端；居中弹窗，不全宽）
        this.providerDialog = FormDialog(this.term.isUtf8())
        // 提交回调：将表单字段值传回外部 onProviderSubmit
        this.providerDialog.onSubmit = { values =>
            this.providerDialog.hide()
            this.markDirty()
            // 转发：index 0=provider 1=base_url 2=model 3=api_key
            if (values.size >= 4) {
                this.onProviderSubmit(values[0], values[1], values[2], values[3])
            }
        }
        this.providerDialog.onCancel = { =>
            this.providerDialog.hide()
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
     * 弹出 provider 配置表单（/provider 无参数时调用）
     * Provider 字段为 select 下拉（deepseek/openai/glm），
     * ←→ 切换时联动填充对应 baseUrl/model 预设
     */
    public func showProviderDialog(currentBaseUrl: String, currentModel: String, currentApiKey: String): Unit {
        this.providerDialog.clearFields()
        // 字段 0：Provider（select，含三个预设）
        let providers = ArrayList<String>()
        providers.add("deepseek")
        providers.add("openai")
        providers.add("glm")
        this.providerDialog.addSelectField("Provider", providers)
        // 字段 1：API 端点（text）
        this.providerDialog.addField("API 端点", "https://api.openai.com/v1/chat/completions", false)
        // 字段 2：模型（text）
        this.providerDialog.addField("模型", "gpt-4o-mini", false)
        // 字段 3：API Key（secret）
        this.providerDialog.addField("API Key", "sk-xxxx", true)
        // 预填当前配置，方便增量修改
        this.providerDialog.setFieldValue(1, currentBaseUrl)
        this.providerDialog.setFieldValue(2, currentModel)
        this.providerDialog.setFieldValue(3, currentApiKey)
        // select 联动：切换 Provider 时填充对应 baseUrl/model 预设
        this.providerDialog.onSelectChange = { index, value =>
            if (index == 0) {
                // 联动填充 baseUrl/model 预设
                match (value) {
                    case "deepseek" =>
                        this.providerDialog.setFieldValue(1, "https://api.deepseek.com/v1/chat/completions")
                        this.providerDialog.setFieldValue(2, "deepseek-chat")
                    case "openai" =>
                        this.providerDialog.setFieldValue(1, "https://api.openai.com/v1/chat/completions")
                        this.providerDialog.setFieldValue(2, "gpt-4o-mini")
                    case "glm" =>
                        this.providerDialog.setFieldValue(1, "https://open.bigmodel.cn/api/paas/v4/chat/completions")
                        this.providerDialog.setFieldValue(2, "glm-4-flash")
                    case _ => ()
                }
                this.markDirty()
            }
        }
        this.providerDialog.show("配置 Provider", "[Enter]=保存 [Esc]=取消 [↑↓/Tab]切换字段 [←→]选择Provider")
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
     * 确保输出以换行结尾（工具调用提示前调用，线程安全）
     */
    public func ensureNewline(): Unit {
        this.outputLock.lock()
        try {
            this.outputView.ensureNewline()
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
     * 设置模型名（状态徽章显示 + 状态栏分段 + 欢迎视图）
     */
    public func setModel(name: String): Unit {
        this.modelName = name
        this.statusBar.setModel(name)
        this.welcomeView.setModel(name)
        this.markDirty()
    }

    /**
     * 设置最近会话摘要（欢迎视图右栏展示；由外部 SessionStore.list() 注入）
     */
    public func setSessions(list: ArrayList<String>): Unit {
        this.welcomeView.setSessions(list)
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
        // provider 配置表单弹窗：可见时拦截所有按键
        if (this.providerDialog.isVisible()) {
            if (this.providerDialog.handleKey(key)) {
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
            // 关闭下拉框 / 退出多行编辑 / 帮助视图回对话
            if (this.editMode) {
                // 退出多行编辑：内容回填输入框（不提交）
                this.editorExit()
                return
            }
            if (this.viewMode == 1) {
                // 帮助视图：Esc 回对话视图
                this.setView(0)
                return
            }
            if (this.picker.isVisible()) {
                this.picker.hide()
                this.markDirty()
            }
            return
        }
        // Ctrl+E：切换多行编辑模式（ch=5；Ctrl+U/D/C 已被占用）
        if (key.ch == 5) {
            if (this.editMode) {
                // 再次 Ctrl+E：等价 Esc 退出（内容回填输入框）
                this.editorExit()
            } else {
                this.editorEnter()
            }
            return
        }
        // 多行编辑模式：Alt+Enter（ESC \r 序列）提交；其余键交 MultiLineEditor
        if (this.editMode) {
            // Alt+Enter：ESC 后跟 \r（readKey 中 escapeSeq = "\x1b\r"）
            if (key.escapeSeq == TermEsc.ESC + "\r") {
                this.editorSubmit()
                return
            }
            if (this.editor.handleKey(key)) {
                this.markDirty()
                return
            }
            // 编辑模式不消费的键（鼠标等）直接吞掉，避免穿透到输出滚动
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
        // 视图切换：Tab / ←→ 交给 TabBar（对话/帮助视图都可切换回）
        if (this.tabBar.handleKey(key)) {
            // 与当前视图不同才切换（TabBar 已更新 activeIndex）
            if (this.tabBar.activeIndex() != this.viewMode) {
                this.setView(this.tabBar.activeIndex())
            }
            this.markDirty()
            return
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
     * 进入多行编辑模式：输入框内容带入编辑器，隐藏下拉框
     */
    private func editorEnter(): Unit {
        this.editor.setText(this.inputBox.text())
        this.editMode = true
        this.picker.hide()
        this.logger.info("editor enter: text='${this.editor.text()}'")
        this.markDirty()
    }

    /**
     * 退出多行编辑模式：编辑器内容回填输入框（不提交）
     */
    private func editorExit(): Unit {
        this.inputBox.setTextSilent(this.editor.text())
        this.editMode = false
        this.logger.info("editor exit: text='${this.inputBox.text()}'")
        this.markDirty()
    }

    /**
     * 多行编辑提交：Alt+Enter → 回显 + 外部 onSubmit（与输入框提交同路径）
     */
    private func editorSubmit(): Unit {
        let text = this.editor.text()
        this.editMode = false
        this.inputBox.clear()
        if (text.size > 0) {
            this.logger.info("editor submit: '${text}'")
            this.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + text)
            this.onSubmit(text)
        }
        this.markDirty()
    }

    /**
     * 切换视图（0=对话 1=帮助）
     */
    private func setView(v: Int64): Unit {
        this.viewMode = v
        this.tabBar.setActive(v)
        this.markDirty()
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

        // 布局（对齐 omp pi-composer：无侧边框，上下全宽水平线，底部状态+输入）：
        //   0..4        CJ 彩色 logo（现代 5 行）
        //   5           标题栏（cjh Cangjie Agent [模型]）
        //   6           视图标签栏（对话 / 帮助）
        //   7           全宽分隔线（上）
        //   8..bot-1    输出区（无边框全宽，可滚动）
        //   bot         全宽分隔线（下）
        //   statusRow   状态行
        //   inputTop..  输入区（普通 1 行 / 多行编辑动态增高）
        //   rows-1      末行（输入框或编辑器末行）
        // 多行编辑模式：输入区动态增高（行号栏 + 内容行），分隔线/状态随之上移
        // 欢迎视图（启动/新会话，输出区为空）时：隐藏顶部 logo/标题/TabBar/分隔线，
        // 欢迎视图从行 0 占满到状态行上方（对齐 omp 启动画面整屏两栏布局）

        // 输入区行数（编辑模式动态）
        let editBoxH: Int64 = if (this.editMode) {
            var h = this.editor.lineCount()
            if (h < 1) { h = 1 }
            if (h > 5) { h = 5 }
            h
        } else { 1 }
        // 输入区顶行（编辑模式：编辑器占 inputTop..rows-1；普通模式：单行在 rows-1）
        let inputTop = rows - editBoxH
        // 状态行：输入区上方一行（omp 上边框：╭── 状态内容 ─▶──╮，兼作下分隔线）
        let statusRow = inputTop - 1

        // 是否显示欢迎视图（对话视图且输出区为空）
        this.outputLock.lock()
        let showWelcome = this.viewMode == 0 && this.outputView.content().size == 0
        this.outputLock.unlock()

        if (showWelcome) {
            // 欢迎视图垂直居中：可用高度 statusRow，视图实际高约 12 行
            let wH = if (statusRow > 0) { statusRow } else { 0 }
            let welcomeContentH: Int64 = 12
            var wRow: Int64 = 0
            if (wH > welcomeContentH) {
                wRow = (wH - welcomeContentH) / 2
            }
            this.welcomeView.render(this.canvas, wRow, cols, wH - wRow)
        } else {
            // 顶部：CJ logo（彩色）+ 标题栏 + 视图标签栏 + 上分隔线
            let logoLines = Logo.renderLinesModern(utf8)
            var li: Int64 = 0
            for (l in logoLines) {
                this.canvas.setLine(li, l)
                li += 1
            }
            this.canvas.setLine(5, Logo.titleBarFull(utf8, this.modelName, cols))
            this.tabBar.render(this.canvas, 6, cols, 1)
            this.canvas.setLine(7, Logo.separator(cols, utf8))

            // 输出区可用高度：8 .. statusRow-1
            let outH = if (statusRow - 8 > 0) { statusRow - 8 } else { 0 }

            // 输出区（对话 / 帮助视图，无边框全宽）
            if (this.viewMode == 1) {
                this.renderHelp(this.canvas, 8, cols, outH)
            } else {
                this.outputLock.lock()
                try {
                    this.outputView.render(this.canvas, 8, cols, outH)
                } finally {
                    this.outputLock.unlock()
                }
            }
        }

        // 底部区域：审批弹窗 / 流式 spinner / 状态行 三选一
        // （状态行即 omp 上边框 ╭── 内容 ─▶──╮，兼作输出区下分隔线，不再单独画线）
        if (this.confirmDialog.isVisible()) {
            // 审批弹窗：模态覆盖，弹窗 4 行，紧贴输入区上方渲染
            let dlgRow = if (statusRow - 5 > 0) { statusRow - 5 } else { 0 }
            this.confirmDialog.render(this.canvas, dlgRow, cols, 4)
        } else {
            // 流式判定需要 outputLock（agent 线程写流式段，可能竞态）
            this.outputLock.lock()
            let streaming = this.outputView.isStreaming()
            this.outputLock.unlock()
            if (streaming && this.viewMode == 0) {
                // 流式回复中：状态行显示加载指示器（每次渲染推进一帧）
                this.spinner.tick()
                this.spinner.render(this.canvas, statusRow, cols, 1)
            } else {
                this.statusBar.render(this.canvas, statusRow, cols, 1)
            }
        }

        // 输入区（无边框：InputBox 带 ❯ 提示符 / MultiLineEditor 行号栏）
        if (this.editMode) {
            // 编辑器从 inputTop 起占 editBoxH 行（顶到末行 rows-1）
            this.editor.render(this.canvas, inputTop, cols, editBoxH)
        } else {
            this.inputBox.render(this.canvas, inputTop, cols, 1)
        }

        // / 命令下拉补全框：紧贴输入区上方渲染（覆盖状态行区域，最多 6 行）
        if (this.picker.isVisible() && this.picker.size() > 0) {
            let pickerRows = if (this.picker.size() > 6) { 6 } else { this.picker.size() }
            let rendered = this.picker.render(pickerRows)
            for (pi in 0..pickerRows) {
                let lineIdx = statusRow - pickerRows + pi
                // 下限对齐输出区起点（行 8），不覆盖输出区内容
                if (lineIdx >= 8 && lineIdx <= statusRow) {
                    this.canvas.setLine(lineIdx, rendered[pi])
                }
            }
        }

        // provider 配置表单弹窗：可见时居中覆盖在输出区上方
        if (this.providerDialog.isVisible()) {
            // 居中：行 = (输出区起点 8 + 状态行 statusRow) / 2 - 弹窗高度/2
            // 弹窗高度约 8 行（4 字段 + 空行 + 提示 + 上下边框）
            let dlgH: Int64 = 8
            let centerRow = 8 + (if (statusRow > 8) { statusRow - 8 } else { 0 }) / 2 - dlgH / 2
            let dlgRow = if (centerRow < 1) { 1 } else { centerRow }
            this.providerDialog.render(this.canvas, dlgRow, cols, dlgH)
        }

        // 差分渲染：只输出变化行 + 光标定位（InputBox / MultiLineEditor 已设置）
        print(this.canvas.flush(), flush: true)
    }

    /**
     * 帮助视图内容（无边框全宽渲染）
     */
    private func renderHelp(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Unit {
        let lines: ArrayList<String> = ArrayList<String>()
        lines.add(Ansi.fg(Ansi.COLOR_CYAN) + "可用命令：" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /help          显示本帮助" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /new           开始新会话" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /resume [id]   恢复历史会话（无 id 时列出）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /model [id|#]  列出/切换模型" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /settings      查看采样参数（temp/max_tokens）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  /quit          退出" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_CYAN) + "快捷键：" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  Tab / ←→       切换视图（对话/帮助）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  Ctrl+E         多行输入编辑" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  Alt+Enter      多行编辑提交" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.COLOR_GRAY) + "  Esc            退出多行编辑 / 回对话视图" + Ansi.reset())
        var r: Int64 = 0
        for (l in lines) {
            if (r >= height) {
                break
            }
            canvas.setLine(row + r, l)
            r += 1
        }
    }
}
