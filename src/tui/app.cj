package cjh.tui

import std.env.*
import std.fs.*
import std.sync.*
import std.collection.*
import stdx.log.*
import stdx.logger.*
import cjterm.*

/**
 * TUI 应用：对话界面
 *
 * 布局（全量重绘，每行 moveTo 精确定位）：
 *   行 1    标题
 *   行 2..N 输出区（滚动）
 *   行 N-1  状态行（保存提示等）
 *   行 N    输入行 cjh>
 *
 * 关键设计（吸取教训）：
 * - 全量重绘 + 每行 moveTo + clearLine：避免 \n 链式换行的 wrap 漂移
 * - 行宽按码点截断：防终端自动换行破坏对齐
 * - output/dirty 用 Mutex：agent 在 spawn 线程写入，主循环渲染
 * - 所有 print 带 flush: true：即时上屏
 */
public class TuiApp {
    private let term: Term
    private var output: StringBuilder
    private var outputLock: Mutex
    private var inputLine: String = ""
    private var running: Bool = true
    private var dirty: Bool = true
    private var dirtyLock: Mutex = Mutex()
    private var renderLock: Mutex = Mutex()
    private var scrollOffset: Int64 = 0
    private var statusLine: String = ""
    private var modelName: String = ""
    // 流式段起点（output 中的字节偏移；-1 表示无活动流式段）
    private var streamStartPos: Int64 = -1
    // 差分渲染：上次每行已渲染内容（尺寸变化/首帧时清空强制全量重绘）
    private var prevLines: ArrayList<String> = ArrayList<String>()
    // / 命令下拉补全框（ListPicker 组件）
    private var picker: ListPicker = ListPicker()
    // 文件日志（TUI stderr 被屏蔽，写文件排查按键/下拉框问题）
    private var logger: Logger = NoopLogger()

    // 斜杠命令候选（对齐 main.cj handleSlashCommand 支持的命令）
    private static let SLASH_COMMANDS: Array<String> = [
        "/help", "/new", "/resume", "/model", "/settings", "/quit",
    ]

    // 事件回调：提交输入时触发
    public var onSubmit: (String) -> Unit = { _ => }

    public init() {
        this.term = Term()
        this.output = StringBuilder()
        this.outputLock = Mutex()
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
            this.output.append(text)
            if (text.size == 0 || text[text.size - 1] != 10u8) {
                this.output.append("\n")
            }
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
            if (this.streamStartPos < 0) {
                // 记录流式段起点（append 起点必为合法字符边界，可安全切片）
                this.streamStartPos = this.output.toString().size
            }
            this.output.append(text)
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
            if (this.streamStartPos >= 0) {
                let full = this.output.toString()
                var head = ""
                if (this.streamStartPos > 0) {
                    head = full[0..this.streamStartPos]
                }
                // 重建 StringBuilder：截断回流式段起点，再追加最终文本
                let nb = StringBuilder()
                nb.append(head)
                this.output = nb
                this.streamStartPos = -1
            }
            this.output.append(text)
        } finally {
            this.outputLock.unlock()
        }
        this.markDirty()
    }

    /**
     * 设置底部状态行（线程安全）
     */
    public func setStatus(text: String): Unit {
        this.statusLine = text
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
        // 文件日志：记录每个按键的完整形态（排查方向键/下拉框问题）
        this.logger.debug(
            "key ch=${key.ch} esc=${key.escapeSeq} text='${key.text}' " +
            "up=${key.isArrowUp} down=${key.isArrowDown} tab=${key.isTab} " +
            "enter=${key.isEnter} back=${key.isBackspace} mouse=${key.isMouse} " +
            "picker=${this.picker.isVisible()}")
        if (key.isCtrlC) {
            this.running = false
            return
        }
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
                    this.inputLine = cur
                }
                this.picker.hide()
                this.refreshCandidates()
                this.markDirty()
                return
            }
        }
        if (key.isCtrlU || key.isPageUp) {
            this.scrollUp(8)
            this.markDirty()
            return
        }
        if (key.isCtrlD || key.isPageDown) {
            this.scrollDown(8)
            this.markDirty()
            return
        }
        if (key.isEnter) {
            // 下拉框可见时：Enter 确认当前选中项（否则提交原始输入）
            if (this.picker.isVisible()) {
                let cur = this.picker.current()
                if (cur.size > 0) {
                    this.inputLine = cur
                }
                this.logger.debug("enter+pick: 选中项='${cur}' -> inputLine='${this.inputLine}'")
            }
            let line = this.inputLine
            this.inputLine = ""
            this.picker.hide()
            if (line.size > 0) {
                this.logger.info("submit: '${line}'")
                this.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + line)
                this.onSubmit(line)
            }
            this.markDirty()
            return
        }
        if (key.isBackspace) {
            if (this.inputLine.size > 0) {
                // 按 UTF-8 字符删除（非字节）：从末尾递减试切片，直到合法字符边界
                var cut = this.inputLine.size - 1
                while (cut >= 0) {
                    try {
                        this.inputLine = this.inputLine[0..cut]
                        break
                    } catch (e: Exception) {
                        cut -= 1
                    }
                }
                this.refreshCandidates()
                this.markDirty()
            }
            return
        }
        // 可打印字符（含中文等多字节 UTF-8）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace) {
            this.inputLine += key.text
            this.refreshCandidates()
            this.markDirty()
        }
    }

    /**
     * 根据当前输入刷新 / 命令下拉候选（输入以 "/" 开头且无空格时弹出）
     */
    private func refreshCandidates(): Unit {
        let line = this.inputLine
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

    private func scrollUp(n: Int64): Unit {
        this.scrollOffset += n
        // 上限由 render 修正
    }

    private func scrollDown(n: Int64): Unit {
        this.scrollOffset -= n
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
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

        this.outputLock.lock()
        let outStr = this.output.toString()
        this.outputLock.unlock()
        let outLines = outStr.split("\n", -1)

        // 布局：行1-5 logo；行6 标题；行7 分隔；行8..输出区；rows-1 状态；rows 输入
        let maxOut = rows - 7
        let maxOffset = if (outLines.size > maxOut) { outLines.size - maxOut } else { 0 }
        if (this.scrollOffset > maxOffset) {
            this.scrollOffset = maxOffset
        }
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
        var startIdx = outLines.size - maxOut - this.scrollOffset
        if (startIdx < 0) {
            startIdx = 0
        }

        // 尺寸变化探测：首帧或 resize 时清空行缓存，强制全量重绘
        if (this.term.sizeChanged()) {
            this.prevLines = ArrayList<String>()
        }

        // 本次渲染各行内容（与 prevLines 对比，只输出变化行）
        var lines = ArrayList<String>()
        for (i in 0..rows) {
            lines.add("")
        }

        let utf8 = this.term.isUtf8()
        // logo 区（5 行，box-drawing CJ 徽标）
        let logoLines = Logo.renderLines(utf8)
        var li: Int64 = 0
        for (l in logoLines) {
            lines[li] = this.truncateLine(l, cols)
            li += 1
        }
        // 标题栏（logo 下方独立行）
        lines[5] = this.truncateLine(Logo.titleBar(utf8, this.modelName), cols)
        // 分隔线
        lines[6] = this.truncateLine(Logo.separator(cols, utf8), cols)

        // 输出区（从行 8 开始）
        var r: Int64 = 0
        for (i in startIdx..outLines.size) {
            if (r >= maxOut - 2) {
                break
            }
            lines[r + 7] = this.truncateLine(outLines[i], cols)
            r += 1
        }

        // 状态行（徽章：模型 + 会话 + 滚动提示）
        var status = this.statusLine
        if (status.size == 0) {
            status = Logo.badge("ready", Ansi.THEME_OK)
        }
        lines[rows - 2] = this.truncateLine(status, cols)

        // 输入行
        lines[rows - 1] = Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + this.inputLine

        // / 命令下拉补全框：紧贴输入行上方渲染（覆盖状态行区域，最多 6 行）
        if (this.picker.isVisible() && this.picker.size() > 0) {
            let pickerRows = if (this.picker.size() > 6) { 6 } else { this.picker.size() }
            let rendered = this.picker.render(pickerRows)
            for (pi in 0..pickerRows) {
                let lineIdx = rows - 1 - pickerRows + pi
                if (lineIdx >= 8 && lineIdx <= rows - 1) {
                    lines[lineIdx] = this.truncateLine(rendered[pi], cols)
                }
            }
        }

        // 差分渲染：逐行对比，只重绘变化行（省掉未变化区域的 ANSI 输出）
        var sb = StringBuilder()
        for (i in 0..rows) {
            let content = lines[i]
            if (this.prevLines.size <= i || this.prevLines[i] != content) {
                sb.append(Ansi.moveTo(i + 1, 1))
                sb.append(Ansi.clearLine())
                sb.append(content)
                // 扩容并写入缓存
                while (this.prevLines.size <= i) {
                    this.prevLines.add("")
                }
                this.prevLines[i] = content
            }
        }

        // 光标定位到输入末尾（按字符数，中文输入时光标不错位）
        var cur = 3
        for (c in this.inputLine) {
            cur += 1
        }
        sb.append(Ansi.moveTo(rows, cur))
        print(sb.toString(), flush: true)
    }

    /**
     * 截断行到列宽（按码点，防终端自动换行破坏对齐）
     */
    private func truncateLine(text: String, cols: Int64): String {
        if (text.size <= cols - 1) {
            return text
        }
        // 字节安全截断：从目标字节数递减，直到落在字符边界（非边界切片抛异常）
        var k = cols - 1
        while (k > 0) {
            try {
                return text[0..k]
            } catch (e: Exception) {
                k -= 1
            }
        }
        return ""
    }
}
