package cjterm

import std.collection.*

/**
 * FormDialog：多字段表单弹窗组件（参考 omp sign-in 配置弹窗）
 *
 * 字段类型：
 * - text：可编辑文本（追加/退格）
 * - secret：文本但显示为 *（API Key）
 * - select：从预设选项中循环选择（方向键 ←→ 切换）；value 存当前选项
 *
 * 布局（box-drawing 圆角边框，等宽对齐）：
 *   ╭─ 标题 ────────────────╮
 *   │  标签   [value]        │   聚焦字段：accent 边框
 *   │  标签    value         │   非聚焦：muted value
 *   │                         │
 *   │  提示文本               │
 *   ╰─────────────────────────╯
 *
 * 按键：↑↓/Tab 切换字段，←→ 切换 select 选项，Enter 提交，Esc 取消。
 */
public class FormDialog <: Component {
    private var visible: Bool = false
    private var title: String = ""
    private var hint: String = "[Enter]=保存 [Esc]=取消 [↑↓]切换字段"
    private var utf8: Bool = true

    // 字段定义（并行数组）
    private var labels: ArrayList<String> = ArrayList<String>()
    private var placeholders: ArrayList<String> = ArrayList<String>()
    private var secrets: ArrayList<Bool> = ArrayList<Bool>()
    private var selects: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    private var values: ArrayList<String> = ArrayList<String>()
    // 字段可见性（true=渲染可聚焦；false=隐藏但值保留，提交仍含该值）
    // 用于"协议"等仅特定场景需要的字段（如 custom provider 才选协议）
    private var fieldVisible: ArrayList<Bool> = ArrayList<Bool>()

    private var focus: Int64 = 0
    private var boxW: Int64 = 60
    public var fullWidth: Bool = false

    public var onSubmit: (ArrayList<String>) -> Unit = { _ => }
    public var onCancel: () -> Unit = { => }
    // select 字段切换回调：参数 = (字段索引, 新值)，供外部联动填充其他字段
    public var onSelectChange: (Int64, String) -> Unit = { _, _ => }

    public init() {}

    public init(utf8: Bool) {
        this.utf8 = utf8
    }

    /**
     * 清空所有字段
     */
    public func clearFields(): Unit {
        this.labels = ArrayList<String>()
        this.placeholders = ArrayList<String>()
        this.secrets = ArrayList<Bool>()
        this.selects = ArrayList<ArrayList<String>>()
        this.values = ArrayList<String>()
        this.fieldVisible = ArrayList<Bool>()
        this.focus = 0
    }

    /**
     * 添加 text 字段
     */
    public func addField(label: String, placeholder: String, secret: Bool): Unit {
        this.labels.add(label)
        this.placeholders.add(placeholder)
        this.secrets.add(secret)
        this.selects.add(ArrayList<String>())
        this.values.add("")
        this.fieldVisible.add(true)
    }

    /**
     * 添加 select 字段（带预设选项）。setValue 时必须在 options 中。
     */
    public func addSelectField(label: String, options: ArrayList<String>): Unit {
        this.labels.add(label)
        this.placeholders.add("")
        this.secrets.add(false)
        this.selects.add(options)
        this.values.add(if (options.size > 0) { options[0] } else { "" })
        this.fieldVisible.add(true)
    }

    /**
     * 设置字段可见性：隐藏字段不渲染、不可聚焦，但值保留（提交仍含该值）。
     * 用于"协议"等仅特定场景需要的字段。
     */
    public func setFieldVisible(index: Int64, visible: Bool): Unit {
        if (index < 0 || index >= this.fieldVisible.size) {
            return
        }
        this.fieldVisible[index] = visible
        // 隐藏当前聚焦字段时，焦点移到下一个可见字段
        if (!visible && this.focus == index) {
            let next = this.nextVisibleIndex(index)
            if (next >= 0) {
                this.focus = next
            }
        }
    }

    /**
     * 字段是否可见
     */
    public func isFieldVisible(index: Int64): Bool {
        if (index < 0 || index >= this.fieldVisible.size) {
            return false
        }
        return this.fieldVisible[index]
    }

    /**
     * 从 start 起找下一个可见字段（循环），无可见字段返回 -1
     */
    private func nextVisibleIndex(start: Int64): Int64 {
        if (this.labels.size == 0) {
            return -1
        }
        var i: Int64 = start + 1
        var tried: Int64 = 0
        while (tried < this.labels.size) {
            if (i >= this.labels.size) {
                i = 0
            }
            if (this.fieldVisible[i]) {
                return i
            }
            i += 1
            tried += 1
        }
        return -1
    }

    /**
     * 设置字段初始值（index 越界忽略）
     */
    public func setFieldValue(index: Int64, value: String): Unit {
        if (index < 0 || index >= this.values.size) {
            return
        }
        this.values[index] = value
    }

    public func show(title: String, hint: String): Unit {
        this.title = title
        this.hint = hint
        this.focus = 0
        this.visible = true
    }

    public func hide(): Unit {
        this.visible = false
    }

    public func isVisible(): Bool {
        return this.visible
    }

    public func focusIndex(): Int64 {
        return this.focus
    }

    public func fieldCount(): Int64 {
        return this.labels.size
    }

    /**
     * 判断字段是否为 select 类型
     */
    private func isSelect(index: Int64): Bool {
        if (index < 0 || index >= this.selects.size) {
            return false
        }
        return this.selects[index].size > 0
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        if (!this.visible) {
            return 0
        }

        // ── 计算弹窗宽度 ──
        var maxLabelW: Int64 = 0
        for (i in 0..this.labels.size) {
            let w = FormDialog.displayWidth(this.labels[i])
            if (w > maxLabelW) {
                maxLabelW = w
            }
        }
        let titleW = FormDialog.displayWidth(this.title)
        let hintW = FormDialog.displayWidth(this.hint)
        // 最长 value 宽度（含 select 选项）
        var maxValW: Int64 = 10
        for (i in 0..this.values.size) {
            let vw = FormDialog.displayWidth(this.values[i])
            if (vw > maxValW) {
                maxValW = vw
            }
        }
        // 内容宽度 = 标签 + 分隔 + value + 边距
        var contentW = maxLabelW + 2 + maxValW + 4
        if (titleW + 6 > contentW) {
            contentW = titleW + 6
        }
        if (hintW + 6 > contentW) {
            contentW = hintW + 6
        }
        if (contentW < 44) {
            contentW = 44
        }
        if (this.fullWidth) {
            this.boxW = width
        } else {
            this.boxW = contentW
            if (this.boxW > width) {
                this.boxW = width
            }
        }

        let tl = if (this.utf8) { "╭" } else { "+" }
        let tr = if (this.utf8) { "╮" } else { "+" }
        let bl = if (this.utf8) { "╰" } else { "+" }
        let br = if (this.utf8) { "╯" } else { "+" }
        let hc = if (this.utf8) { "─" } else { "-" }
        let vc = if (this.utf8) { "│" } else { "|" }
        let muted = Ansi.fg(Ansi.THEME_MUTED)
        let accent = Ansi.fg(Ansi.THEME_ACCENT)

        // ── 辅助：生成一条完整内容行（含左右边框，宽度对齐 boxW）──
        // inner = 标签（右对齐 maxLabelW） + 分隔 + value 区（inputW 列）
        let inputW = this.boxW - 2 - 1 - maxLabelW - 2 - 1   // 边框+内边距+标签+分隔+右内边距
        let buildLine = { leftPad: String, mid: String, rightFill: Bool =>
            var sb = StringBuilder()
            sb.append(muted + vc + Ansi.reset())
            sb.append(" ")
            sb.append(mid)
            // 末尾补空格到 boxW-3（留 1 列右内边距 + 1 列右边框）
            let used = 1 + 1 + FormDialog.displayWidth(mid)
            var fillN = this.boxW - 1 - used
            if (fillN < 0) {
                fillN = 0
            }
            var fp: Int64 = 0
            while (fp < fillN) {
                sb.append(" ")
                fp += 1
            }
            sb.append(muted + vc + Ansi.reset())
            sb.toString()
        }

        // ── 行 0：上边框 + 标题 ──
        var top = StringBuilder()
        top.append(muted + tl + hc + " " + Ansi.reset())
        top.append(accent + Ansi.bold() + this.title + Ansi.reset())
        top.append(" ")
        // 标题后填充横线到 boxW
        let topUsed = 1 + 1 + 1 + titleW + 1   // tl + hc + sp + title + sp
        var topFill = this.boxW - topUsed - 1   // -tr
        if (topFill < 0) {
            topFill = 0
        }
        top.append(muted)
        var tfi: Int64 = 0
        while (tfi < topFill) {
            top.append(hc)
            tfi += 1
        }
        top.append(tr + Ansi.reset())
        canvas.setLine(row, top.toString())

        // ── 字段内容行 ──
        var curRow: Int64 = row + 1
        for (i in 0..this.labels.size) {
            // 隐藏字段不渲染（如预设 provider 下的协议字段）
            if (!this.fieldVisible[i]) {
                continue
            }
            let isFocus = (i == this.focus)
            let label = this.labels[i]
            let labelW = FormDialog.displayWidth(label)
            // 构造 mid = 标签（右对齐 maxLabelW） + "  " + value 区
            var mid = StringBuilder()
            // 标签前补空格右对齐
            var lp: Int64 = 0
            while (lp < maxLabelW - labelW) {
                mid.append(" ")
                lp += 1
            }
            if (isFocus) {
                mid.append(accent + Ansi.bold() + label + Ansi.reset())
            } else {
                mid.append(Ansi.fg(Ansi.THEME_MUTED) + label + Ansi.reset())
            }
            mid.append("  ")

            // value 显示串（secret → * 串）
            let valStr = this.values[i]
            let isSel = this.isSelect(i)
            var displayStr = valStr
            if (this.secrets[i]) {
                var stars = StringBuilder()
                let runeCount = valStr.toRuneArray().size
                var si: Int64 = 0
                while (si < runeCount) {
                    stars.append("*")
                    si += 1
                }
                displayStr = stars.toString()
            }

            // 聚焦字段：▶ 指示符 + 反色高亮输入区
            if (isFocus) {
                if (isSel) {
                    // select 聚焦：‹ value ›（反色高亮 value）
                    mid.append(accent + "‹ " + Ansi.reset())
                    mid.append(Ansi.bg(Ansi.THEME_ACCENT) + Ansi.fg(Ansi.COLOR_BLACK) + " " + displayStr + " " + Ansi.reset())
                    mid.append(accent + " ›" + Ansi.reset())
                } else {
                    // text 聚焦：[ value ]（反色高亮 value 区，光标在 value 末尾）
                    mid.append(accent + "[" + Ansi.reset())
                    mid.append(Ansi.bg(Ansi.THEME_ACCENT) + Ansi.fg(Ansi.COLOR_BLACK) + " " + displayStr + " " + Ansi.reset())
                    mid.append(accent + "]" + Ansi.reset())
                }
            } else {
                // 非聚焦：value 或 placeholder（前置 ▷ 占位对齐聚焦 ▶）
                mid.append(Ansi.fg(Ansi.THEME_MUTED) + "▷ " + Ansi.reset())
                if (isSel) {
                    mid.append(Ansi.fg(Ansi.THEME_MUTED) + displayStr + Ansi.reset())
                } else {
                    let showStr = if (valStr.size > 0) { displayStr } else { this.placeholders[i] }
                    let showColor = if (valStr.size > 0) { Ansi.THEME_MUTED } else { Ansi.THEME_MUTED }
                    mid.append(Ansi.fg(showColor) + showStr + Ansi.reset())
                }
            }
            canvas.setLine(curRow, buildLine(" ", mid.toString(), true))
            // 聚焦 text 字段时光标定位到 value 末尾（反色高亮区内）
            if (isFocus && !isSel) {
                // 列 = 边框(1) + 内边距(1) + 标签(maxLabelW) + 分隔(2) + '['(1) + 高亮前空格(1) + value 宽
                let cursorCol = 1 + 1 + maxLabelW + 2 + 1 + 1 + FormDialog.displayWidth(displayStr) + 1
                canvas.setCursor(curRow + 1, cursorCol)
            }
            curRow += 1
        }

        // ── 空行 ──
        canvas.setLine(curRow, muted + vc + this.fillSpaces(this.boxW - 2) + vc + Ansi.reset())
        curRow += 1

        // ── 提示行 ──
        var hintSb = StringBuilder()
        hintSb.append(muted + vc + Ansi.reset())
        hintSb.append(" ")
        hintSb.append(Ansi.fg(Ansi.THEME_MUTED) + this.hint + Ansi.reset())
        let hintUsed = 1 + 1 + hintW
        var hintFill = this.boxW - 1 - hintUsed
        if (hintFill < 0) {
            hintFill = 0
        }
        var hfi: Int64 = 0
        while (hfi < hintFill) {
            hintSb.append(" ")
            hfi += 1
        }
        hintSb.append(muted + vc + Ansi.reset())
        canvas.setLine(curRow, hintSb.toString())
        curRow += 1

        // ── 底边框 ──
        var bottom = StringBuilder()
        bottom.append(muted + bl)
        var bfi: Int64 = 0
        while (bfi < this.boxW - 2) {
            bottom.append(hc)
            bfi += 1
        }
        bottom.append(br + Ansi.reset())
        canvas.setLine(curRow, bottom.toString())

        return curRow - row + 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        if (!this.visible) {
            return false
        }
        // 裸 Esc → 取消（方向键 ESC[A 等转义序列 escapeSeq 更长，不误判）
        if (key.escapeSeq == TermEsc.ESC) {
            this.visible = false
            this.onCancel()
            return true
        }
        // Ctrl+C 也取消
        if (key.ch == 3) {
            this.visible = false
            this.onCancel()
            return true
        }
        // Tab / ↓ → 下一字段（跳过隐藏字段）
        if (key.isTab || key.isArrowDown) {
            if (this.labels.size > 0) {
                let next = this.nextVisibleIndex(this.focus)
                if (next >= 0) {
                    this.focus = next
                }
            }
            return true
        }
        // ↑ → 上一字段（反向找上一个可见字段）
        if (key.isArrowUp) {
            if (this.labels.size > 0) {
                var i: Int64 = this.focus - 1
                var tried: Int64 = 0
                while (tried < this.labels.size) {
                    if (i < 0) {
                        i = this.labels.size - 1
                    }
                    if (this.fieldVisible[i]) {
                        this.focus = i
                        break
                    }
                    i -= 1
                    tried += 1
                }
            }
            return true
        }
        // 当前字段为 select：←→ 切换选项，并触发 onSelectChange 联动
        if (this.isSelect(this.focus)) {
            if (key.isArrowLeft || key.isArrowRight) {
                let opts = this.selects[this.focus]
                if (opts.size > 0) {
                    var idx: Int64 = 0
                    let cur = this.values[this.focus]
                    for (j in 0..opts.size) {
                        if (opts[j] == cur) {
                            idx = j
                            break
                        }
                    }
                    if (key.isArrowRight) {
                        idx += 1
                        if (idx >= opts.size) {
                            idx = 0
                        }
                    } else {
                        idx -= 1
                        if (idx < 0) {
                            idx = opts.size - 1
                        }
                    }
                    this.values[this.focus] = opts[idx]
                    this.onSelectChange(this.focus, opts[idx])
                }
                return true
            }
        }
        // Enter → 提交
        if (key.isEnter) {
            this.visible = false
            this.onSubmit(this.values)
            return true
        }
        // 退格：删除当前字段末尾字符（select 字段忽略）
        if (key.isBackspace && !this.isSelect(this.focus)) {
            if (this.focus < this.values.size) {
                let cur = this.values[this.focus]
                if (cur.size > 0) {
                    var cut = cur.size - 1
                    while (cut >= 0) {
                        try {
                            this.values[this.focus] = cur[0..cut]
                            break
                        } catch (e: Exception) {
                            cut -= 1
                        }
                    }
                }
            }
            return true
        }
        // 粘贴事件：整段**替换**当前字段值（配置字段语义：粘贴即填入我的配置，
        // 而非追加在预填值后面）。单行文本字段剥离换行（端点/模型/key 单行，
        // 避免 \n 渲染换行错位）。bracketed paste 含换行也不触发 Enter/提交。
        if (key.isPaste) {
            if (this.focus < this.values.size && !this.isSelect(this.focus)) {
                let cleaned = key.text.replace("\n", "").replace("\r", "")
                this.values[this.focus] = cleaned
            }
            return true
        }
        // 可打印字符：追加到当前字段（select 字段忽略）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace &&
            !key.isTab && !key.isArrowUp && !key.isArrowDown && !key.isArrowLeft && !key.isArrowRight) {
            if (this.focus < this.values.size && !this.isSelect(this.focus)) {
                this.values[this.focus] += key.text
            }
            return true
        }
        // 模态：可见时消费一切按键
        return true
    }

    private func fillSpaces(n: Int64): String {
        if (n <= 0) {
            return ""
        }
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < n) {
            sb.append(" ")
            i += 1
        }
        return sb.toString()
    }

    private static func displayWidth(s: String): Int64 {
        return TuiCanvas.displayWidth(s)
    }
}
