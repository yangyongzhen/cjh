package cjterm

import std.collection.*

/**
 * MultiLineEditor：多行文本编辑器组件（可复用）
 *
 * - 行缓冲区（ArrayList<String>，每行一个 String）
 * - 光标：row 为逻辑行号（0-based），col 为行内码点位置（0-based）
 * - 光标移动：方向键（上/下保持目标列，左右逐码点）
 * - 编辑：可打印字符插入、Enter 拆行、Backspace 删除（行首合并上一行）、
 *   Ctrl+D 删除（行尾合并下一行）
 * - 翻页：PageUp/PageDown 光标上下移动 8 行；渲染时自动滚动保持光标可见
 * - UTF-8 字节安全：所有行内操作经 toRuneArray 逐码点重建，不切碎多字节字符
 * - 消费按键：方向键/Enter/Backspace/Ctrl+D/PageUp/PageDown/可打印字符
 *
 * 用途：长文本起草、配置编辑、prompt 编写（可复用，不绑 agent 逻辑）。
 */
public class MultiLineEditor <: Component {
    private var lines: ArrayList<String> = ArrayList<String>()
    // 光标：行号 + 行内码点位置
    private var row: Int64 = 0
    private var col: Int64 = 0
    // 视口顶行（渲染滚动）
    private var scrollTop: Int64 = 0
    // 空内容提示（渲染为空时显示，弱化色）
    private var placeholder: String = ""
    // 行号栏宽度（按总行数位数计算，右对齐）
    private var gutterWidth: Int64 = 1

    // 内容变更回调（任一编辑操作后触发，参数为完整文本）
    public var onChange: (String) -> Unit = { _ => }

    public init() {}

    public init(placeholder: String) {
        this.placeholder = placeholder
    }

    /**
     * 设置完整内容（按 \n 拆行；清空行缓冲区则保底一行空行）
     */
    public func setText(t: String): Unit {
        this.lines = ArrayList<String>()
        let parts = t.split("\n", -1)
        for (p in parts) {
            this.lines.add(p)
        }
        if (this.lines.size == 0) {
            this.lines.add("")
        }
        this.row = 0
        this.col = 0
        this.scrollTop = 0
        this.onChange(this.text())
    }

    /**
     * 完整文本（行间以 \n 连接）
     */
    public func text(): String {
        var sb = StringBuilder()
        for (i in 0..this.lines.size) {
            sb.append(this.lines[i])
            if (i < this.lines.size - 1) {
                sb.append("\n")
            }
        }
        return sb.toString()
    }

    /**
     * 当前光标行号（0-based）
     */
    public func cursorRow(): Int64 {
        return this.row
    }

    /**
     * 当前光标列（行内码点位置，0-based）
     */
    public func cursorCol(): Int64 {
        return this.col
    }

    /**
     * 总行数
     */
    public func lineCount(): Int64 {
        return this.lines.size
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        // 行号栏宽度 = 最大行号位数 + 两侧空格
        var digits: Int64 = 1
        var n = this.lines.size
        while (n >= 10) {
            n = n / 10
            digits += 1
        }
        this.gutterWidth = digits + 2

        // 滚动：保持光标可见（上移/下移各纠一次）
        if (this.row < this.scrollTop) {
            this.scrollTop = this.row
        }
        let bottom = this.row - height + 1
        if (bottom > this.scrollTop) {
            this.scrollTop = bottom
        }
        if (this.scrollTop < 0) {
            this.scrollTop = 0
        }
        let maxTop = if (this.lines.size > height) { this.lines.size - height } else { 0 }
        if (this.scrollTop > maxTop) {
            this.scrollTop = maxTop
        }

        // 渲染可见行
        var r: Int64 = 0
        while (r < height) {
            let idx = this.scrollTop + r
            if (idx >= this.lines.size) {
                break
            }
            let num = (idx + 1).toString()
            let gutter = Ansi.fg(Ansi.THEME_MUTED) + " " + num + " " + Ansi.reset()
            canvas.setLine(row + r, gutter + this.lines[idx])
            r += 1
        }
        // 空内容：显示提示
        if (this.lines.size == 1 && this.lines[0].size == 0 && this.placeholder.size > 0) {
            canvas.setLine(row, Ansi.fg(Ansi.THEME_MUTED) + this.placeholder + Ansi.reset())
        }

        // 光标定位（1-based）：视口内行号 + 行号栏 + 码点列
        let visRow = this.row - this.scrollTop + 1
        let cursorCol = this.gutterWidth + this.col + 1
        canvas.setCursor(row + visRow, cursorCol)
        return r
    }

    public override func handleKey(key: KeyEvent): Bool {
        // 方向键移动
        if (key.isArrowUp) {
            this.moveUp()
            return true
        }
        if (key.isArrowDown) {
            this.moveDown()
            return true
        }
        if (key.isArrowLeft) {
            this.moveLeft()
            return true
        }
        if (key.isArrowRight) {
            this.moveRight()
            return true
        }
        // 翻页（光标上下移动 8 行）
        if (key.isPageUp) {
            this.moveUpN(8)
            return true
        }
        if (key.isPageDown) {
            this.moveDownN(8)
            return true
        }
        // 回车拆行
        if (key.isEnter) {
            let line = this.lines[this.row]
            let (left, right) = this.splitAtRunes(line, this.col)
            this.lines[this.row] = left
            this.insertLine(this.row + 1, right)
            this.row += 1
            this.col = 0
            this.onChange(this.text())
            return true
        }
        // 退格：删前一码点；行首合并上一行
        if (key.isBackspace) {
            if (this.col > 0) {
                this.lines[this.row] = this.deleteAtRunes(this.lines[this.row], this.col - 1)
                this.col -= 1
            } else if (this.row > 0) {
                let prev = this.lines[this.row - 1]
                this.lines[this.row - 1] = prev + this.lines[this.row]
                this.removeLine(this.row)
                this.row -= 1
                this.col = this.runeCount(prev)
            }
            this.onChange(this.text())
            return true
        }
        // Ctrl+D：删光标处码点；行尾合并下一行
        if (key.isCtrlD) {
            let line = this.lines[this.row]
            if (this.col < this.runeCount(line)) {
                this.lines[this.row] = this.deleteAtRunes(line, this.col)
            } else if (this.row < this.lines.size - 1) {
                this.lines[this.row] = line + this.lines[this.row + 1]
                this.removeLine(this.row + 1)
            }
            this.onChange(this.text())
            return true
        }
        // 粘贴事件：整段在光标处插入（含换行按文本插入，不拆行触发语义——bracketed paste）
        if (key.isPaste) {
            if (key.text.size > 0) {
                this.lines[this.row] = this.insertAtRunes(this.lines[this.row], this.col, key.text)
                this.col += this.runeCount(key.text)
                this.onChange(this.text())
            }
            return true
        }
        // 可打印字符：在光标处插入（UTF-8 多字节安全）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace) {
            this.lines[this.row] = this.insertAtRunes(this.lines[this.row], this.col, key.text)
            this.col += this.runeCount(key.text)
            this.onChange(this.text())
            return true
        }
        return false
    }

    // ===== 光标移动 =====

    private func moveUp(): Unit {
        if (this.row > 0) {
            this.row -= 1
            this.clampCol()
        }
    }

    private func moveDown(): Unit {
        if (this.row < this.lines.size - 1) {
            this.row += 1
            this.clampCol()
        }
    }

    private func moveLeft(): Unit {
        if (this.col > 0) {
            this.col -= 1
        } else if (this.row > 0) {
            this.row -= 1
            this.col = this.runeCount(this.lines[this.row])
        }
    }

    private func moveRight(): Unit {
        let line = this.lines[this.row]
        if (this.col < this.runeCount(line)) {
            this.col += 1
        } else if (this.row < this.lines.size - 1) {
            this.row += 1
            this.col = 0
        }
    }

    private func moveUpN(n: Int64): Unit {
        this.row -= n
        if (this.row < 0) {
            this.row = 0
        }
        this.clampCol()
    }

    private func moveDownN(n: Int64): Unit {
        this.row += n
        if (this.row >= this.lines.size) {
            this.row = this.lines.size - 1
        }
        this.clampCol()
    }

    // 列修正：不超过当前行码点数
    private func clampCol(): Unit {
        let max = this.runeCount(this.lines[this.row])
        if (this.col > max) {
            this.col = max
        }
    }

    // ===== 行操作 =====

    // 在 idx 处插入一行（ArrayList 无 insert，用占位 + 右移）
    private func insertLine(idx: Int64, line: String): Unit {
        this.lines.add("")
        var i = this.lines.size - 1
        while (i > idx) {
            this.lines[i] = this.lines[i - 1]
            i -= 1
        }
        this.lines[idx] = line
    }

    // 删除一行（remove 只收 Range）
    private func removeLine(idx: Int64): Unit {
        this.lines.remove(idx..idx + 1)
    }

    // ===== UTF-8 安全字符串操作 =====

    /**
     * 码点数
     */
    private func runeCount(s: String): Int64 {
        var n: Int64 = 0
        for (_ in s.toRuneArray()) {
            n += 1
        }
        return n
    }

    /**
     * 在码点位置 pos 处插入文本（多字节字符整体移动）
     */
    private func insertAtRunes(s: String, pos: Int64, t: String): String {
        let runes = s.toRuneArray()
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < pos && i < runes.size) {
            sb.append(runes[i].toString())
            i += 1
        }
        sb.append(t)
        while (i < runes.size) {
            sb.append(runes[i].toString())
            i += 1
        }
        return sb.toString()
    }

    /**
     * 删除码点位置 pos 处的字符（多字节字符整体删除）
     */
    private func deleteAtRunes(s: String, pos: Int64): String {
        let runes = s.toRuneArray()
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < runes.size) {
            if (i != pos) {
                sb.append(runes[i].toString())
            }
            i += 1
        }
        return sb.toString()
    }

    /**
     * 按码点位置拆成左右两段（用于 Enter 拆行）
     */
    private func splitAtRunes(s: String, pos: Int64): (String, String) {
        let runes = s.toRuneArray()
        var left = StringBuilder()
        var right = StringBuilder()
        var i: Int64 = 0
        while (i < runes.size) {
            if (i < pos) {
                left.append(runes[i].toString())
            } else {
                right.append(runes[i].toString())
            }
            i += 1
        }
        return (left.toString(), right.toString())
    }
}
