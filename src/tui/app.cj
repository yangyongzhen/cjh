package cjh.tui

import std.env.*

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
    private var inputLine: String = ""
    private var running: Bool = true
    private var dirty: Bool = true

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
    }

    public func run(): Unit {
        this.term.enableRaw()
        print(Ansi.clearScreen())
        print(Ansi.hideCursor())
        this.render()

        while (this.running) {
            // 按键处理
            if (let Some(key) <- this.term.readKey()) {
                this.handleKey(key)
            }
            // 输出刷新（由 onOutputAppend 或提交触发）
            if (this.dirty) {
                this.render()
                this.dirty = false
            }
            // 让出 CPU
            sleep(Duration.millisecond * 5)
        }

        this.term.disableRaw()
        print(Ansi.showCursor())
        print(Ansi.clearScreen())
    }

    /**
     * 追加一行到输出区
     */
    public func appendOutput(text: String): Unit {
        this.output.append(text)
        if (text.size == 0 || text[text.size - 1] != 10u8) {
            this.output.append("\n")
        }
        this.dirty = true
    }

    private func handleKey(key: KeyEvent): Unit {
        if (key.isCtrlC) {
            this.running = false
            return
        }
        if (key.isEnter) {
            let line = this.inputLine
            this.inputLine = ""
            if (line.size > 0) {
                this.appendOutput("cjh> ${line}")
                this.onSubmit(line)
            }
            this.dirty = true
            return
        }
        if (key.isBackspace) {
            if (this.inputLine.size > 0) {
                this.inputLine = this.inputLine[0..this.inputLine.size - 1]
                this.dirty = true
            }
            return
        }
        // 可打印字符
        if (key.ch >= 32 && key.ch < 127) {
            this.inputLine += Rune(key.ch).toString()
            this.dirty = true
        }
    }

    private func render(): Unit {
        let (rows, cols) = TermSize.get()
        // 尺寸变化时重建
        if (rows != this.screen.rows || cols != this.screen.cols) {
            this.screen = Screen(rows, cols)
            this.prev = Screen(rows, cols)
        }

        // 输出区：最后 N-2 行
        let outLines = this.output.toString().split("\n", -1)
        let maxOut = rows - 3
        var startIdx = outLines.size - maxOut
        if (startIdx < 0) {
            startIdx = 0
        }

        var r: Int64 = 0
        // 标题
        this.screen.setLine(0, Ansi.bold() + "cjh — 仓颉 Coding Agent" + Ansi.reset())
        r = 1
        // 输出区
        for (i in startIdx..outLines.size) {
            if (r >= rows - 2) {
                break
            }
            this.screen.setLine(r, outLines[i])
            r += 1
        }
        // 输入行
        this.screen.setLine(rows - 2, Ansi.fg(Ansi.COLOR_CYAN) + "cjh> " + Ansi.reset() + this.inputLine + Ansi.clearLine())

        // 差分渲染
        let diff = this.screen.diff(this.prev)
        if (diff.size > 0) {
            print(diff)
        }
        // 光标定位到输入行末尾
        print(Ansi.moveTo(rows - 1, 6 + this.inputLine.size))
        this.prev = this.screen.clone()
    }
}
