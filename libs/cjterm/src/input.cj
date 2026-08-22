package cjterm

/**
 * InputBox：单行输入组件（参考 pi-tui Input 组件简化）
 *
 * - 提示符前缀（默认 "❯ " 亮青色，可定制）
 * - UTF-8 字节安全退格（按字符删，中文不崩）
 * - 变更回调 onChange（输入变化时触发，供下拉补全等联动）
 * - 提交回调 onSubmit（回车时触发）
 *
 * 消费按键：可打印字符 / 退格 / 回车（返回 true）；其余按键不消费，
 * 由上层（滚动/Esc 等）处理。
 */
public class InputBox <: Component {
    private var text_: String = ""
    // 提示符可见文本（不含 ANSI）与其着色渲染文本
    private var promptText: String = "❯ "
    private var promptRendered: String = Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset()

    // 变更回调（输入内容变化时触发，参数为新内容）
    public var onChange: (String) -> Unit = { _ => }
    // 提交回调（回车时触发，参数为完整输入）
    public var onSubmit: (String) -> Unit = { _ => }

    public init() {}

    public init(prompt: String) {
        this.promptText = prompt
        this.promptRendered = Ansi.fg(Ansi.THEME_ACCENT) + prompt + Ansi.reset()
    }

    /**
     * 当前输入内容
     */
    public func text(): String {
        return this.text_
    }

    /**
     * 设置内容（并触发 onChange）
     */
    public func setText(t: String): Unit {
        if (this.text_ != t) {
            this.text_ = t
            this.onChange(t)
        }
    }

    /**
     * 设置内容但不触发 onChange（补全确认等场景，避免重新弹候选）
     */
    public func setTextSilent(t: String): Unit {
        this.text_ = t
    }

    /**
     * 清空内容（不触发 onChange）
     */
    public func clear(): Unit {
        this.text_ = ""
    }

    /**
     * 获取提示符可见宽度（码点数）
     */
    public func promptWidth(): Int64 {
        var w: Int64 = 0
        for (_ in this.promptText.toRuneArray()) {
            w += 1
        }
        return w
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        // 输入行：提示符 + 内容
        canvas.setLine(row, this.promptRendered + this.text_)
        // 光标定位到内容末尾（提示符宽度 + 内容码点数；中文输入光标不错位）
        var cur = this.promptWidth() + 1
        for (_ in this.text_.toRuneArray()) {
            cur += 1
        }
        canvas.setCursor(row + 1, cur)
        return 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        if (key.isEnter) {
            // 提交（即使内容为空也回调，由上层决定是否忽略）
            this.onSubmit(this.text_)
            return true
        }
        if (key.isBackspace) {
            if (this.text_.size > 0) {
                // 按 UTF-8 字符删除（非字节）：从末尾递减试切片，直到合法字符边界
                var cut = this.text_.size - 1
                while (cut >= 0) {
                    try {
                        this.text_ = this.text_[0..cut]
                        break
                    } catch (e: Exception) {
                        cut -= 1
                    }
                }
                this.onChange(this.text_)
            }
            return true
        }
        // 可打印字符（含中文等多字节 UTF-8；排除控制键）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace) {
            this.text_ += key.text
            this.onChange(this.text_)
            return true
        }
        return false
    }
}
