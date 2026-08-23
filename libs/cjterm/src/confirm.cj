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
    // 全宽模式：铺满整个终端宽度（TUI 审批弹窗用；通用组件默认内容自适应）
    public var fullWidth: Bool = false
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
        if (this.fullWidth) {
            // 全宽模式：铺满终端宽度
            this.boxW = width
        } else {
            // 内容自适应：最长行显示宽度 + 内边距 + 左右边框
            var maxLen: Int64 = 4
            let t = this.displayWidth(this.title) + 2
            if (t > maxLen) { maxLen = t }
            let m = this.displayWidth(this.message) + 2
            if (m > maxLen) { maxLen = m }
            let h = this.displayWidth(this.hint) + 2
            if (h > maxLen) { maxLen = h }
            this.boxW = maxLen + 2
            if (this.boxW > width) {
                this.boxW = width
            }
            if (this.boxW < 12) {
                this.boxW = 12
            }
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
        top.append(this.fill(hc, this.boxW - this.displayWidth(this.title) - 4))
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
     * 边框内容行：│ 内容（显示宽度截断）   │（宽度对齐 boxW）
     */
    private func contentLine(vc: String, content: String): String {
        var sb = StringBuilder()
        sb.append(vc)
        sb.append(" ")
        let text = this.truncateWidth(content, this.boxW - 4)
        sb.append(text)
        sb.append(" ")
        sb.append(this.fill(" ", this.boxW - this.displayWidth(text) - 3))
        sb.append(vc)
        return sb.toString()
    }

    /**
     * 显示宽度（东亚宽字符=2 列，其余=1 列；与终端渲染一致）
     */
    private func displayWidth(s: String): Int64 {
        var n: Int64 = 0
        for (r in s.toRuneArray()) {
            n += if (ConfirmDialog.isWideCp(UInt32(r))) { 2 } else { 1 }
        }
        return n
    }

    /**
     * 按显示宽度截断（字节安全：经 toRuneArray 逐码点重建，不会切碎 UTF-8；
     * 超出 maxW 列即停，避免 CJK 2 列字符被切半）
     */
    private func truncateWidth(s: String, maxW: Int64): String {
        if (maxW <= 0) {
            return ""
        }
        var sb = StringBuilder()
        var w: Int64 = 0
        for (r in s.toRuneArray()) {
            let rw = if (ConfirmDialog.isWideCp(UInt32(r))) { 2 } else { 1 }
            if (w + rw > maxW) {
                break
            }
            sb.append(r.toString())
            w += rw
        }
        return sb.toString()
    }

    /**
     * 东亚宽字符码点判断（wcwidth wide 简化版，与 TuiCanvas.isWideCp 同规则）
     */
    private static func isWideCp(cp: UInt32): Bool {
        if (cp >= 0x1100 && cp <= 0x115F) { return true }    // 谚文 Jamo
        if (cp >= 0x2E80 && cp <= 0x303E) { return true }    // 部首/注音/东亚标点
        if (cp >= 0x3041 && cp <= 0x33FF) { return true }    // 假名/谚文兼容符号
        if (cp >= 0x3400 && cp <= 0x4DBF) { return true }    // CJK 扩展 A
        if (cp >= 0x4E00 && cp <= 0x9FFF) { return true }    // CJK 统一表意
        if (cp >= 0xA000 && cp <= 0xA4CF) { return true }    // 彝文/谚文字母
        if (cp >= 0xAC00 && cp <= 0xD7A3) { return true }    // 谚文音节
        if (cp >= 0xF900 && cp <= 0xFAFF) { return true }    // CJK 兼容表意
        if (cp >= 0xFE30 && cp <= 0xFE4F) { return true }    // CJK 兼容形式
        if (cp >= 0xFF00 && cp <= 0xFF60) { return true }    // 全角
        if (cp >= 0xFFE0 && cp <= 0xFFE6) { return true }    // 全角符号
        if (cp >= 0x20000 && cp <= 0x2FFFD) { return true }  // CJK 扩展 B+
        return false
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
