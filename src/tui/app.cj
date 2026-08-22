package cjh.tui

import std.env.*
import std.sync.*
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

    // 事件回调：提交输入时触发
    public var onSubmit: (String) -> Unit = { _ => }

    public init() {
        this.term = Term()
        this.output = StringBuilder()
        this.outputLock = Mutex()
    }

    public func run(): Unit {
        this.term.enableRaw()
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
            this.output.append(text)
        } finally {
            this.outputLock.unlock()
        }
        this.markDirty()
        // 由主循环统一渲染（跨线程直接 render 会导致并发写 stdout、光标错乱）
    }

    /**
     * 设置底部状态行（线程安全）
     */
    public func setStatus(text: String): Unit {
        this.statusLine = text
        this.markDirty()
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
        if (key.isCtrlC) {
            this.running = false
            return
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
            let line = this.inputLine
            this.inputLine = ""
            if (line.size > 0) {
                this.appendOutput("cjh> ${line}")
                this.onSubmit(line)
            }
            this.markDirty()
            return
        }
        if (key.isBackspace) {
            if (this.inputLine.size > 0) {
                this.inputLine = this.inputLine[0..this.inputLine.size - 1]
                this.markDirty()
            }
            return
        }
        if (key.ch >= 32 && key.ch < 127) {
            this.inputLine += Rune(key.ch).toString()
            this.markDirty()
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

        var sb = StringBuilder()
        sb.append(Ansi.clearScreen())

        let utf8 = this.term.isUtf8()
        // logo 区（5 行，box-drawing CJ 徽标）
        let logoLines = Logo.renderLines(utf8)
        var li: Int64 = 0
        for (l in logoLines) {
            sb.append(Ansi.moveTo(li + 1, 1))
            sb.append(Ansi.clearLine())
            sb.append(this.truncateLine(l, cols))
            li += 1
        }
        // 标题栏（logo 下方独立行）
        sb.append(Ansi.moveTo(6, 1))
        sb.append(Ansi.clearLine())
        sb.append(Logo.titleBar(utf8, this.modelName))

        // 分隔线
        sb.append(Ansi.moveTo(7, 1))
        sb.append(Ansi.clearLine())
        sb.append(this.truncateLine(Logo.separator(cols, utf8), cols))

        // 输出区（从行 8 开始）
        var r: Int64 = 0
        for (i in startIdx..outLines.size) {
            if (r >= maxOut - 2) {
                break
            }
            sb.append(Ansi.moveTo(r + 8, 1))
            sb.append(Ansi.clearLine())
            sb.append(this.truncateLine(outLines[i], cols))
            r += 1
        }

        // 状态行（徽章：模型 + 会话 + 滚动提示）
        sb.append(Ansi.moveTo(rows - 1, 1))
        sb.append(Ansi.clearLine())
        var status = this.statusLine
        if (status.size > 0) {
            sb.append(this.truncateLine(status, cols))
        } else {
            sb.append(Logo.badge("ready", Ansi.THEME_OK))
        }

        // 输入行
        sb.append(Ansi.moveTo(rows, 1))
        sb.append(Ansi.clearLine())
        sb.append(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + this.inputLine)

        // 光标定位到输入末尾
        sb.append(Ansi.moveTo(rows, 3 + this.inputLine.size))
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
