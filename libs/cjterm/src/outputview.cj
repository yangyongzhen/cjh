package cjterm

/**
 * OutputView：对话输出区组件（行集合 + 滚动 + 流式段）
 *
 * 从 TuiApp 的输出/流式/滚动逻辑抽出，职责：
 * - 维护输出文本（StringBuilder，行集合）
 * - 流式段管理：appendDelta 记录段起点，endStream 用最终完整文本整体替换
 *   （mojibake 整体修复 / markdown 收尾依赖此语义）
 * - 滚动：scrollUp/scrollDown + render 时修正边界
 *
 * 消费按键：PageUp/PageDown/CtrlU/CtrlD（滚动），返回 true；其余不消费。
 */
public class OutputView <: Component {
    private var output: StringBuilder = StringBuilder()
    // 流式段起点（output 中的字节偏移；-1 表示无活动流式段）
    private var streamStartPos: Int64 = -1
    private var scrollOffset: Int64 = 0

    public init() {}

    /**
     * 追加一行到输出区（自动补 \n）
     */
    public func append(text: String): Unit {
        this.output.append(text)
        if (text.size == 0 || text[text.size - 1] != 10u8) {
            this.output.append("\n")
        }
    }

    /**
     * 流式追加：追加到当前输出行末尾（不换行），用于 LLM 增量渲染
     */
    public func appendDelta(text: String): Unit {
        if (this.streamStartPos < 0) {
            // 记录流式段起点（append 起点必为合法字符边界，可安全切片）
            this.streamStartPos = this.output.toString().size
        }
        this.output.append(text)
    }

    /**
     * 流式结束：用最终完整文本替换整个流式段。
     * 用于 mojibake 整体修复 / markdown 状态收尾（线程安全由调用方保证）
     */
    public func endStream(text: String): Unit {
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
    }

    /**
     * 当前是否有活动流式段
     */
    public func isStreaming(): Bool {
        return this.streamStartPos >= 0
    }

    /**
     * 全部输出文本（供存档/会话持久化）
     */
    public func content(): String {
        return this.output.toString()
    }

    /**
     * 向上滚动 n 行（上限由 render 修正）
     */
    public func scrollUp(n: Int64): Unit {
        this.scrollOffset += n
    }

    /**
     * 向下滚动 n 行
     */
    public func scrollDown(n: Int64): Unit {
        this.scrollOffset -= n
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let outLines = this.output.toString().split("\n", -1)
        // 滚动边界修正：最多滚到"最后一行可见"
        let maxOffset = if (outLines.size > height) { outLines.size - height } else { 0 }
        if (this.scrollOffset > maxOffset) {
            this.scrollOffset = maxOffset
        }
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
        var startIdx = outLines.size - height - this.scrollOffset
        if (startIdx < 0) {
            startIdx = 0
        }
        var r: Int64 = 0
        for (i in startIdx..outLines.size) {
            if (r >= height) {
                break
            }
            canvas.setLine(row + r, outLines[i])
            r += 1
        }
        return r
    }

    public override func handleKey(key: KeyEvent): Bool {
        if (key.isCtrlU || key.isPageUp) {
            this.scrollUp(8)
            return true
        }
        if (key.isCtrlD || key.isPageDown) {
            this.scrollDown(8)
            return true
        }
        return false
    }
}
