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

    // ===== 思考行内 Markdown 渲染（粗体 / 行内代码）=====
    // 思考内容在灰斜体基础上叠加语法高亮（对齐 pi：thinking 走 Markdown 渲染）
    // 基础样式：灰斜体（行前缀）；行内高亮后恢复灰斜体（非全 reset）

    /**
     * 行内 Markdown 渲染：**粗体** → bold；`行内代码` → 青色。
     * 输入为纯文本行（折行后），输出带 ANSI（灰斜体基础 + 行内高亮叠加）。
     * 颜色对齐 omp（collab-web transcript.css）：内容=--fg-muted(≈249 #aaaaaa)，
     * 头部=--fg-faint(≈244 #787878)——比正文素白暗一档可区分，又比中灰 MUTED 亮
     */
    private func renderInlineMd(line: String): String {
        let runes = line.toRuneArray()
        var sb = StringBuilder()
        var i: Int64 = 0
        var boldOn: Bool = false
        var codeOn: Bool = false
        // 恢复基础样式（行内高亮后回到灰斜体）
        func restore(): String {
            return Ansi.fg(249) + Ansi.italic()
        }
        while (i < runes.size) {
            let ch = runes[i].toString()
            // 粗体 **
            if (ch == "*") {
                if (i + 1 < runes.size && runes[i + 1].toString() == "*") {
                    boldOn = !boldOn
                    sb.append(if (boldOn) { Ansi.bold() } else { restore() })
                    i += 2
                    continue
                }
                sb.append(ch)
                i += 1
                continue
            }
            // 行内代码 `
            if (ch == "`") {
                codeOn = !codeOn
                sb.append(if (codeOn) { Ansi.fg(Ansi.THEME_ACCENT) } else { restore() })
                i += 1
                continue
            }
            sb.append(ch)
            i += 1
        }
        // 未闭合的粗体/代码：恢复基础样式
        if (boldOn || codeOn) {
            sb.append(restore())
        }
        return sb.toString()
    }

    /**
     * 设置思考中 token 计数（折叠行显示增长）
     */
    public func setThinkingTokens(tokens: Int64): Unit {
        this.thinkingTokens = tokens
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
        // 消息流行：output 基础行 + 思考块合成段（消息流末尾，回复下方）
        // 位置在回复下方是刻意的：流式时输出区锚定底部，思考块始终可见；
        // 若插到回复上方，长回复增长时思考块会先滚出可视区（用户实测反馈）
        var outLines = ArrayList<String>()
        for (l in this.output.toString().split("\n", -1)) {
            outLines.add(l)
        }
        // 思考块：折叠 1 行 / 展开全部内容行（前缀 "› "），作为消息流成员
        if (this.thinkingText.size > 0) {
            if (this.thinkingExpanded) {
                let status: String = if (this.thinkingDone) { "思考过程 · Ctrl+T 折叠" } else { "思考中… · Ctrl+T 折叠" }
                outLines.add(Ansi.fg(244) + "💭 " + status + Ansi.reset())
                let contentW: Int64 = if (width > 4) { width - 4 } else { 10 }
                var cur: String = ""
                var curW: Int64 = 0
                for (r in this.thinkingText.toRuneArray()) {
                    let ch = r.toString()
                    if (ch == "\n") {
                        outLines.add(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur) + Ansi.reset())
                        cur = ""
                        curW = 0
                        continue
                    }
                    let chW: Int64 = TuiCanvas.displayWidth(ch)
                    if (curW + chW > contentW) {
                        outLines.add(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur) + Ansi.reset())
                        cur = ch
                        curW = chW
                    } else {
                        cur += ch
                        curW += chW
                    }
                }
                if (cur.size > 0) {
                    outLines.add(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur) + Ansi.reset())
                }
            } else {
                if (this.thinkingDone) {
                    outLines.add(Ansi.fg(244) + "💭 思考过程 · Ctrl+T 查看" + Ansi.reset())
                } else {
                    // 思考中：显示 token 计数增长（+ 动态状态行 spinner），
                    // 不做内容滚动——尾部窗口逐字符前进会碎片闪烁（用户实测）
                    var label = "💭 思考中…"
                    if (this.thinkingTokens > 0) {
                        label = "💭 思考中… (↑ ${this.thinkingTokens} tokens)"
                    }
                    outLines.add(Ansi.fg(244) + label + Ansi.reset() +
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
