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

    // 行缓存：恒等于 output.toString().split("\n", -1) 的行列表。
    // append/appendDelta/endStream/ensureNewline 增量维护（O(本帧文本)），
    // render 不再每帧全量 split（旧实现每帧 O(总量)，长会话卡主循环）。
    // 不变式由 outputview_linecache_test 锁死（含尾/首空串边界语义）。
    private var lineCache: ArrayList<String> = ArrayList<String>()
    private var cacheValid: Bool = false

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

    // 思考块整行背景卡片（P2b，≈ omp thinkingBg #141414）：
    // 内容行只用 fg/italic/bold 改色、禁止 reset（reset 会清背景使卡片断裂），
    // 本函数统一铺 bg 233 并按 displayWidth 补空格到 w，行尾 reset 由 padBg 补。
    private func thinkingCard(inner: String, w: Int64): String {
        return Ansi.padBg(inner, w - 1, Ansi.THEME_THINKING_BG)
    }

    /**
     * 设置思考中 token 计数（折叠行显示增长）
     */
    public func setThinkingTokens(tokens: Int64): Unit {
        this.thinkingTokens = tokens
    }

    // ===== 行缓存增量维护（P2/G4）=====

    /**
     * 全量重建行缓存（首帧 / 外部替换 output 后）。O(总量)，仅低频路径调用
     */
    private func rebuildCache(): Unit {
        let lc = ArrayList<String>()
        for (l in this.output.toString().split("\n", -1)) {
            lc.add(l)
        }
        this.lineCache = lc
        this.cacheValid = true
    }

    /**
     * 增量同步：output 在末尾追加了 d（d 为任意字节序列，可能含 \n）后同步行缓存。
     * 语义恒等于 (旧output+d).split("\n",-1) 相对旧行的增量：
     * - d 无 \n：整体拼到最后一行
     * - d 含 \n：末行 += 首段，中间段逐段 add
     * - d 以 \n 结尾：末尾产生空行（对齐 split -1 尾空串）
     * - d 为空：无操作
     */
    private func syncDelta(d: String): Unit {
        if (!this.cacheValid) {
            // 首次/失效后：调用前 output 已含本增量 d，全量重建即为最新态，直接返回
            // （若再叠加 d 会双重应用——已踩坑：首帧 cache 翻倍）
            this.rebuildCache()
            return
        }
        if (d.size == 0) {
            return
        }
        let parts = d.split("\n", -1)
        // 末行 += 首段（d 以 \n 开头时首段为空，末行不变）
        if (this.lineCache.size > 0) {
            this.lineCache[this.lineCache.size - 1] = this.lineCache[this.lineCache.size - 1] + parts[0]
        } else {
            this.lineCache.add(parts[0])
        }
        // 其余段逐段 add（d 以 \n 结尾时末段为空 → 补空行）
        for (i in 1..parts.size) {
            this.lineCache.add(parts[i])
        }
    }

    /**
     * 追加一行到输出区（自动补 \n）
     */
    public func append(text: String): Unit {
        this.output.append(text)
        if (text.size == 0 || text[text.size - 1] != 10u8) {
            this.output.append("\n")
            this.syncDelta(text + "\n")
        } else {
            this.syncDelta(text)
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
            this.syncDelta("\n")
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
        this.syncDelta(text)
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
            // output 被替换（尾部截断重写）：行缓存全量重建。
            // 流式段起点可能在行中间（前文无 \n 结尾时），截断前缀不可靠，
            // 重建是唯一安全解。endStream 每响应一次（非热路径），成本可接受。
            this.rebuildCache()
        }
        this.output.append(text)
        this.syncDelta(text)
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
     * 行缓存快照（测试钩子：与 content().split("\n", -1) 断言逐位等价）
     */
    public func cachedLines(): ArrayList<String> {
        return this.lineCache
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

    /**
     * 是否已向上滚动（未在最新位置）——状态栏显示滚动提示用
     */
    public func isScrolled(): Bool {
        return this.scrollOffset > 0
    }

    /**
     * 当前滚动偏移行数（状态栏提示用）
     */
    public func scrollOffsetLines(): Int64 {
        return this.scrollOffset
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        // 消息流行：output 基础行（行缓存，P2：每帧 O(可见窗口) 而非 O(总量)）
        // + 思考块合成段（消息流末尾，回复下方）
        // 位置在回复下方是刻意的：流式时输出区锚定底部，思考块始终可见；
        // 若插到回复上方，长回复增长时思考块会先滚出可视区（用户实测反馈）
        if (!this.cacheValid) {
            this.rebuildCache()
        }
        // 思考块：折叠 1 行 / 展开全部内容行（前缀 "› "），作为消息流成员
        var thinkLines = ArrayList<String>()
        if (this.thinkingText.size > 0) {
            if (this.thinkingExpanded) {
                let status: String = if (this.thinkingDone) { "思考过程 · Ctrl+T 折叠" } else { "思考中… · Ctrl+T 折叠" }
                thinkLines.add(this.thinkingCard(Ansi.fg(244) + "💭 " + status, width))
                let contentW: Int64 = if (width > 4) { width - 4 } else { 10 }
                var cur: String = ""
                var curW: Int64 = 0
                for (r in this.thinkingText.toRuneArray()) {
                    let ch = r.toString()
                    if (ch == "\n") {
                        thinkLines.add(this.thinkingCard(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur), width))
                        cur = ""
                        curW = 0
                        continue
                    }
                    let chW: Int64 = TuiCanvas.displayWidth(ch)
                    if (curW + chW > contentW) {
                        thinkLines.add(this.thinkingCard(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur), width))
                        cur = ch
                        curW = chW
                    } else {
                        cur += ch
                        curW += chW
                    }
                }
                if (cur.size > 0) {
                    thinkLines.add(this.thinkingCard(Ansi.fg(249) + Ansi.italic() + "› " + this.renderInlineMd(cur), width))
                }
            } else {
                if (this.thinkingDone) {
                    thinkLines.add(Ansi.fg(244) + "💭 思考过程 · Ctrl+T 查看" + Ansi.reset())
                } else {
                    // 思考中：显示 token 计数增长（+ 动态状态行 spinner），
                    // 不做内容滚动——尾部窗口逐字符前进会碎片闪烁（用户实测）
                    var label = "💭 思考中…"
                    if (this.thinkingTokens > 0) {
                        label = "💭 思考中… (↑ ${this.thinkingTokens} tokens)"
                    }
                    thinkLines.add(Ansi.fg(244) + label + Ansi.reset() +
                        Ansi.fg(Ansi.THEME_MUTED) + " · Ctrl+T 展开" + Ansi.reset())
                }
            }
        }
        // 滚动边界修正：最多滚到"最后一行可见"（总行数 = 基础行 + 思考行）
        let total = this.lineCache.size + thinkLines.size
        let maxOffset = if (total > height) { total - height } else { 0 }
        if (this.scrollOffset > maxOffset) {
            this.scrollOffset = maxOffset
        }
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
        var startIdx = total - height - this.scrollOffset
        if (startIdx < 0) {
            startIdx = 0
        }
        // 可见窗口：基础行直接取缓存、尾部取思考行（虚拟拼接，无整段拷贝）
        var r: Int64 = 0
        for (i in startIdx..total) {
            if (r >= height) {
                break
            }
            let line: String = if (i < this.lineCache.size) { this.lineCache[i] } else { thinkLines[i - this.lineCache.size] }
            canvas.setLine(row + r, line)
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
