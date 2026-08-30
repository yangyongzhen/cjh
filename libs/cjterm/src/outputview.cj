package cjterm

import std.collection.*

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
    // 思考块（消息流成员，pi transcript 模式）：
    // 渲染时作为消息末尾的合成段（折叠 1 行 / 展开全文），随输出滚动回看；
    // 不写入 output（会话存档不含思考过程）
    public var thinkingText: String = ""
    public var thinkingExpanded: Bool = false
    public var thinkingDone: Bool = false
    // 思考中已消耗 token（流式估算，折叠行显示增长——动态且稳定）
    public var thinkingTokens: Int64 = 0

    public init() {}

    /**
     * 设置思考块内容（reasoning_content 累积）
     */
    public func setThinking(text: String, done: Bool): Unit {
        this.thinkingText = text
        this.thinkingDone = done
    }

    /**
     * 切换思考块展开/折叠
     */
    public func toggleThinking(): Unit {
        this.thinkingExpanded = !this.thinkingExpanded
    }

    /**
     * 设置思考中 token 计数（折叠行显示增长）
     */
    public func setThinkingTokens(tokens: Int64): Unit {
        this.thinkingTokens = tokens
    }

    // ===== 思考内容技术元素高亮 =====
    // 方案 A：只高亮技术关键点（路径/文件名/数字/代码标识符）用青色，
    // 自然语言保持灰色——信息密度高且不打断阅读（词级关键词标绿太刺眼）

    /**
     * 思考行技术元素高亮：
     *   - 数字（含小数）→ 青
     *   - 路径（含 /）→ 青
     *   - 文件/扩展名（word.ext，常见扩展）→ 青
     *   - 代码标识符（含 _ 或驼峰）→ 青
     *   - 其余（自然语言/中文）→ 保持灰色
     * 输入为纯文本行（折行后），输出带 ANSI 色。
     */
    private func highlightThinking(line: String): String {
        let runes = line.toRuneArray()
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < runes.size) {
            let ch = runes[i]
            // 技术 token 字符集：字母/数字/下划线/斜杠/点/连字符
            if (isTechChar(ch)) {
                var token = StringBuilder()
                var isAllDigit: Bool = true
                var hasSlash: Bool = false
                var hasUnderscore: Bool = false
                var hasCamel: Bool = false
                var hasDot: Bool = false
                var prevLower: Bool = false
                while (i < runes.size && isTechChar(runes[i])) {
                    let c = runes[i]
                    token.append(String(c))
                    let v = UInt32(c)
                    if (v >= 48 && v <= 57 || v == 46) {
                        if (v == 46) { hasDot = true }
                    } else {
                        isAllDigit = false
                    }
                    if (v == 47) { hasSlash = true }       // '/'
                    if (v == 95) { hasUnderscore = true }  // '_'
                    if (v == 46) { hasDot = true }         // '.'
                    if (v >= 65 && v <= 90) {              // 大写：驼峰检测
                        if (prevLower) { hasCamel = true }
                    }
                    prevLower = (v >= 97 && v <= 122)
                    i += 1
                }
                let tokenStr = token.toString()
                var isFile: Bool = false
                // word.ext：扩展名匹配
                if (hasDot && !hasSlash && !isAllDigit) {
                    let dotIdx = tokenStr.lastIndexOf(".")
                    if (dotIdx.isSome()) {
                        let ext = tokenStr[(dotIdx.getOrThrow() + 1)..tokenStr.size]
                        if (isKnownExt(ext)) {
                            isFile = true
                        }
                    }
                }
                let isTech = isAllDigit || hasSlash || hasUnderscore || hasCamel || isFile
                if (isTech) {
                    sb.append(Ansi.fg(Ansi.THEME_ACCENT) + tokenStr + Ansi.reset())
                } else {
                    sb.append(tokenStr)
                }
                continue
            }
            sb.append(String(ch))
            i += 1
        }
        return sb.toString()
    }

    /**
     * 技术 token 字符：字母/数字/下划线/斜杠/点/连字符
     */
    private func isTechChar(ch: Rune): Bool {
        let v = UInt32(ch)
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) ||
            (v >= 97 && v <= 122) || v == 95 || v == 47 || v == 46 || v == 45
    }

    /**
     * 常见文件扩展名
     */
    private func isKnownExt(ext: String): Bool {
        let exts = ["cj", "cangjie", "js", "ts", "html", "css", "py", "rs", "go",
            "java", "c", "h", "cpp", "sh", "bash", "json", "toml", "yaml", "yml",
            "md", "txt", "log", "sql", "db", "png", "jpg", "svg", "xml", "ini"]
        for (e in exts) {
            if (ext == e) {
                return true
            }
        }
        return false
    }

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
     * 确保输出以换行结尾（工具调用提示等新行开始的元素调用；
     * 流式文本 appendDelta 不换行，直接 append 会拼到文字后面）
     */
    public func ensureNewline(): Unit {
        let s = this.output.toString()
        if (s.size > 0 && s[s.size - 1] != 10u8) {
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
        // 消息流行：output 基础行 + 思考块合成段（消息末尾）
        var outLines = ArrayList<String>()
        for (l in this.output.toString().split("\n", -1)) {
            outLines.add(l)
        }
        // 思考块：折叠 1 行 / 展开全部内容行（前缀 "› "），作为消息流成员
        if (this.thinkingText.size > 0) {
            if (this.thinkingExpanded) {
                let status: String = if (this.thinkingDone) { "思考过程 · Ctrl+T 折叠" } else { "思考中… · Ctrl+T 折叠" }
                outLines.add(Ansi.fg(Ansi.THEME_MUTED) + "💭 " + status + Ansi.reset())
                let contentW: Int64 = if (width > 4) { width - 4 } else { 10 }
                var cur: String = ""
                var curW: Int64 = 0
                for (r in this.thinkingText.toRuneArray()) {
                    let ch = r.toString()
                    if (ch == "\n") {
                        outLines.add(Ansi.fg(Ansi.THEME_MUTED) + "› " + this.highlightThinking(cur) + Ansi.reset())
                        cur = ""
                        curW = 0
                        continue
                    }
                    let chW: Int64 = TuiCanvas.displayWidth(ch)
                    if (curW + chW > contentW) {
                        outLines.add(Ansi.fg(Ansi.THEME_MUTED) + "› " + this.highlightThinking(cur) + Ansi.reset())
                        cur = ch
                        curW = chW
                    } else {
                        cur += ch
                        curW += chW
                    }
                }
                if (cur.size > 0) {
                    outLines.add(Ansi.fg(Ansi.THEME_MUTED) + "› " + this.highlightThinking(cur) + Ansi.reset())
                }
            } else {
                if (this.thinkingDone) {
                    outLines.add(Ansi.fg(Ansi.THEME_MUTED) + "💭 思考过程 · Ctrl+T 查看" + Ansi.reset())
                } else {
                    // 思考中：显示 token 计数增长（+ 动态状态行 spinner），
                    // 不做内容滚动——尾部窗口逐字符前进会碎片闪烁（用户实测）
                    var label = "💭 思考中…"
                    if (this.thinkingTokens > 0) {
                        label = "💭 思考中… (↑ ${this.thinkingTokens} tokens)"
                    }
                    outLines.add(Ansi.fg(Ansi.THEME_WARN) + label + Ansi.reset() +
                        Ansi.fg(Ansi.THEME_MUTED) + " · Ctrl+T 展开" + Ansi.reset())
                }
            }
        }
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
