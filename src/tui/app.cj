package cjh.tui

import std.env.*
import std.convert.Parsable
import std.fs.*
import std.sync.*
import std.time.*
import std.collection.*
import stdx.log.*
import stdx.logger.*
import cjterm.*
import cjh.agent.*
import cjutil.*

// 强制退出：直接终止进程（agent 线程卡死在 OS 调用时的 100% 兜底）。
// 必须用 _exit（POSIX，不运行 atexit/runtime 清理）而非 exit——exit 会触发
// 仓颉 runtime 析构，此时 agent 线程仍在阻塞（mock 延迟/TLS read），
// 清理访问跨线程资源 → Segmentation fault（实测静态版 exit code -11）
@C
foreign func _exit(code: Int32): Unit

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
    // Agent 执行状态（方案 B：执行期间输入可编辑，提交时入队 + 提示）
    private var agentRunning: Bool = false
    private var agentRunningLock: Mutex = Mutex()
    // Agent 执行开始时间（实时状态行计时用）
    private var agentStartTime: DateTime = DateTime.now()
    // Agent 当前 LLM 轮次计数（状态行"第 N 轮"：让用户看到 run 在推进、
    // 排队消息要等多轮任务结束——队列等待透明化）
    private var agentRounds: Int64 = 0
    // Agent 执行期间累计输入 token（实时状态行显示用）
    private var agentPromptTokens: Int64 = 0
    private var agentTokenLock: Mutex = Mutex()
    // Agent 当前执行状态（实时状态行显示用：Thinking/Running bash/Streaming 等）
    private var agentState: String = ""
    // 思考窗口缓冲：reasoning_content 实时累积
    // 升级（pi 风格）：内容保留全文可回看，默认折叠为 1 行，Ctrl+T 展开/折叠
    private var reasoningBuffer: String = ""
    private var reasoningLock: Mutex = Mutex()
    // 思考块展开状态（Ctrl+T 切换）
    private var reasoningExpanded: Bool = false
    // 思考是否已结束（正式 content 开始；结束前显示"思考中"，结束后可回看）
    private var reasoningDone: Bool = false
    // 思考内容上限（防内存膨胀；超出截断保留尾部）
    private let reasoningMaxChars: Int64 = 8192
    // 输入队列：Agent 执行期间提交的消息排队，执行完毕后自动处理
    private var inputQueue: ArrayList<String> = ArrayList<String>()
    private var inputQueueLock: Mutex = Mutex()
    // 文件日志（TUI stderr 被屏蔽，写文件排查按键/下拉框问题）
    private var logger: Logger = NoopLogger()
    // 流式加载指示器（agent 回复中显示）
    private var spinner: Spinner = Spinner()
    // Agent 最近活动时间（onDelta/onReasoning/onTokenEstimate 更新）：
    // 空闲检测——模型停滞（无帧）时超时自动中断，避免僵持
    private var agentLastActivity: DateTime = DateTime.now()
    private var idleWarned: Bool = false
    // 空闲超时秒数（CJH_IDLE_TIMEOUT_SECS 可配，默认 180）
    // 180s：第三方代理（taotoken.net 等）缓冲 SSE + 模型思考/长生成阶段
    // 客户端可长时间无帧；60s 太激进会误切正常任务（已多次实测）
    private let idleTimeoutSecs: Int64
    // 审批/确认弹窗（替代旧的状态行内联审批 UI）
    private var confirmDialog: ConfirmDialog = ConfirmDialog()
    // provider 配置表单弹窗（/provider 无参数时弹出）
    private var providerDialog: FormDialog = FormDialog()
    // 视图切换标签栏（对话 / 帮助）
    private var tabBar: TabBar = TabBar()
    // 启动欢迎视图（两栏：左 logo+模型，右 Tips+会话；输出区为空时显示）
    private var welcomeView: WelcomeView = WelcomeView()
    // Tasks 面板（Agent 内置任务列表实时展示）
    private var tasksPanel: TasksPanel = TasksPanel()
    // /theme 交互式选择模式：picker 显示主题列表，选中后提交 /theme <name>
    private var themePickerMode: Bool = false
    // 主题预览：picker 移动时即时预览，Esc 恢复原主题，Enter 持久化
    private var themePreviewOriginal: String = ""  // 进入预览前的主题名（Esc 恢复用）
    // /resume 交互式会话选择：委托 cjterm.ListSelect 组件（按键+滚动+渲染全封装）
    private var sessionSelect: ListSelect = ListSelect()
    private var sessionSelectList: ArrayList<(String, String)> = ArrayList<(String, String)>()  // (id, summary) 映射，供 chosenId 查询
    // 当前视图：0=对话 1=帮助
    private var viewMode: Int64 = 0
    // 帮助页滚动偏移（帮助内容超一屏时可滚）
    private var helpScroll: Int64 = 0
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
        "/help", "/new", "/resume", "/model", "/provider", "/skills", "/compact", "/tree", "/fork", "/settings", "/task", "/theme", "/quit",
    ]

    // 事件回调：提交输入时触发（外部接线）
    public var onSubmit: (String) -> Unit = { _ => }
    // 中断回调（P0-2）：Ctrl+C 且 agent 忙时触发，外部接线到 agent.interrupt()
    public var onInterrupt: () -> Unit = { => }
    // 两级 Ctrl+C：agent 忙时第一次请求中断（interruptPending=true），
    // 第二次强制退出进程——agent 线程可能卡在 OS 深处（connect/DNS/TLS/
    // 工具子进程），中断无法保证生效，强退是唯一 100% 可靠兜底
    private var interruptPending: Bool = false
    // 强制退出回调（测试可注入替换 exit；默认恢复终端 + 退出进程）
    // 默认空——字段初始化阶段不能调方法（类未构造完），init 里接线
    public var onForceQuit: () -> Unit = { => }

    // provider 配置表单提交回调（外部接线；参数：provider/baseUrl/model/apiKey/protocol）
    public var onProviderSubmit: (String, String, String, String, String) -> Unit = { _, _, _, _, _ => }

    // 主题确认回调（外部接线；参数：主题名）—— Enter 确认时触发，写回 settings.json
    public var onThemeApply: (String) -> Unit = { _ => }

    // /resume 会话选择确认回调（外部接线；参数：session id）—— Enter 选中时触发
    public var onSessionResume: (String) -> Unit = { _ => }

    public init() {
        // 空闲超时秒数（CJH_IDLE_TIMEOUT_SECS 可配，默认 180）
        var to: Int64 = 180
        try {
            let v = TermEnv.getenv("CJH_IDLE_TIMEOUT_SECS") ?? ""
            if (v.size > 0) {
                let parsed = Int64.parse(v)
                if (parsed >= 10) {
                    to = parsed
                }
            }
        } catch (e: Exception) {
            // 非法配置用默认
        }
        this.idleTimeoutSecs = to
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
            // 转发：index 0=provider 1=protocol 2=base_url 3=model 4=api_key
            if (values.size >= 5) {
                this.onProviderSubmit(values[0], values[2], values[3], values[4], values[1])
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
        // 强制退出默认实现：恢复终端 + 退出进程（须在全部字段初始化后接线，
        // 测试可注入替换 onForceQuit 避免真退出）
        this.onForceQuit = { => this.forceQuitImpl() }
        // 输入历史：启动加载（↑↓ 切换上次输入，对齐 omp/通用 CLI）
        this.loadHistory()
        // 草稿恢复：上次退出时未提交的输入（不触发 onChange）
        this.loadDraft()
        // 输入框回调接线
        // 变更 → 刷新 / 命令候选
        this.inputBox.onChange = { _ =>
            this.refreshCandidates()
        }
        // 提交（Enter）→ 下拉确认 + 输出回显 + 外部 onSubmit
        this.inputBox.onSubmit = { line =>
            // /theme 交互式选择：picker 选中后确认当前预览主题
            if (this.themePickerMode) {
                this.themePickerMode = false
                let cur = this.picker.current()
                this.inputBox.clear()
                this.picker.hide()
                if (cur.size > 0) {
                    // 预览已 apply，这里只需持久化
                    Theme.apply(cur)
                    this.onThemeApply(cur)
                    this.appendOutput(Ansi.fg(Ansi.THEME_OK) +
                        "[主题已切换: ${cur}]" + Ansi.reset())
                }
                this.markDirty()
                return
            }
            // 下拉框可见时：Enter 确认当前选中项（否则提交原始输入）
            var finalLine = line
            if (this.picker.isVisible()) {
                let cur = this.picker.current()
                if (cur.size > 0) {
                    finalLine = cur
                }
                this.safeLog("debug", "enter+pick: 选中项='${cur}' -> inputLine='${finalLine}'")
            }
            this.inputBox.clear()
            this.picker.hide()
            if (finalLine.size > 0) {
                this.safeLog("info", "submit: '${finalLine}'")
                this.appendOutput("")  // 空行：与上一轮回复分隔
                // 回显：大粘贴折叠为 [Paste #N] marker（对齐 omp/通用 CLI），
                // 完整内容随提交进入 agent 会话；历史持久化
                let echoLine = this.inputBox.lastEchoText()
                this.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() +
                    (if (echoLine.size > 0) { echoLine } else { finalLine }))
                this.saveHistory()
                this.appendOutput("")  // 空行：分隔用户输入与 Agent 回复
                // 方案 B：Agent 执行期间提交的消息入队，执行完毕后自动处理。
                // 不在 transcript 追加"已入队"提示（处理后残留误导，且污染会话存档）——
                // 排队状态由动态状态行实时显示（"排队 N 条"），agent 结束自动消失。
                // busy || 队列非空都入队：堵住 run 结束→下一条启动的窗口期
                // （否则该窗口提交的消息绕过队列、与续跑消息并发执行同一 Agent）
                if (this.isAgentBusy() || this.queueLength() > 0) {
                    this.enqueueInput(finalLine)
                } else {
                    this.onSubmit(finalLine)
                }
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
        // 注意：不强制发送 ESC[?2004h 开启 bracketed paste——实测部分真实终端
        // 开启后粘贴闭合检测失败，readBracketedPaste 吞后续按键（Backspace/方向键
        // 变 DDDD、删不掉）。保持默认裸流粘贴（逐字符，行为可预期）；
        // 若终端自行发送 ESC[200~ 包裹，readKey 仍识别为单次粘贴事件。
        this.render()

        // 动态状态行计时刷新：agent 执行中时每秒强制 markDirty，
        // 让 "Thinking… (Ns · ↑ M tokens)" 的计时按秒递增
        var lastTick: DateTime = DateTime.now()
        while (this.running) {
            if (let Some(key) <- this.term.readKey()) {
                this.handleKey(key)
            }
            // resize 感知：终端尺寸变化时立即重绘
            // （空闲时 resize 不产生输入事件，依赖每帧尺寸查询对比触发）
            if (this.term.sizeChanged()) {
                this.markDirty()
            }
            // agent 执行中：每 1 秒触发一次重绘（刷新计时/token 计数）
            if (this.isAgentBusy()) {
                let now = DateTime.now()
                if ((now - lastTick).toSeconds() >= 1) {
                    lastTick = now
                    this.markDirty()
                }
                // 空闲检测：idleTimeoutSecs 无活动（模型停滞、流无帧）→ 自动中断，
                // 避免 Streaming… 无限计时 + 新消息僵持排队。
                // 触发后重置计时（重新武装）：若中断未生效（连接/异常路径卡死），
                // 下个超时周期再次告警+中断，持续升级直到恢复
                let idleSecs = (now - this.agentLastActivity).toSeconds()
                if (idleSecs > this.idleTimeoutSecs && !this.idleWarned) {
                    this.idleWarned = true
                    // 看门狗已请求中断：置 interruptPending——若中断未生效
                    // （线程卡死），用户下次 Ctrl+C 直接强制退出
                    this.interruptPending = true
                    this.appendOutput(Ansi.fg(Ansi.THEME_WARN) +
                        "⚠️ 模型 ${idleSecs}s 无响应（可能停滞），已请求中断。有数据恢复则立即停止。" +
                        Ansi.reset())
                    this.onInterrupt()
                    // 重新武装：若仍未恢复，等满一个超时周期再次中断
                    this.agentLastActivity = now
                }
            }
            if (this.takeDirty()) {
                this.render()
            }
            sleep(Duration.millisecond * 5)
        }

        this.restoreTerminal()
    }

    /**
     * 恢复终端：关 raw 模式 + 显示光标 + 清屏
     * 供 run() 正常退出和 main() finally 异常退出兜底调用
     */
    public func restoreTerminal(): Unit {
        this.saveDraft()  // 退出前保存未提交输入（启动时恢复）
        this.term.disableRaw()
        print(Ansi.showCursor(), flush: true)
        print(Ansi.clearScreen(), flush: true)
    }

    /**
     * 输入历史持久化文件（~/.cjh/history 或 CJH_CONFIG_DIR/history）
     */
    private func historyPath(): String {
        var dir = ""
        try {
            let cfgDir = TermEnv.getenv("CJH_CONFIG_DIR") ?? ""
            if (cfgDir.size > 0) {
                dir = cfgDir
            } else {
                let home = TermEnv.getenv("HOME") ?? ""
                if (home.size > 0) {
                    dir = home + "/.cjh"
                }
            }
        } catch (e: Exception) {
            dir = ""
        }
        if (dir.size == 0) {
            return "/tmp/cjh_history"  // 兜底
        }
        return dir + "/history"
    }

    /**
     * 加载输入历史（启动时）：每行一条，旧在前
     */
    private func loadHistory(): Unit {
        try {
            let f = File(this.historyPath(), OpenMode.Read)
            var lines = ArrayList<String>()
            let buf = Array<Byte>(4096, repeat: 0)
            var pending = ""
            while (true) {
                let n = f.read(buf)
                if (n <= 0) {
                    break
                }
                pending += safeFromUtf8(buf[0..n])
            }
            f.close()
            for (line in pending.split("\n", -1)) {
                var l = line
                if (l.size > 0 && l[l.size - 1] == 13u8) {  // 剥 \r
                    l = l[0..l.size - 1]
                }
                if (l.size > 0) {
                    lines.add(l)
                }
            }
            this.inputBox.setHistory(lines)
        } catch (e: Exception) {
            // 无历史文件/读失败：忽略
        }
    }

    /**
     * 保存输入历史（提交后）：整体写文件（上限 50 条，开销可忽略）
     */
    private func saveHistory(): Unit {
        try {
            let path = this.historyPath()
            let f = File(path, OpenMode.Write)
            var sb = StringBuilder()
            for (h in this.inputBox.historyList()) {
                sb.append(h)
                sb.append("\n")
            }
            f.write(sb.toString().toArray())
            f.close()
        } catch (e: Exception) {
            // 写失败忽略（历史持久化非关键）
        }
    }

    /**
     * 保存输入草稿（退出/强退前）：未提交的输入内容写 <configDir>/draft
     */
    private func saveDraft(): Unit {
        try {
            let text = this.inputBox.text()
            if (text.size == 0) {
                return  // 无草稿不写
            }
            let path = this.historyPath().replace("history", "draft")
            let f = File(path, OpenMode.Write)
            f.write(text.toArray())
            f.close()
        } catch (e: Exception) {
            // 写失败忽略（草稿恢复非关键）
        }
    }

    /**
     * 加载草稿（启动时）：上次退出未提交的输入恢复进输入框（不触发 onChange）
     */
    private func loadDraft(): Unit {
        try {
            let path = this.historyPath().replace("history", "draft")
            let f = File(path, OpenMode.Read)
            let buf = Array<Byte>(16384, repeat: 0)
            var pending = ""
            while (true) {
                let n = f.read(buf)
                if (n <= 0) {
                    break
                }
                pending += safeFromUtf8(buf[0..n])
            }
            f.close()
            if (pending.size > 0) {
                this.inputBox.setTextSilent(pending)
            }
        } catch (e: Exception) {
            // 无草稿/读失败忽略
        }
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

    // ── 测试观测（TUI 逻辑单测用；不触碰终端渲染）──

    /**
     * 安全日志：日志写入异常绝不带崩主循环。
     * 实测：Backspace(ch=127) 等控制字符触发 stdx.logger quotedReplace
     * IndexOutOfBoundsException——真实用户按退格会崩 TUI，必须防御。
     */
    private func safeLog(level: String, msg: String): Unit {
        try {
            match (level) {
                case "debug" => this.logger.debug(msg)
                case "info" => this.logger.info(msg)
                case _ => this.logger.warn(msg)
            }
        } catch (e: Exception) {
            // 日志失败忽略：TUI 主流程优先
        }
    }

    public func testRunning(): Bool { return this.running }
    public func testInputText(): String { return this.inputBox.text() }
    public func testPickerVisible(): Bool { return this.picker.isVisible() }
    public func testPickerCurrent(): String { return this.picker.current() }
    public func testViewMode(): Int64 { return this.viewMode }
    public func testEditMode(): Bool { return this.editMode }

    /**
     * 设置 Agent 执行状态（方案 B：执行期间输入可编辑，提交时入队 + 提示）
     * @param running true=Agent 开始执行；false=Agent 执行完毕
     */
    public func setAgentRunning(running: Bool): Unit {
        this.agentRunningLock.lock()
        this.agentRunning = running
        this.agentRunningLock.unlock()
        if (running) {
            this.agentStartTime = DateTime.now()
            this.agentRounds = 0
            this.agentTokenLock.lock()
            this.agentPromptTokens = 0
            this.agentTokenLock.unlock()
        } else {
            // 任务结束/中断生效：复位中断标记（下次 Ctrl+C 重新从"请求中断"开始）
            this.interruptPending = false
        }
        this.markDirty()
    }

    /**
     * 强制退出实现：恢复终端（raw mode 解除 + 显示光标）后退出进程。
     * 不等待 agent 线程——进程退出会终止一切线程
     */
    private func forceQuitImpl(): Unit {
        this.saveDraft()  // 强退前保存草稿
        this.safeLog("info", "Ctrl+C 强制退出：任务未能在中断后停止")
        try {
            this.term.disableRaw()
        } catch (e: Exception) {
            // 恢复失败忽略
        }
        print(Ansi.showCursor(), flush: true)
        unsafe {
            _exit(0)
        }
    }

    /**
     * 查询 Agent 是否正在执行
     */
    public func isAgentBusy(): Bool {
        this.agentRunningLock.lock()
        let busy: Bool = this.agentRunning
        this.agentRunningLock.unlock()
        return busy
    }

    /**
     * 设置 Agent 当前执行状态（实时状态行显示用）
     * 调用时机：chatStream 前="Thinking…"；onToolStart="Running <tool>"；onDelta="Streaming…"
     */
    public func setAgentState(state: String): Unit {
        this.agentState = state
        this.markDirty()
    }

    /**
     * 标记 Agent 有活动（流式增量/思考/工具回调调用）。
     * 供空闲检测：模型停滞（无任何帧）时自动中断，避免"Streaming… 一直计时"僵持
     */
    public func markAgentActivity(): Unit {
        this.agentLastActivity = DateTime.now()
        this.idleWarned = false
    }

    /**
     * 追加思考内容（reasoning_content 增量）——方案 B：思考并入消息流
     * 累积到 OutputView 的思考块（折叠/展开段），渲染在消息末尾，随输出滚动
     */
    public func appendReasoning(text: String): Unit {
        if (text.size == 0) { return }
        this.reasoningLock.lock()
        // 新一轮思考开始：上一轮已结束（done）则清空重启
        if (this.reasoningDone && this.reasoningBuffer.size > 0) {
            this.reasoningBuffer = ""
            this.reasoningDone = false
        }
        this.reasoningBuffer += text
        // 上限保护：超出截断保留尾部（最新思考内容）
        if (this.reasoningBuffer.size > this.reasoningMaxChars) {
            let cut = this.reasoningBuffer.size - this.reasoningMaxChars
            this.reasoningBuffer = this.reasoningBuffer[cut..this.reasoningBuffer.size]
        }
        this.outputView.setThinking(this.reasoningBuffer, this.reasoningDone)
        this.reasoningLock.unlock()
        this.markDirty()
    }

    /**
     * 思考结束标记（正式 content 开始调用）。内容保留（可 Ctrl+T 展开回看）
     */
    public func clearReasoning(): Unit {
        this.reasoningLock.lock()
        if (this.reasoningBuffer.size > 0 && !this.reasoningDone) {
            this.reasoningDone = true
            this.outputView.setThinking(this.reasoningBuffer, true)
            this.reasoningLock.unlock()
            this.markDirty()
        } else {
            this.reasoningLock.unlock()
        }
    }

    /**
     * 切换思考块展开/折叠（Ctrl+T）
     */
    public func toggleReasoning(): Unit {
        this.reasoningLock.lock()
        this.reasoningExpanded = !this.reasoningExpanded
        this.outputView.toggleThinking()
        this.reasoningLock.unlock()
        this.markDirty()
    }

    /**
     * 重置计时器（每轮 LLM 调用前调用，让计时从每轮开始计算）
     * 同时递增轮次计数（状态行"第 N 轮"）
     */
    public func resetAgentTimer(): Unit {
        this.agentStartTime = DateTime.now()
        this.agentRounds += 1
        this.markDirty()
    }

    /**
     * 设置 Agent 执行期间的精确 token 数（每轮 LLM 调用结束后的 usage）
     * 覆盖语义：精确值直接覆盖估算值，避免累加导致后续轮次的估算值无法更新
     */
    public func addAgentTokens(tokens: Int64): Unit {
        this.agentTokenLock.lock()
        this.agentPromptTokens = tokens
        this.agentTokenLock.unlock()
        this.markDirty()
    }

    /**
     * 设置流式 token 估算值（思考过程中实时更新）
     * 用估算值覆盖 agentPromptTokens，让动态状态栏显示实时增长的 token 数。
     * usage 精确值回传后，addAgentTokens 会再次累加精确值。
     */
    public func setAgentTokenEstimate(estimate: Int64): Unit {
        this.agentTokenLock.lock()
        // 估算值只增不减（避免帧间抖动），且只在实际 token 未回传前生效
        if (estimate > this.agentPromptTokens) {
            this.agentPromptTokens = estimate
        }
        this.agentTokenLock.unlock()
        // 思考中 token 计数同步到思考块折叠行（显示增长）
        this.reasoningLock.lock()
        if (this.reasoningBuffer.size > 0 && !this.reasoningDone) {
            this.outputView.setThinkingTokens(estimate)
        }
        this.reasoningLock.unlock()
        this.markDirty()
    }

    /**
     * 入队待发送消息（Agent 执行期间提交的输入）
     * @return 队列长度（用于提示"前面还有 N 条"）
     */
    public func enqueueInput(text: String): Int64 {
        this.inputQueueLock.lock()
        this.inputQueue.add(text)
        let len: Int64 = Int64(this.inputQueue.size)
        this.inputQueueLock.unlock()
        return len
    }

    /**
     * 出队下一条待发送消息（FIFO）
     * @return Some(text) 有消息；None 队列为空
     */
    public func dequeueInput(): Option<String> {
        this.inputQueueLock.lock()
        if (this.inputQueue.size == 0) {
            this.inputQueueLock.unlock()
            return None
        }
        let first: String = this.inputQueue[0]
        // 移除首元素：重建列表（ArrayList 无 removeAt）
        var rest: ArrayList<String> = ArrayList<String>()
        for (i in 1..this.inputQueue.size) {
            rest.add(this.inputQueue[i])
        }
        this.inputQueue = rest
        this.inputQueueLock.unlock()
        return Some(first)
    }

    /**
     * 查询输入队列长度
     */
    public func queueLength(): Int64 {
        this.inputQueueLock.lock()
        let len: Int64 = Int64(this.inputQueue.size)
        this.inputQueueLock.unlock()
        return len
    }

    /**
     * 弹出 provider 配置表单（/provider 无参数时调用）
     * Provider 字段为 select 下拉（deepseek/openai/glm/qwen/kimi/doubao/siliconflow），
     * ←→ 切换时联动填充对应 baseUrl/model 预设。
     *
     * 默认值策略：
     * - Provider select：按当前 base_url 推断（openai.com/bigmodel.cn/deepseek.com/
     *   dashscope/moonshot.cn/volces.com/siliconflow.cn 匹配；**未匹配 = custom 自定义**
     *   ——聚合/中转平台（如 taotoken.net）显示 custom，端点/模型保留真实配置）
     * - 协议字段：custom 时可选择接入协议（openai=OpenAI 兼容 / anthropic=Messages /
     *   gemini 预留）；预设 provider 固定 openai
     * - 端点/模型：**预填当前真实配置**（体现 deepseek-v4-flash 等实际使用的值）——
     *   切换 ←→ 到其他预设时联动覆盖为该家预设；切到 custom 时保持不覆盖
     * - API Key **不预填**（各家 key 独立且敏感，预填会误导——切到未配置的
     *   家仍显示当前 key 的星号）；留空保存时 applyProvider 保留原 key
     */
    public func showProviderDialog(currentBaseUrl: String, currentModel: String, currentApiKey: String,
        currentProtocol: String): Unit {
        // 根据当前 base_url 推断 provider（预设匹配；未匹配 = custom 自定义/聚合）
        var provider = "custom"
        if (currentBaseUrl.contains("openai.com")) {
            provider = "openai"
        } else if (currentBaseUrl.contains("bigmodel.cn")) {
            provider = "glm"
        } else if (currentBaseUrl.contains("deepseek.com")) {
            provider = "deepseek"
        } else if (currentBaseUrl.contains("dashscope")) {
            provider = "qwen"
        } else if (currentBaseUrl.contains("moonshot.cn")) {
            provider = "kimi"
        } else if (currentBaseUrl.contains("volces.com")) {
            provider = "doubao"
        } else if (currentBaseUrl.contains("siliconflow.cn")) {
            provider = "siliconflow"
        }

        this.providerDialog.clearFields()
        // 字段 0：Provider（select，含各家预设 + custom 自定义）
        let providers = ArrayList<String>()
        providers.add("deepseek")
        providers.add("openai")
        providers.add("glm")
        providers.add("qwen")
        providers.add("kimi")
        providers.add("doubao")
        providers.add("siliconflow")
        providers.add("custom")
        this.providerDialog.addSelectField("Provider", providers)
        // 字段 1：接入协议（select：openai / anthropic / gemini 预留）
        let protocols = ArrayList<String>()
        protocols.add("openai")
        protocols.add("anthropic")
        protocols.add("gemini")
        this.providerDialog.addSelectField("协议", protocols)
        // 字段 2：API 端点（text）
        this.providerDialog.addField("API 端点", "https://api.openai.com/v1/chat/completions", false)
        // 字段 3：模型（text）
        this.providerDialog.addField("模型", "gpt-4o-mini", false)
        // 字段 4：API Key（secret）
        this.providerDialog.addField("API Key", "sk-xxxx", true)
        // select 初始选中 = 推断的 provider（value 必须在 options 中）
        this.providerDialog.setFieldValue(0, provider)
        // 协议字段：仅 custom（自定义/聚合端点）可见——预设家均为 OpenAI 兼容，无需选择
        // 初始值：当前配置的 provider_protocol（"" → openai）
        let initProtocol = if (currentProtocol.size > 0) { currentProtocol } else { "openai" }
        this.providerDialog.setFieldValue(1, initProtocol)
        if (provider == "custom") {
            this.providerDialog.setFieldVisible(1, true)
        } else {
            this.providerDialog.setFieldVisible(1, false)
        }
        // 端点/模型预填当前真实配置（体现实际使用的模型，如 deepseek-v4-flash）
        this.providerDialog.setFieldValue(2, currentBaseUrl)
        this.providerDialog.setFieldValue(3, currentModel)
        // API Key 不预填（placeholder "sk-xxxx"；各家 key 独立，预填易误导）
        // select 联动：切换 Provider 时填充对应 baseUrl/model 预设；custom 保持不覆盖
        this.providerDialog.onSelectChange = { index, value =>
            if (index == 0) {
                if (value == "custom") {
                    // 自定义/聚合：端点/模型/协议保持用户输入，不覆盖；显示协议字段
                    this.providerDialog.setFieldVisible(1, true)
                } else {
                    let (b, m) = TuiApp.providerPresets(value)
                    this.providerDialog.setFieldValue(2, b)
                    this.providerDialog.setFieldValue(3, m)
                    // 预设家均为 OpenAI 兼容协议：固定 openai 且隐藏协议字段
                    this.providerDialog.setFieldValue(1, "openai")
                    this.providerDialog.setFieldVisible(1, false)
                }
                this.markDirty()
            }
        }
        this.providerDialog.show("配置 Provider", "[Enter]=保存 [Esc]=取消 [↑↓/Tab]切换字段 [←→]选择Provider")
        this.markDirty()
    }

    /**
     * 各家 provider 预设（端点 + 默认模型）。
     * 与 slash_command.cj 的 /provider 预设保持一致。
     */
    public static func providerPresets(name: String): (String, String) {
        match (name) {
            case "openai" => ("https://api.openai.com/v1/chat/completions", "gpt-4o-mini")
            case "glm" => ("https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash")
            case "qwen" => ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus")
            case "kimi" => ("https://api.moonshot.cn/v1", "moonshot-v1-8k")
            case "doubao" => ("https://ark.cn-beijing.volces.com/api/v3", "doubao-1-5-pro-32k-250115")
            case "siliconflow" => ("https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3")
            case _ => ("https://api.deepseek.com/v1/chat/completions", "deepseek-chat")
        }
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
     * 更新 Tasks 面板快照（Agent.onTodosChanged 回调调用）
     * @param items Agent 的 TodoItem 列表
     */
    public func updateTasks(items: ArrayList<TodoItem>): Unit {
        var snaps: ArrayList<TaskSnapshot> = ArrayList<TaskSnapshot>()
        for (item in items) {
            let state: TaskState = match (item.status) {
                case TodoStatus.Pending => TaskState.Pending
                case TodoStatus.InProgress => TaskState.InProgress
                case TodoStatus.Completed => TaskState.Completed
            }
            snaps.add(TaskSnapshot(item.id, item.content, state))
        }
        this.tasksPanel.updateSnapshots(snaps)
        this.markDirty()
    }

    /**
     * 弹出主题选择 picker（/theme 无参数时调用）
     * @param themes 可用主题名列表
     * @param current 当前主题名（picker 默认指向它）
     */
    public func showThemePicker(themes: ArrayList<String>, current: String): Unit {
        this.themePickerMode = true
        this.themePreviewOriginal = current  // 记录原主题，Esc 恢复用
        this.picker.show(themes)
        // 默认指向当前主题
        var idx: Int64 = 0
        for (i in 0..themes.size) {
            if (themes[i] == current) {
                idx = i
                break
            }
        }
        // picker.show 已重置 selected=0，需要手动移到当前主题
        while (this.picker.selectedIndex() < idx) {
            this.picker.next()
        }
        this.markDirty()
    }

    /**
     * /resume 交互式会话选择：进入选择模式
     * @param sessions (id, summary) 列表，按时间倒序
     */
    public func showSessionList(sessions: ArrayList<(String, String)>): Unit {
        this.sessionSelectList = sessions
        // 构造显示文本列表委托 ListSelect 渲染/按键
        let displayItems: ArrayList<String> = ArrayList<String>()
        for ((id, summary) in sessions) {
            displayItems.add("${id}  |  ${summary}")
        }
        this.sessionSelect.onSelect = { idx =>
            // Enter 选中：查 sessionSelectList 拿 id，转发外部 onSessionResume
            if (idx >= 0 && idx < this.sessionSelectList.size) {
                let id = this.sessionSelectList[idx][0]
                this.hideSessionList()
                this.onSessionResume(id)
            }
        }
        this.sessionSelect.onCancel = { =>
            this.hideSessionList()
        }
        this.sessionSelect.show(displayItems, "选择会话（上下箭头切换，Enter 恢复，Esc 取消）", 0)
        this.markDirty()
    }

    /**
     * 退出会话选择模式
     */
    public func hideSessionList(): Unit {
        this.sessionSelect.hide()
        this.sessionSelectList = ArrayList<(String, String)>()
        this.markDirty()
    }

    /**
     * 会话选择模式当前选中的 session id
     */
    public func sessionSelectChosenId(): ?String {
        if (!this.sessionSelect.visible) { return None }
        let idx = this.sessionSelect.selectedIndex
        if (this.sessionSelectList.size == 0) { return None }
        if (idx < 0 || idx >= this.sessionSelectList.size) { return None }
        return this.sessionSelectList[idx][0]
    }

    /**
     * 会话选择模式当前选中的 session summary（标题）
     */
    public func sessionSelectChosenSummary(): ?String {
        if (!this.sessionSelect.visible) { return None }
        let idx = this.sessionSelect.selectedIndex
        if (this.sessionSelectList.size == 0) { return None }
        if (idx < 0 || idx >= this.sessionSelectList.size) { return None }
        return this.sessionSelectList[idx][1]
    }

    /**
     * 是否处于会话选择模式
     */
    public func isSessionSelectMode(): Bool {
        return this.sessionSelect.visible
    }

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

    /**
     * 按键分发（主循环调用）。不依赖终端 FFI，仅改内部状态 + 组件分发——
     * 单元测试可直接构造 KeyEvent 驱动验证协议（输入/视图/编辑/补全/退出）。
     */
    public func handleKey(key: KeyEvent): Unit {
        // Ctrl+T：切换思考块展开/折叠（reasoning 内容回看）
        if (key.ch == 20 && !key.isEsc) {
            this.toggleReasoning()
            return
        }
        // Ctrl+C（P0-2）：审批等待中→拒绝审批；agent 忙→中断当前轮；
        // 空闲→第一次确认、第二次退出（防误触丢会话）
        if (key.isCtrlC) {
            // 若有等待中的审批：写回 false 让其解除阻塞（避免 agent 线程悬挂）
            this.approvalLock.lock()
            let hasPending = this.pendingApproval.isSome()
            if (hasPending) {
                this.approvalResult = Some(false)
                this.pendingApproval = None
            }
            this.approvalLock.unlock()
            if (hasPending) {
                return  // 审批拒绝：不退出、不中断任务
            }
            if (this.isAgentBusy()) {
                // 两级 Ctrl+C：第一次请求中断（优雅，保留已完成工作）；
                // 第二次强制退出进程——agent 线程可能卡在 OS 深处
                // （connect/DNS/TLS/工具子进程），中断无法保证生效
                if (this.interruptPending) {
                    this.onForceQuit()
                    return
                }
                this.interruptPending = true
                this.onInterrupt()
                this.safeLog("info", "Ctrl+C: 请求中断当前任务（再按一次强制退出）")
                this.appendOutput(Ansi.fg(Ansi.THEME_WARN) +
                    "⏹ 已请求中断当前任务，正在停止…（再按 Ctrl+C 强制退出）" + Ansi.reset())
                return
            }
            // 空闲：一次 Ctrl+C 直接退出（用户明确要求，无确认环节）
            this.safeLog("info", "Ctrl+C: 空闲，退出")
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
        // /resume 会话选择模式：按键全委托 ListSelect 组件
        if (this.sessionSelect.visible) {
            let r = this.sessionSelect.handleKey(key)
            match (r) {
                case ListSelectResult.Moved =>
                    this.markDirty()
                case ListSelectResult.Selected =>
                    // 由 main.cj runTui 轮询 sessionSelectChosenId 执行 resume
                    this.markDirty()
                case ListSelectResult.Cancelled =>
                    this.hideSessionList()
                case ListSelectResult.Ignored =>
                    ()   // 其他键吞掉，避免穿透到输入框
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
        // 用 safeLog：Backspace(ch=127) 等字符曾触发 stdx logger 越界崩 TUI
        this.safeLog("debug",
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
                // 主题预览模式：Esc 恢复原主题
                if (this.themePickerMode) {
                    this.themePickerMode = false
                    Theme.apply(this.themePreviewOriginal)
                    this.picker.hide()
                    this.markDirty()
                } else {
                    this.picker.hide()
                    this.markDirty()
                }
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
                // 主题预览：即时应用选中主题
                if (this.themePickerMode) {
                    Theme.apply(this.picker.current())
                }
                this.markDirty()
                return
            }
            if (key.isArrowDown) {
                this.picker.next()
                // 主题预览：即时应用选中主题
                if (this.themePickerMode) {
                    Theme.apply(this.picker.current())
                }
                this.markDirty()
                return
            }
            if (key.isTab) {
                let cur = this.picker.current()
                if (cur.size > 0) {
                    this.inputBox.setTextSilent(cur)
                }
                this.picker.hide()
                // 注意：不能在此调 refreshCandidates()——补全后的文本（如 /theme）
                // 仍以 "/" 开头无空格，会把刚隐藏的下拉框重新打开（实测 bug）
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
        // 帮助视图：PageUp/Down 滚动帮助内容（输出区滚动仅对话视图）
        if (this.viewMode == 1) {
            if (key.isPageUp || key.isCtrlU) {
                this.helpScroll -= 8
                if (this.helpScroll < 0) {
                    this.helpScroll = 0
                }
                this.markDirty()
                return
            }
            if (key.isPageDown || key.isCtrlD) {
                this.helpScroll += 8
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
     * 进入多行编辑模式：输入框内容带入编辑器，隐藏下拉框
     */
    private func editorEnter(): Unit {
        this.editor.setText(this.inputBox.text())
        this.editMode = true
        this.picker.hide()
        this.safeLog("info", "editor enter: text='${this.editor.text()}'")
        this.markDirty()
    }

    /**
     * 退出多行编辑模式：编辑器内容回填输入框（不提交）
     */
    private func editorExit(): Unit {
        this.inputBox.setTextSilent(this.editor.text())
        this.editMode = false
        this.safeLog("info", "editor exit: text='${this.inputBox.text()}'")
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
            this.safeLog("info", "editor submit: '${text}'")
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
        this.helpScroll = 0  // 切视图重置帮助滚动
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
                this.safeLog("debug", "candidates input='${line}' -> ${list.size} 项: ${list}")
            } else {
                this.picker.hide()
                this.safeLog("debug", "candidates input='${line}' -> 无匹配，隐藏")
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
        let editBoxH0: Int64 = if (this.editMode) {
            var h = this.editor.lineCount()
            if (h < 1) { h = 1 }
            if (h > 5) { h = 5 }
            h
        } else { 1 }

        // 是否显示欢迎视图（对话视图且输出区为空）
        this.outputLock.lock()
        let showWelcome = this.viewMode == 0 && this.outputView.content().size == 0
        this.outputLock.unlock()

        // 欢迎视图布局：欢迎视图固定顶部，状态行+输入框首次居中
        let welcomeContentH: Int64 = 12
        var inputTop: Int64 = rows - editBoxH0
        var statusRow: Int64 = inputTop - 1

        if (showWelcome) {
            // 欢迎视图固定从行 0 开始（顶部展示）
            this.welcomeView.render(this.canvas, 0, cols, welcomeContentH)
            // 状态行+输入框垂直居中在欢迎视图下方的剩余空间
            // 剩余空间 = rows - welcomeContentH，状态行+输入框占 2 行
            // 居中起始行 = welcomeContentH + (剩余空间 - 2) / 2
            let remain = rows - welcomeContentH
            if (remain > 2) {
                statusRow = welcomeContentH + (remain - 2) / 2
            } else {
                statusRow = welcomeContentH
            }
            inputTop = statusRow + 1
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

            // 动态状态行（agent 执行中）：渲染在输出区底部，与输出内容间隔 1 行
            // 布局（从上到下）：输出区(8..agentRow-1) → 空行(agentRow-1) → 动态状态行(agentRow) → Tasks 面板 → statusRow
            let agentBusy: Bool = this.isAgentBusy()
            // 预计算输出区全高（无动态状态行时），用于预计算 Tasks 面板高度
            let outH0: Int64 = if (statusRow - 8 > 0) { statusRow - 8 } else { 0 }
            // tasksH：Tasks 面板占用行数（无任务时为 0；maxH 用 outH0 限制，误差≤1 行可接受）
            let tasksH: Int64 = this.tasksPanel.height(outH0)
            // 动态状态行位置：statusRow - 1(间隔) - tasksH(面板高度) - 1(自身)
            // 无 agent 运行时，agentRow 不使用，仅用于 outH 计算
            let agentRow: Int64 = if (agentBusy) { statusRow - 1 - tasksH - 1 } else { -1 }

            // 思考块（方案 B）：作为消息流成员由 OutputView 渲染（折叠/展开段），
            // 不再占用独立布局区域——消息区高度恒定，思考随输出滚动回看
            // 输出区可用高度：8 .. outBottom（恒定）
            // agent 执行中：动态状态行上方；空闲：状态栏上方
            let outBottom: Int64 = if (agentBusy && agentRow >= 8) {
                agentRow - 1
            } else { statusRow - 1 }
            let outH: Int64 = if (outBottom - 8 + 1 > 0) { outBottom - 8 + 1 } else { 0 }

            // 输出区（对话 / 帮助视图，无边框全宽）
            if (this.viewMode == 1) {
                this.renderHelp(this.canvas, 8, cols, outH)
            } else if (this.sessionSelect.visible) {
                // /resume 会话选择：委托 ListSelect 组件渲染到输出区
                this.sessionSelect.paintCanvas(this.canvas, 8, cols, outH)
            } else {
                this.outputLock.lock()
                try {
                    this.outputView.render(this.canvas, 8, cols, outH)
                } finally {
                    this.outputLock.unlock()
                }
                // Tasks 面板：有任务时在输出区右下角渲染
                this.tasksPanel.render(this.canvas, statusRow - 1, cols, outH)
                // 动态状态行：agent 执行中时渲染在 Tasks 面板上方
                if (agentBusy && agentRow >= 8) {
                    this.spinner.tick()
                    this.renderAgentStatus(this.canvas, agentRow, cols)
                }
            }
        }

        // 静态状态栏：始终渲染在 statusRow（+-- # model > [ cwd ] > ready ->）
        // 滚动指示：输出区已向上滚动时右侧提示（PageUp 可回到底部）
        this.outputLock.lock()
        let scrolled = this.outputView.isScrolled()
        let scrollLines = this.outputView.scrollOffsetLines()
        this.outputLock.unlock()
        this.statusBar.setRightHint(if (scrolled) { " ↕ ↑${scrollLines}行" } else { "" })
        this.statusBar.render(this.canvas, statusRow, cols, 1)

        // 审批弹窗：模态覆盖，弹窗 4 行，紧贴输入区上方渲染
        if (this.confirmDialog.isVisible()) {
            let dlgRow = if (statusRow - 5 > 0) { statusRow - 5 } else { 0 }
            this.confirmDialog.render(this.canvas, dlgRow, cols, 4)
        }

        // 输入区（无边框：InputBox 带 ❯ 提示符 / MultiLineEditor 行号栏）
        if (this.editMode) {
            // 编辑器从 inputTop 起占 editBoxH0 行（顶到末行 rows-1）
            this.editor.render(this.canvas, inputTop, cols, editBoxH0)
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
     * Agent 执行中的实时状态行：⠏ Thinking… (5s · ↑ 102 tokens)
     * 状态来源：agentState 字段（由 setAgentState 更新）
     * 计时来源：agentStartTime（由 setAgentRunning(true) 记录）
     * token 来源：agentPromptTokens（由 addAgentTokens 累加）
     */
    private func renderAgentStatus(canvas: TuiCanvas, row: Int64, cols: Int64): Unit {
        let frame = this.spinner.frame()
        let elapsed = (DateTime.now() - this.agentStartTime).toSeconds()
        this.agentTokenLock.lock()
        let tokens = this.agentPromptTokens
        this.agentTokenLock.unlock()
        let stateLabel = if (this.agentState.size > 0) { this.agentState } else { "Working…" }
        // 排队消息数（执行期间提交、待自动发送）；0 时不显示
        let qLen: Int64 = this.queueLength()
        // 配色：spinner 青色动感 · 状态文字亮白醒目 · 计时淡灰辅助 · token 数琥珀金点睛
        var line = Ansi.fg(Ansi.THEME_ACCENT) + frame + " " + Ansi.reset() +
            Ansi.fg(Ansi.THEME_OK) + stateLabel + Ansi.reset() +
            Ansi.fg(Ansi.THEME_MUTED) + " (" + elapsed.toString() + "s · ↑ " + Ansi.reset() +
            Ansi.fg(Ansi.THEME_WARN) + tokens.toString() + Ansi.reset() +
            Ansi.fg(Ansi.THEME_MUTED) + " tokens" + Ansi.reset()
        // 多轮任务：显示当前轮次（用户可判断 run 在推进、排队消息还要等几轮）
        if (this.agentRounds > 1) {
            line += Ansi.fg(Ansi.THEME_MUTED) + " · 第 " + Ansi.reset() +
                Ansi.fg(Ansi.THEME_WARN) + this.agentRounds.toString() + Ansi.reset() +
                Ansi.fg(Ansi.THEME_MUTED) + " 轮" + Ansi.reset()
        }
        line += Ansi.fg(Ansi.THEME_MUTED) + ")" + Ansi.reset()
        if (qLen > 0) {
            line += Ansi.fg(Ansi.THEME_ACCENT) + " · 📥 排队 ${qLen} 条待发送" + Ansi.reset()
        }
        canvas.setLine(row, line)
    }

    /**
     * 思考窗口：最多 2 行滚动展示 reasoning_content
     *
     * 布局（占 3 行，从上到下）：
     *   row+0: 内容行 1（灰色，按显示宽度截断）
     *   row+1: 内容行 2（灰色，按显示宽度截断）+ 底边框
     *   row+2: 空行（与动态状态栏间隔）
     *
     * 截断策略：按显示宽度（displayWidth）计算，CJK/emoji 占 2 列；
     * 超出 2 行 × (cols-2) 时只显示最后 2 行。
     */
    /**
     * 帮助视图内容（无边框全宽渲染）
     */
    private func renderHelp(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Unit {
        let lines: ArrayList<String> = ArrayList<String>()
        lines.add(Ansi.fg(Ansi.THEME_ACCENT) + "可用命令：" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /help          显示本帮助" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /new           开始新会话" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /resume [id]   恢复历史会话（无 id 时列出）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /model [id|#]  列出/切换模型" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /provider      配置接入（端点/模型/协议/key）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /skills        查看/启用技能" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /compact       手动压缩历史（摘要）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /tree          会话树" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /fork          从当前分支分叉" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /task          查看/管理任务列表" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /theme         切换主题" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /settings      查看采样参数（temp/max_tokens）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  /quit          退出" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_ACCENT) + "输入：" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  ↑ / ↓          历史上下切换（滚轮亦可）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  / 开头 ↑↓     只翻 / 命令历史" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+R         历史搜索（输入子串过滤）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  长粘贴         自动折叠为 [Paste #N]（回车展开提交）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_ACCENT) + "快捷键：" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Tab / ←→       切换视图（对话/帮助）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+E         多行输入编辑（Alt+Enter 提交）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+T         思考过程展开/折叠（推理模型）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  PageUp/Down    输出区滚动（Ctrl+U/D 亦可）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+C         空闲退出 / 忙时中断，再按强制退出" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Esc            关闭弹窗 / 退出编辑 / 回对话视图" + Ansi.reset())
        var r: Int64 = 0
        var idx: Int64 = this.helpScroll
        while (idx < Int64(lines.size) && r < height) {
            canvas.setLine(row + r, lines[idx])
            r += 1
            idx += 1
        }
        // 滚动超出时标记（底部"更多"提示由状态栏滚动指示逻辑类似；简单截断）
    }
}
