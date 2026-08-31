package cjterm

import std.collection.*
import std.convert.Parsable

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
    // 提示符可见文本（不含 ANSI）与其着色渲染文本（omp 风格：╰─ 底边框 + ❯）
    private var promptText: String = "╰─ ❯ "
    private var promptRendered: String = Ansi.fg(Ansi.THEME_MUTED) + "╰─ " + Ansi.reset() + Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset()

    // 变更回调（输入内容变化时触发，参数为新内容）
    public var onChange: (String) -> Unit = { _ => }
    // 提交回调（回车时触发，参数为完整输入——大粘贴已展开为原文）
    public var onSubmit: (String) -> Unit = { _ => }

    // ===== 输入历史（↑↓ 切换，对齐 omp/通用 CLI）=====
    private var history: ArrayList<String> = ArrayList<String>()
    private var historyIndex: Int64 = -1   // -1=正常输入；0=最新一条；越大越旧
    private var historyDraft: String = ""  // 浏览历史前保存的当前输入（↓ 回底部恢复）
    private let historyMax: Int64 = 50

    // ===== 大粘贴折叠（[Paste #N] marker，对齐 omp）=====
    private var pasteStore: ArrayList<String> = ArrayList<String>()
    private var pasteCounter: Int64 = 0
    private let pasteCollapseChars: Int64 = 1000
    // 最近一次提交的显示文本（折叠 marker 或原文）——供上层回显
    private var lastEcho: String = ""

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
     * 加入输入历史（提交时调用）：非空且与最近一条不同；超上限移除最旧
     */
    public func addToHistory(text: String): Unit {
        if (text.size == 0) {
            return
        }
        if (this.history.size > 0 && this.history[this.history.size - 1] == text) {
            return  // 与最近一条相同：不重复
        }
        this.history.add(text)
        if (Int64(this.history.size) > this.historyMax) {
            // 移除最旧（重建，ArrayList 无 removeAt）
            var rest = ArrayList<String>()
            for (i in 1..this.history.size) {
                rest.add(this.history[i])
            }
            this.history = rest
        }
    }

    /**
     * 载入持久化历史（启动时，倒序=旧在前）
     */
    public func setHistory(list: ArrayList<String>): Unit {
        this.history = ArrayList<String>()
        for (h in list) {
            this.history.add(h)
        }
        // 超上限裁剪（保留最近 historyMax 条）
        while (Int64(this.history.size) > this.historyMax) {
            var rest = ArrayList<String>()
            for (i in 1..this.history.size) {
                rest.add(this.history[i])
            }
            this.history = rest
        }
    }

    /**
     * 全部历史（供持久化保存；旧在前）
     */
    public func historyList(): ArrayList<String> {
        return this.history
    }

    /**
     * 展开提交文本：若当前内容是大粘贴折叠 marker，返回原文；否则原样
     */
    public func expandedText(): String {
        let (isMarker, idx) = this.parsePasteMarker(this.text_)
        if (isMarker && idx >= 0 && idx < Int64(this.pasteStore.size)) {
            return this.pasteStore[idx]
        }
        return this.text_
    }

    /**
     * 最近一次提交的显示文本（折叠 marker 或原文）——上层回显用
     */
    public func lastEchoText(): String {
        return this.lastEcho
    }

    /**
     * 解析 "[Paste #N, +X chars]" 折叠 marker
     * @return (是否 marker, 序号 N-1 或 -1)
     */
    private func parsePasteMarker(s: String): (Bool, Int64) {
        if (!s.startsWith("[Paste #")) {
            return (false, -1)
        }
        var numStr = ""
        var i: Int64 = 8  // 跳过 "[Paste #"
        while (i < s.size && s[i] >= 48u8 && s[i] <= 57u8) {  // 数字
            numStr += String(Rune(s[i]))
            i += 1
        }
        if (numStr.size == 0 || i >= s.size || s[i] != 44u8) {  // 数字后须 ","
            return (false, -1)
        }
        try {
            let n = Int64.parse(numStr)
            return (true, n - 1)
        } catch (e: Exception) {
            return (false, -1)
        }
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
        // 历史导航：↑ 上一条 / ↓ 下一条（终端滚轮在非鼠标模式下发 ↑↓ 序列，天然覆盖）
        if (key.isArrowUp) {
            this.historyUp()
            return true
        }
        if (key.isArrowDown) {
            this.historyDown()
            return true
        }
        if (key.isEnter) {
            // 提交（即使内容为空也回调，由上层决定是否忽略）：
            // 大粘贴 marker 展开为原文提交；加入历史；记录回显文本
            let expanded = this.expandedText()
            this.lastEcho = this.text_
            this.addToHistory(expanded)
            this.onSubmit(expanded)
            return true
        }
        if (key.isBackspace) {
            // 大粘贴 marker 是原子 token：退格整体删除（对齐 omp atomic token）
            let (isMarker, _) = this.parsePasteMarker(this.text_)
            if (isMarker) {
                this.text_ = ""
            } else if (this.text_.size > 0) {
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
            }
            this.historyIndex = -1  // 编辑内容：退出历史浏览
            this.onChange(this.text_)
            return true
        }
        // 粘贴事件：整段追加（bracketed paste 含换行也不触发 Enter 提交）。
        // 单行输入框剥离换行（多行内容贴到单行框时保持单行）。
        // 超长粘贴（> pasteCollapseChars）折叠为 [Paste #N] marker（对齐 omp）
        if (key.isPaste) {
            if (key.text.size > 0) {
                let clean = key.text.replace("\n", "").replace("\r", "")
                if (Int64(clean.size) > this.pasteCollapseChars) {
                    this.pasteCounter += 1
                    this.pasteStore.add(clean)
                    this.text_ = "[Paste #${this.pasteCounter}, +${clean.toRuneArray().size} chars]"
                } else {
                    this.text_ += clean
                }
                this.historyIndex = -1
                this.onChange(this.text_)
            }
            return true
        }
        // 可打印字符（含中文等多字节 UTF-8；排除控制键）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace) {
            // 编辑内容：退出历史浏览（draft 失效）
            this.historyIndex = -1
            this.text_ += key.text
            this.onChange(this.text_)
            return true
        }
        return false
    }

    /**
     * ↑：上一条历史（首次保存当前输入到 draft；继续↑ 更旧）
     */
    private func historyUp(): Unit {
        if (this.history.size == 0) {
            return
        }
        if (this.historyIndex == -1) {
            this.historyDraft = this.text_  // 保存当前输入，↓ 回底部恢复
            this.historyIndex = 0
        } else if (this.historyIndex < Int64(this.history.size) - 1) {
            this.historyIndex += 1
        } else {
            return  // 已到最旧
        }
        this.text_ = this.history[this.history.size - 1 - this.historyIndex]
        this.onChange(this.text_)
    }

    /**
     * ↓：下一条历史；回到底部恢复 draft（当前输入）
     */
    private func historyDown(): Unit {
        if (this.historyIndex == -1) {
            return  // 已在底部
        }
        if (this.historyIndex > 0) {
            this.historyIndex -= 1
            this.text_ = this.history[this.history.size - 1 - this.historyIndex]
        } else {
            this.historyIndex = -1
            this.text_ = this.historyDraft
        }
        this.onChange(this.text_)
    }
}
