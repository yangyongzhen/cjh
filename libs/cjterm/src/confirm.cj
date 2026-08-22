package cjterm

/**
 * ConfirmDialog：确认/审批弹窗组件（可复用）
 *
 * - 带边框的模态弹窗（UTF-8 box-drawing，非 UTF-8 降级 ASCII +-|）
 * - show(title, message, hint) 弹出；可见时 handleKey 消费 y/n/Esc/Enter，
 *   触发 onResult(Bool) 后自动隐藏
 * - 模态语义：弹窗可见时所有按键被消费，不穿透到底层组件
 * - 默认谨慎：y/Y = 确认，n/N/Esc = 取消，Enter 也按取消（可用
 *   enterAccepts 改为按确认）
 *
 * 用途：危险操作审批、确认弹窗、二选一选择（可复用，不绑 agent 逻辑）。
 */
public class ConfirmDialog <: Component {
    private var visible: Bool = false
    private var title: String = ""
    private var message: String = ""
    private var hint: String = "[y]=确认 [n]/[Esc]=取消"
    private var utf8: Bool = true
    // 弹窗宽度（render 时按内容 + 终端宽度重算）
    private var boxW: Int64 = 40
    // Enter 是否表示确认（默认 false = 谨慎，Enter 与 n/Esc 同为取消）
    public var enterAccepts: Bool = false

    // 结果回调：true=确认，false=取消
    public var onResult: (Bool) -> Unit = { _ => }

    public init() {}

    public init(utf8: Bool) {
        this.utf8 = utf8
    }

    /**
     * 弹出弹窗（设置标题/消息/操作提示）
     */
    public func show(title: String, message: String, hint: String): Unit {
        this.title = title
        this.message = message
        this.hint = hint
        this.visible = true
    }

    /**
     * 关闭弹窗（不触发回调）
     */
    public func hide(): Unit {
        this.visible = false
    }

    public func isVisible(): Bool {
        return this.visible
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        if (!this.visible) {
            return 0
        }
        // 弹窗宽度：内容最长行（码点数）+ 内边距 + 左右边框
        var maxLen: Int64 = 4
        let t = this.runeCount(this.title) + 2
        if (t > maxLen) { maxLen = t }
        let m = this.runeCount(this.message) + 2
        if (m > maxLen) { maxLen = m }
        let h = this.runeCount(this.hint) + 2
        if (h > maxLen) { maxLen = h }
        this.boxW = maxLen + 2
        if (this.boxW > width) {
            this.boxW = width
        }
        if (this.boxW < 12) {
            this.boxW = 12
        }

        let tl = if (this.utf8) { "╭" } else { "+" }
        let tr = if (this.utf8) { "╮" } else { "+" }
        let bl = if (this.utf8) { "╰" } else { "+" }
        let br = if (this.utf8) { "╯" } else { "+" }
        let hc = if (this.utf8) { "─" } else { "-" }
        let vc = if (this.utf8) { "│" } else { "|" }

        // 行 0：上边框 + 标题（标题居中左侧）
        var top = StringBuilder()
        top.append(tl)
        top.append(hc)
        top.append(" ")
        top.append(this.title)
        top.append(" ")
        top.append(this.fill(hc, this.boxW - this.runeCount(this.title) - 4))
        top.append(tr)
        canvas.setLine(row, top.toString())

        // 行 1：消息
        canvas.setLine(row + 1, this.contentLine(vc, this.message))

        // 行 2：操作提示
        canvas.setLine(row + 2, this.contentLine(vc, this.hint))

        // 行 3：下边框
        var bottom = StringBuilder()
        bottom.append(bl)
        bottom.append(this.fill(hc, this.boxW - 2))
        bottom.append(br)
        canvas.setLine(row + 3, bottom.toString())

        return 4
    }

    public override func handleKey(key: KeyEvent): Bool {
        if (!this.visible) {
            return false
        }
        // 模态：可见时消费一切按键（即使未命中，也拦截不穿透）
        if (key.isEsc || key.ch == 110 || key.ch == 78) {
            // Esc / n / N → 取消
            this.visible = false
            this.onResult(false)
            return true
        }
        if (key.ch == 121 || key.ch == 89) {
            // y / Y → 确认
            this.visible = false
            this.onResult(true)
            return true
        }
        if (key.isEnter) {
            this.visible = false
            this.onResult(this.enterAccepts)
            return true
        }
        return true
    }

    /**
     * 边框内容行：│ 内容（码点级截断）   │（宽度对齐 boxW）
     */
    private func contentLine(vc: String, content: String): String {
        var sb = StringBuilder()
        sb.append(vc)
        sb.append(" ")
        let text = this.truncateRunes(content, this.boxW - 4)
        sb.append(text)
        sb.append(" ")
        sb.append(this.fill(" ", this.boxW - this.runeCount(text) - 3))
        sb.append(vc)
        return sb.toString()
    }

    /**
     * 码点数（近似显示宽度：CJK 按 1 个码点计，与 canvas 截断一致）
     */
    private func runeCount(s: String): Int64 {
        var n: Int64 = 0
        for (_ in s.toRuneArray()) {
            n += 1
        }
        return n
    }

    /**
     * 按码点数截断（字节安全：经 toRuneArray 逐码点重建，不会切碎 UTF-8）
     */
    private func truncateRunes(s: String, maxRunes: Int64): String {
        if (maxRunes <= 0) {
            return ""
        }
        let runes = s.toRuneArray()
        if (runes.size <= maxRunes) {
            return s
        }
        var sb = StringBuilder()
        var n: Int64 = 0
        for (r in runes) {
            if (n >= maxRunes) {
                break
            }
            sb.append(r.toString())
            n += 1
        }
        return sb.toString()
    }

    /**
     * 重复字符填充
     */
    private func fill(ch: String, n: Int64): String {
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < n) {
            sb.append(ch)
            i += 1
        }
        return sb.toString()
    }
}
