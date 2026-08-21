package cjh.tui

import std.env.*
import std.sync.*
import cjterm.*

/**
 * TUI 应用：简单对话界面
 *
 * 布局：
 *   ┌──────────────────────────┐
 *   │ 输出区（滚动，历史消息）   │
 *   ├──────────────────────────┤
 *   │ 输入行: cjh> …            │
 *   └──────────────────────────┘
 *
 * 差分渲染：维护 screen 期望状态，仅输出变化行。
 */
public class TuiApp {
    private let term: Term
    private var screen: Screen
    private var prev: Screen
    private var output: StringBuilder
    private var outputLock: Mutex
    private var inputLine: String = ""
    private var running: Bool = true
    private var dirty: Bool = true
    private var dirtyLock: Mutex = Mutex()
    private var scrollOffset: Int64 = 0
    private var statusLine: String = ""

    // 事件回调：提交输入时触发
    public var onSubmit: (String) -> Unit = { _ => }
    // 追加输出后刷新
    public var onOutputAppend: (String) -> Unit = { _ => }

    public init() {
        this.term = Term()
        let (rows, cols) = TermSize.get()
        this.screen = Screen(rows, cols)
        this.prev = Screen(rows, cols)
        this.output = StringBuilder()
        this.outputLock = Mutex()
    }

    public func run(): Unit {
        this.term.enableRaw()
        print(Ansi.clearScreen(), flush: true)
        print(Ansi.hideCursor(), flush: true)
        this.render()

        while (this.running) {
            // 按键处理
            if (let Some(key) <- this.term.readKey()) {
                this.handleKey(key)
            }
            // 输出刷新（由 onOutputAppend 或提交触发）
            if (this.takeDirty()) {
                this.render()
            }
            // 让出 CPU
            sleep(Duration.millisecond * 5)
        }

        this.term.disableRaw()
        print(Ansi.showCursor(), flush: true)
        print(Ansi.clearScreen(), flush: true)
    }

    /**
     * 追加一行到输出区
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
        // 立即渲染一次，实现流式效果
        this.render()
    }

    private func handleKey(key: KeyEvent): Unit {
        if (key.isCtrlC) {
            this.running = false
            return
        }
        // 滚动：PageUp/PageDown + Ctrl-U/Ctrl-D
        if (key.isCtrlU) {
            this.scrollUp(10)
            this.markDirty()
            return
        }
        if (key.isCtrlD) {
            this.scrollDown(10)
            this.markDirty()
            return
        }
        if (key.isPageUp) {
            this.scrollUp(5)
            this.markDirty()
            return
        }
        if (key.isPageDown) {
            this.scrollDown(5)
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
        // 可打印字符
        if (key.ch >= 32 && key.ch < 127) {
            this.inputLine += Rune(key.ch).toString()
            this.markDirty()
        }
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

    /**
     * 设置底部状态行（保存提示等，不污染输出区）
     */
    public func setStatus(text: String): Unit {
        this.statusLine = text
        this.markDirty()
    }

    private func scrollUp(n: Int64): Unit {
        let (rows, _) = TermSize.get()
        let maxOut = rows - 3
        this.outputLock.lock()
        let outStr = this.output.toString()
        this.outputLock.unlock()
        let outLines = outStr.split("\n", -1)
        let maxOffset = if (outLines.size > maxOut) { outLines.size - maxOut } else { 0 }
        this.scrollOffset += n
        if (this.scrollOffset > maxOffset) {
            this.scrollOffset = maxOffset
        }
    }

    private func scrollDown(n: Int64): Unit {
        this.scrollOffset -= n
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
    }

    private func render(): Unit {
        let (rows, cols) = TermSize.get()
        // 尺寸变化时重建
        if (rows != this.screen.rows || cols != this.screen.cols) {
            this.screen = Screen(rows, cols)
            this.prev = Screen(rows, cols)
        }

        // 输出区：滚动显示（offset=0 最新，向上翻看历史）
        this.outputLock.lock()
        let outStr = this.output.toString()
        this.outputLock.unlock()
        let outLines = outStr.split("\n", -1)
        let maxOut = rows - 3
        let maxOffset = if (outLines.size > maxOut) { outLines.size - maxOut } else { 0 }
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
        if (this.scrollOffset > maxOffset) {
            this.scrollOffset = maxOffset
        }
        var startIdx = outLines.size - maxOut - this.scrollOffset
        if (startIdx < 0) {
            startIdx = 0
        }

        // 全量重绘（可靠优先）：标题 + 输出区 + 状态行 + 输入行
        var sb = StringBuilder()
        sb.append(Ansi.clearScreen())
        sb.append(Ansi.moveTo(1, 1))
        sb.append(Ansi.bold() + "cjh - Cangjie Coding Agent" + Ansi.reset() + "\n")
        var r: Int64 = 0
        for (i in startIdx..outLines.size) {
            if (r >= maxOut) {
                break
            }
            sb.append(outLines[i] + "\n")
            r += 1
        }
        // 状态行
        sb.append(Ansi.fg(Ansi.COLOR_DARK) + this.statusLine + Ansi.reset() + "\n")
        // 输入行
        sb.append(Ansi.fg(Ansi.COLOR_CYAN) + "cjh> " + Ansi.reset() + this.inputLine)
        print(sb.toString(), flush: true)
    }
}
