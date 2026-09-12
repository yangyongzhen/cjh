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
    // 每轮按 anchorLines 交织回消息流（默认折叠 1 行 / Ctrl+T 展开全文），
    // 随输出滚动回看；不写入 output（会话存档不含思考过程）
    public var thinkingExpanded: Bool = false
    // 多轮思考历史：每轮独立保留。旧实现只留"最新一轮"（新一轮开始时清空上一轮），
    // 历史无从回看；旧布局又把全部思考堆在消息流末尾（会话底部）。现在逐轮累积
    // 且按锚点插回各自位置（见 render），复用输出区既有 PageUp/PageDown/Ctrl+U/Ctrl+D
    // （见本类 handleKey）滚动回看。
    private var thinkLog: ThinkingLog = ThinkingLog()
    // 已完成轮次的冻结渲染行：避免每帧重排全部历史（轮数越多越明显）。
    // thinkFrozenCount 记录建缓存时的总轮数，轮数变化（新开轮/淘汰）即整体重建，
    // 保证头部文案（单轮 "思考过程" / 多轮 "#n"）与轮次编号始终一致。
    // 渲染按 anchorLines 把每轮插回消息流（见 render），故这里额外记每轮边界。
    private var thinkFrozen: ArrayList<String> = ArrayList<String>()
    // 每轮在 thinkFrozen 中的结束下标（切片用）：轮 k 的行 = ends[k-1]..ends[k]。
    // 交织渲染要按轮取行，这里只记边界、不复制，避免每帧 O(全历史) 切片拷贝。
    private var thinkFrozenEnds: ArrayList<Int64> = ArrayList<Int64>()
    private var thinkFrozenRounds: Int64 = 0
    private var thinkFrozenCount: Int64 = 0
    private var thinkFrozenWidth: Int64 = -1

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
        let gen = this.thinkLog.roundGen
        this.thinkLog.setCurrent(text, done)
        if (this.thinkLog.roundGen != gen) {
            this.anchorNewRound()
        }
    }

    /**
     * 追加思考增量（流式路径）：末轮已完成时自动开新轮，
     * 上一轮不再被清空——这是"可回看历史思考"的关键。
     */
    public func appendThinking(delta: String): Unit {
        let gen = this.thinkLog.roundGen
        this.thinkLog.append(delta)
        if (this.thinkLog.roundGen != gen) {
            this.anchorNewRound()
        }
    }

    /**
     * 新开轮次钉交织锚点 = 消息流中"下一段内容将要落笔"的行位。
     *
     * 此刻本轮回复还没写入，故渲染时思考块落在自己那条回复**之前**；
     * 多轮则各自钉在自己的位置，不再全部堆到会话末尾。
     *
     * 取行位的规则（关键，勿简化回 lineCache.size）：行缓存按 split(-1) 语义，
     * 末行是"当前行"。推理开始时通常末行为空（刚写完换行/空行分隔），随后的回复
     * 就近写入该行，因此锚点须取**该行下标**（size-1）；若取 size（其后一位），
     * 回复落笔在这一行，思考块就被排到回复之后——即"思考在回复下方"的老布局。
     * 末行非空（半行未收尾）时按 size 插在其后，保证不吞行。
     */
    private func anchorNewRound(): Unit {
        if (!this.cacheValid) {
            this.rebuildCache()
        }
        let blocks = this.thinkLog.blocksView()
        if (blocks.size == 0) {
            return
        }
        var a = this.lineCache.size
        if (a > 0 && this.lineCache[a - 1].size == 0) {
            a -= 1
        }
        if (a < 0) {
            a = 0
        }
        blocks[blocks.size - 1].anchorLines = a
    }

    /**
     * 结束当前轮思考（正式 content 开始 / 新一轮开始前）
     */
    public func finishThinking(): Unit {
        this.thinkLog.finishCurrent()
    }

    /** 已保留的思考轮数（TUI/测试观察点） */
    public func thinkingRounds(): Int64 {
        return this.thinkLog.roundCount()
    }

    /** 末轮是否仍在思考中 */
    public func thinkingActive(): Bool {
        return this.thinkLog.isActive()
    }

    /** 清空思考历史（含冻结行缓存） */
    public func clearThinking(): Unit {
        this.thinkLog.clear()
        this.thinkFrozen = ArrayList<String>()
        this.thinkFrozenEnds = ArrayList<Int64>()
        this.thinkFrozenRounds = 0
        this.thinkFrozenCount = 0
        this.thinkFrozenWidth = -1
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
     * 折叠态：1 行摘要。单轮沿用原有文案（既有测试锁死该契约）；
     * 多轮显示轮数，提示可展开回看历史。
     */
    private func collapsedThinkingLine(rounds: Int64): String {
        let active = this.thinkLog.isActive()
        if (rounds == 1) {
            if (!active) {
                return Ansi.fg(244) + "💭 思考过程 · Ctrl+T 查看" + Ansi.reset()
            }
            let tokens = this.thinkLog.blocksView()[0].tokens
            var label = "💭 思考中…"
            if (tokens > 0) {
                label = "💭 思考中… (↑ ${fmtTokenCount(tokens)} tokens)"
            }
            return Ansi.fg(244) + label + Ansi.reset() +
                Ansi.fg(Ansi.THEME_MUTED) + " · Ctrl+T 展开" + Ansi.reset()
        }
        if (!active) {
            return Ansi.fg(244) + "💭 思考过程（${rounds} 轮） · Ctrl+T 查看" + Ansi.reset()
        }
        return Ansi.fg(244) + "💭 思考中…（第 ${rounds} 轮）" + Ansi.reset() +
            Ansi.fg(Ansi.THEME_MUTED) + " · Ctrl+T 展开" + Ansi.reset()
    }

    /** 展开态：某轮思考的头部文案（单轮沿用原文案） */
    private func thinkingHeader(b: ThinkingBlock, rounds: Int64): String {
        if (rounds <= 1) {
            return if (b.done) { "💭 思考过程 · Ctrl+T 折叠" } else { "💭 思考中… · Ctrl+T 折叠" }
        }
        return if (b.done) {
            "💭 思考 #${b.round} · Ctrl+T 折叠"
        } else {
            "💭 思考 #${b.round} · 思考中… · Ctrl+T 折叠"
        }
    }

    /**
     * 把一轮思考折成渲染行：头部 + 内容行（两格缩进，行内 Markdown 高亮）。
     * 折行按 Rune 边界与显示宽度计算，与旧实现逐字符行为一致。
     */
    /**
     * 观察点（渲染热点的可观测契约，供测试与实测取证）：
     * 最近一次"活跃轮折行"真正渲染出的内容行数。
     *
     * 展开态每帧都要折进行中的轮次——整轮重折时该值 = 轮内行数（O(轮长)），
     * 改成"已完成行复用 + 未完成行增量"后仅为 1（未完成行）+ 本帧新完成行（O(增量)）。
     */
    public var foldLineWork: Int64 = 0

    /** 展开态"进行中轮次"的增量折行状态（见 thinking_fold.cj 的失效条件说明） */
    private var activeFold: ThinkingActiveFoldCache = ThinkingActiveFoldCache()

    /**
     * 内容行渲染：两格缩进 + 行内 Markdown + 卡片补白（整轮/增量两条路径共用）。
     *
     * 曾用 `› ` 前缀逐行标记，但每行一个 `>` 状符号在长思考下噪音大、观感差；
     * 块身份已由 💭 头部 + 灰斜体 + 背景卡片表达，故只留缩进。
     * 缩进宽度与原前缀一致（均为 2 显示列），折行宽度 thinkingContentWidth 不受影响。
     */
    private func thinkingContentLine(raw: String, width: Int64): String {
        return this.thinkingCard(Ansi.fg(249) + Ansi.italic() + "  " + this.renderInlineMd(raw), width)
    }

    /**
     * 折"进行中"的那一轮（展开态每帧的渲染热点）：已完成行直接复用，只增量折未完成行 + 新片段。
     *
     * 每帧工作量：断行只走"未完成行 + 本帧新增"（≤ 一行宽 + 增量），渲染只做
     * "本帧新完成行 + 1 行未完成行"——旧实现是整轮 O(轮长) 重折 + 每行重渲染。
     * 失效（轮次/文本代数/宽度/文本变短）时从 0 重折一次，其余帧均为增量。
     */
    private func foldThinkingActive(b: ThinkingBlock, width: Int64): ArrayList<String> {
        let runes = b.runeArray()
        let contentW = thinkingContentWidth(width)
        let cache = this.activeFold
        let headRunes = b.headRunes
        if (cache.roundGen != this.thinkLog.roundGen || cache.textEpoch != this.thinkLog.textEpoch
            || cache.width != width || cache.tailStart > runes.size) {
            // 截断后的头部（前 headRunes 个 Rune）内容永久稳定：内容与长度都没变就直接复用，
            // 只从"省略标记行"起重折；否则从头折一次并把头部冻住
            var reuseHead = false
            if (headRunes > 0 && cache.headRunes == headRunes) {
                reuseHead = cache.headText == thinkingHeadText(runes, headRunes)
            }
            cache.roundGen = this.thinkLog.roundGen
            cache.textEpoch = this.thinkLog.textEpoch
            cache.width = width
            cache.lines = ArrayList<String>()
            if (reuseHead) {
                // head + "\n" + 省略标记 + "\n" + tail：标记行紧跟在头部那个换行之后
                cache.tailStart = if (headRunes < runes.size) { headRunes + 1 } else { headRunes }
            } else {
                cache.headRunes = 0
                cache.headText = ""
                cache.headLines = ArrayList<String>()
                cache.tailStart = 0
                if (headRunes > 0) {
                    let headAll = foldThinkingSpans(runes, 0, contentW)
                    var k: Int64 = 0
                    while (k < headAll.lines.size && headAll.starts[k] < headRunes) {
                        cache.headLines.add(this.thinkingContentLine(headAll.lines[k], width))
                        k += 1
                    }
                    cache.headRunes = headRunes
                    cache.headText = thinkingHeadText(runes, headRunes)
                    cache.tailStart = if (k < headAll.lines.size) { headAll.starts[k] } else { headRunes }
                }
            }
        }
        let spans = foldThinkingSpans(runes, cache.tailStart, contentW)
        let n = spans.lines.size
        var rendered: Int64 = 0
        // 除最后一行外都已断行完成：渲染一次后进入缓存，后续帧不再重折/重渲染
        if (n > 0) {
            for (i in 0..(n - 1)) {
                cache.lines.add(this.thinkingContentLine(spans.lines[i], width))
                rendered += 1
            }
        }
        let out = ArrayList<String>()
        // 头部卡片行（与整轮折行一致，必须每帧产出且置顶）
        out.add(this.thinkingCard(Ansi.fg(244) + this.thinkingHeader(b, this.thinkLog.roundCount()), width))
        this.appendLines(out, cache.headLines)
        this.appendLines(out, cache.lines)
        // 最后一行可能尚未完成（还可能被追加），每帧重渲染；下一帧从它的起点续折
        if (n > 0) {
            out.add(this.thinkingContentLine(spans.lines[n - 1], width))
            rendered += 1
        }
        cache.tailStart = spans.lastStart
        this.foldLineWork = rendered
        return out
    }

    /** 整轮一次性折行（轮次结束后的冻结路径）：断行规则与增量路径共用 thinking_fold.cj */
    private func foldThinkingBlock(b: ThinkingBlock, width: Int64): ArrayList<String> {
        let lines = ArrayList<String>()
        lines.add(this.thinkingCard(Ansi.fg(244) + this.thinkingHeader(b, this.thinkLog.roundCount()), width))
        let spans = foldThinkingSpans(b.runeArray(), 0, thinkingContentWidth(width))
        for (raw in spans.lines) {
            lines.add(this.thinkingContentLine(raw, width))
        }
        return lines
    }

    /**
     * 展开态的冻结行：完成轮次只折一次并缓存，每帧只为"进行中"那一轮重排
     * （旧实现每帧重排全部思考，长会话下随内容线性增重）。
     */
    private func thinkFrozenFor(width: Int64): Unit {
        let count = this.thinkLog.roundCount()
        if (this.thinkFrozenWidth != width || this.thinkFrozenCount != count) {
            this.rebuildThinkFrozen(width, count)
        } else {
            let blocks = this.thinkLog.blocksView()
            while (this.thinkFrozenRounds < blocks.size && blocks[this.thinkFrozenRounds].done) {
                this.freezeRound(blocks[this.thinkFrozenRounds], width)
            }
        }
    }

    private func rebuildThinkFrozen(width: Int64, count: Int64): Unit {
        this.thinkFrozen = ArrayList<String>()
        this.thinkFrozenEnds = ArrayList<Int64>()
        this.thinkFrozenRounds = 0
        this.thinkFrozenCount = count
        this.thinkFrozenWidth = width
        let blocks = this.thinkLog.blocksView()
        while (this.thinkFrozenRounds < blocks.size && blocks[this.thinkFrozenRounds].done) {
            this.freezeRound(blocks[this.thinkFrozenRounds], width)
        }
    }

    /**
     * 冻结一轮：折行追加到平铺缓存，并记下该轮结束下标（render 按轮切片交织）。
     * 只记边界不复制——避免每帧为每轮做一次 O(该轮行数) 的切片拷贝。
     */
    private func freezeRound(b: ThinkingBlock, width: Int64): Unit {
        this.appendLines(this.thinkFrozen, this.foldThinkingBlock(b, width))
        this.thinkFrozenEnds.add(this.thinkFrozen.size)
        this.thinkFrozenRounds += 1
    }

    /** 批量追加行（ArrayList 无批量接口，集中一处避免重复循环） */
    private func appendLines(dst: ArrayList<String>, src: ArrayList<String>): Unit {
        for (line in src) {
            dst.add(line)
        }
    }

    /**
     * 设置思考中 token 计数（折叠行显示增长）
     */
    public func setThinkingTokens(tokens: Int64): Unit {
        this.thinkLog.setTokens(tokens)
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
        // + 每轮思考段按其 anchorLines 交织回消息流（落在自己那条回复之前）
        if (!this.cacheValid) {
            this.rebuildCache()
        }
        // 思考块：折叠 1 行摘要（贴消息流末尾）/ 展开逐轮全文（内容行两格缩进，各归其位）。
        // 多轮历史全部保留并计入下方滚动范围，展开后即可用 PageUp/PageDown
        // （本类 handleKey）回看任意历史轮次的思考内容
        // 渲染性能埋点（默认关闭；关闭时不读时钟、不落盘，见 perf.cj）：
        // 这里正是"展开态每帧重折进行中轮"的热点，用于实测单帧折行耗时/行数/活跃轮长度
        PerfTrace.onRender()
        let foldStartUs = PerfTrace.beginFold()
        var foldRunes: Int64 = 0
        // 思考分组（按轮序）：来源 0=冻结行平铺 / 1=活跃轮本帧折行 / 2=折叠摘要单行
        let grpSrc = ArrayList<Int64>()
        let grpFrom = ArrayList<Int64>()
        let grpCount = ArrayList<Int64>()
        let grpAnchor = ArrayList<Int64>()
        var activeLines = ArrayList<String>()
        var collapsedLine = ArrayList<String>()
        let thinkRounds = this.thinkLog.roundCount()
        if (thinkRounds > 0) {
            if (this.thinkingExpanded) {
                // 已完成轮次走冻结缓存；进行中轮次每帧重排（量级受单轮上限约束）
                this.thinkFrozenFor(width)
                let blocks = this.thinkLog.blocksView()
                for (i in 0..blocks.size) {
                    let b = blocks[i]
                    var src: Int64 = 1
                    var from: Int64 = 0
                    var cnt: Int64 = 0
                    if (b.done && i < this.thinkFrozenRounds) {
                        src = 0
                        from = if (i == 0) { 0 } else { this.thinkFrozenEnds[i - 1] }
                        cnt = this.thinkFrozenEnds[i] - from
                    } else {
                        from = activeLines.size
                        this.appendLines(activeLines, this.foldThinkingActive(b, width))
                        cnt = activeLines.size - from
                        foldRunes += b.runes
                    }
                    grpSrc.add(src)
                    grpFrom.add(from)
                    grpCount.add(cnt)
                    grpAnchor.add(this.roundAnchor(b))
                }
            } else {
                collapsedLine.add(this.collapsedThinkingLine(thinkRounds))
                grpSrc.add(2)
                grpFrom.add(0)
                grpCount.add(1)
                grpAnchor.add(this.lineCache.size)
            }
        }
        var thinkLines: Int64 = 0
        for (c in grpCount) {
            thinkLines += c
        }
        PerfTrace.foldDone(foldStartUs, thinkLines, foldRunes)
        // 交织段表：基础行段（lineCache 切片）与思考段交替，段数 ≤ 2×轮数+1；
        // 可见窗口只遍历段表 O(可见行)，不做整段拼接拷贝（锚点单调化保证段序）
        let segStart = ArrayList<Int64>()
        let segCount = ArrayList<Int64>()
        let segBase = ArrayList<Int64>()
        let segGrp = ArrayList<Int64>()
        var cursor: Int64 = 0
        var total: Int64 = 0
        for (g in 0..grpCount.size) {
            var a = grpAnchor[g]
            if (a < cursor) {
                a = cursor
            }
            if (a > cursor) {
                segStart.add(total)
                segCount.add(a - cursor)
                segBase.add(cursor)
                segGrp.add(-1)
                total += a - cursor
                cursor = a
            }
            segStart.add(total)
            segCount.add(grpCount[g])
            segBase.add(grpFrom[g])
            segGrp.add(g)
            total += grpCount[g]
        }
        if (cursor < this.lineCache.size) {
            segStart.add(total)
            segCount.add(this.lineCache.size - cursor)
            segBase.add(cursor)
            segGrp.add(-1)
            total += this.lineCache.size - cursor
        }
        // 滚动边界修正：最多滚到"最后一行可见"（总行数 = 基础行 + 思考行）
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
        // 可见窗口：按段表取行（基础行直接读缓存、思考段读冻结/活跃行，虚拟拼接无拷贝）
        var r: Int64 = 0
        for (k in 0..segStart.size) {
            if (r >= height) {
                break
            }
            let s0 = segStart[k]
            let s1 = s0 + segCount[k]
            if (s1 <= startIdx) {
                continue
            }
            var j = if (s0 < startIdx) { startIdx } else { s0 }
            while (j < s1 && r < height) {
                let off = j - s0
                let line: String = if (segGrp[k] < 0) {
                    this.lineCache[segBase[k] + off]
                } else if (grpSrc[segGrp[k]] == 0) {
                    this.thinkFrozen[grpFrom[segGrp[k]] + off]
                } else if (grpSrc[segGrp[k]] == 1) {
                    activeLines[grpFrom[segGrp[k]] + off]
                } else {
                    collapsedLine[grpFrom[segGrp[k]] + off]
                }
                canvas.setLine(row + r, line)
                r += 1
                j += 1
            }
        }
        return r
    }

    /**
     * 某轮的交织锚点：未定锚（-1）或越界（输出被外部替换后变短）一律贴消息流末尾，
     * 保证不崩、不吞行；锚点单调化由 render 的段表游标兜底。
     */
    private func roundAnchor(b: ThinkingBlock): Int64 {
        var a = b.anchorLines
        if (a < 0 || a > this.lineCache.size) {
            a = this.lineCache.size
        }
        return a
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
