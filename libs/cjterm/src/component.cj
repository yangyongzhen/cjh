package cjterm

import std.collection.*

/**
 * TUI 组件接口（参考 oh-my-pi pi-tui 的 Component 契约简化）
 *
 * pi-tui 契约：render(width) 返回行数组（每行 ≤ width，不变时返回同一引用
 * 以便 memoize）；handleInput 处理焦点输入；invalidate 清缓存。cjh 侧
 * 简化为显式行定位：组件渲染到 TuiCanvas（canvas 负责差分与截断），
 * handleKey 处理按键并返回是否消费（true = 已消费，不再向下分发）。
 */
public interface Component {
    /**
     * 渲染组件内容到 canvas。row 为组件起始行（0-based），height 为该组件
     * 可用的最大行数，width 为最大列宽（canvas 会按此截断）。
     * 返回组件实际占用的行数（供上层布局/滚动计算）。
     */
    func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64

    /**
     * 处理按键。返回 true 表示消费该按键（上层不再分发）。
     */
    func handleKey(key: KeyEvent): Bool

    /**
     * 组件获得焦点（默认空实现）
     */
    func onFocus(): Unit {}

    /**
     * 组件失去焦点（默认空实现）
     */
    func onBlur(): Unit {}
}

/**
 * 行级差分画布：本次渲染各行内容与上次对比，只输出变化行。
 *
 * 用法（每帧）：
 *   canvas.begin(rows, cols, sizeChanged)  // 开始新帧；尺寸变化清缓存强制全量
 *   canvas.setLine(row, text)              // 写一行（自动截断到列宽）
 *   canvas.setCursor(row, col)             // 设置硬件光标（1-based）
 *   let out = canvas.flush()               // 差分渲染指令 + 光标定位
 *
 * 从 TuiApp 的 prevLines 差分逻辑抽出，供任意组件组合复用。
 */
public class TuiCanvas {
    private var prevLines: ArrayList<String> = ArrayList<String>()
    private var lines: ArrayList<String> = ArrayList<String>()
    private var rows: Int64 = 0
    private var cols: Int64 = 0
    private var cursorRow: Int64 = 1
    private var cursorCol: Int64 = 1

    /**
     * 开始新帧。sizeChanged 为 true（首帧或终端尺寸变化）时清空缓存强制全量重绘。
     */
    public func begin(rows: Int64, cols: Int64, sizeChanged: Bool): Unit {
        this.rows = rows
        this.cols = cols
        this.lines = ArrayList<String>()
        for (i in 0..rows) {
            this.lines.add("")
        }
        if (sizeChanged) {
            this.prevLines = ArrayList<String>()
        }
    }

    /**
     * 设置某行内容（0-based；自动截断到列宽；越界忽略）
     */
    public func setLine(row: Int64, text: String): Unit {
        if (row < 0 || row >= this.rows) {
            return
        }
        this.lines[row] = this.truncate(text, this.cols)
    }

    /**
     * 设置硬件光标位置（1-based 行列，默认 (1,1)）
     */
    public func setCursor(row: Int64, col: Int64): Unit {
        this.cursorRow = row
        this.cursorCol = col
    }

    /**
     * 完成本帧：返回差分渲染指令（只重绘变化行），并定位光标。
     */
    public func flush(): String {
        var sb = StringBuilder()
        for (i in 0..this.rows) {
            let content = this.lines[i]
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
        sb.append(Ansi.moveTo(this.cursorRow, this.cursorCol))
        return sb.toString()
    }

    /**
     * 按列宽截断行（字节安全：从目标字节数递减，直到落在合法字符边界）。
     * 注意：含 ANSI 转义序列的行按原始字节计数，宽度为近似值（CJK=2 列未精确，
     * 与 TuiApp 旧实现行为一致）。
     */
    public func truncate(text: String, cols: Int64): String {
        if (text.size <= cols - 1) {
            return text
        }
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
