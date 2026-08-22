package cjterm

/**
 * StatusBar：底部状态行组件
 *
 * - 外部可设置状态文本（setStatus）；为空时回退显示 "ready" 徽章
 * - 不消费按键（滚动等由其他组件处理）
 */
public class StatusBar <: Component {
    private var text: String = ""

    public init() {}

    /**
     * 设置状态文本（空串显示默认徽章）
     */
    public func setStatus(t: String): Unit {
        this.text = t
    }

    public func current(): String {
        return this.text
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let status = if (this.text.size == 0) {
            Logo.badge("ready", Ansi.THEME_OK)
        } else {
            this.text
        }
        canvas.setLine(row, status)
        return 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        return false
    }
}
