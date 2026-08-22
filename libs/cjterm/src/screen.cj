package cjterm

/**
 * 差分渲染：维护"期望屏幕"状态，与上一次渲染比较，只输出差异
 *
 * 屏幕状态 = 二维字符网格（行 × 列）。渲染时对比新旧网格，
 * 输出最小化的光标移动 + 写入命令，实现流畅的局部刷新。
 */
public class Screen {
    public let rows: Int64
    public let cols: Int64
    private var grid: Array<Array<String>>  // 当前期望状态

    public init(rows: Int64, cols: Int64) {
        this.rows = rows
        this.cols = cols
        var g = Array<Array<String>>(rows, repeat: Array<String>(cols, repeat: " "))
        this.grid = g
    }

    /**
     * 设置某行文本（自动填充/截断到列宽）
     */
    public func setLine(row: Int64, text: String): Unit {
        if (row < 0 || row >= this.rows) {
            return
        }
        var newRow = Array<String>(this.cols, repeat: " ")
        // 迭代码点（toRuneArray）而非 for-in 迭代 String——后者得 Byte，
        // Rune(byte) 重建会把中文拆成 Latin-1 形态乱码
        var col: Int64 = 0
        for (r in text.toRuneArray()) {
            if (col >= this.cols) {
                break
            }
            newRow[col] = r.toString()
            col += 1
        }
        this.grid[row] = newRow
    }

    /**
     * 与 old 比较，生成渲染指令（移动光标 + 写差异行）
     */
    public func diff(old: Screen): String {
        var sb = StringBuilder()
        for (r in 0..this.rows) {
            let changed = !this.rowEquals(old.grid[r], this.grid[r])
            if (changed) {
                sb.append(Ansi.moveTo(r + 1, 1))
                sb.append(Ansi.clearLine())
                var line = ""
                for (c in 0..this.cols) {
                    line += this.grid[r][c]
                }
                sb.append(line)
            }
        }
        return sb.toString()
    }

    private func rowEquals(a: Array<String>, b: Array<String>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }

    /**
     * 复制当前状态（作为下次渲染的 old）
     */
    public func clone(): Screen {
        let s = Screen(this.rows, this.cols)
        for (r in 0..this.rows) {
            for (c in 0..this.cols) {
                s.grid[r][c] = this.grid[r][c]
            }
        }
        return s
    }

    public func renderToString(): String {
        var sb = StringBuilder()
        for (r in 0..this.rows) {
            var line = ""
            for (c in 0..this.cols) {
                line += this.grid[r][c]
            }
            sb.append(line)
            if (r < this.rows - 1) {
                sb.append("\n")
            }
        }
        return sb.toString()
    }
}
