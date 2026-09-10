package cjterm

import std.collection.*
import std.convert.Parsable

/**
 * InputBox：输入组件（参考 pi-tui Input 组件简化）
 *
 * - 提示符前缀（默认 "❯ " 亮青色，可定制）
 * - UTF-8 字节安全退格（按字符删，中文不崩）
 * - 变更回调 onChange（输入变化时触发，供下拉补全等联动）
 * - 提交回调 onSubmit（回车时触发）
 * - 多行软换行显示（v1.3.20）：内容含真实换行（粘贴保留）且按显示宽度
 *   自动软换行；显示区最多 maxVisibleRows 行，视口跟随光标；Enter 仍是
 *   提交键（不换行）
 *
 * 消费按键：可打印字符 / 退格 / 回车（返回 true）；其余按键不消费，
 * 由上层（滚动/Esc 等）处理。
 */
public class InputBox <: Component {
    private var text_: String = ""
    // 光标位置（字节索引，范围 [0..text_.size]）——支持左右移动/插入/删除
    private var cursorPos: Int64 = 0
    // 终端 UTF-8 能力（决定提示符/搜索图标是否走 ASCII 降级）：
    // v1.3.16 前硬编码 UTF-8，Windows 非 65001 代码页下与 logo/状态栏 ASCII 混排
    private var utf8: Bool = true
    // 提示符可见文本（不含 ANSI）与其着色渲染文本（omp 风格：╰─ 底边框 + ❯）
    private var promptText: String = "╰─ ❯ "
    private var promptRendered: String = Ansi.fg(Ansi.THEME_BORDER) + "╰─ " + Ansi.reset() + Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset()

    // 变更回调（输入内容变化时触发，参数为新内容）
    public var onChange: (String) -> Unit = { _ => }
    // 提交回调（回车时触发，参数为完整输入——大粘贴已展开为原文）
    public var onSubmit: (String) -> Unit = { _ => }

    // ===== 输入历史（↑↓ 切换，对齐 omp/通用 CLI）=====
    private var history: ArrayList<String> = ArrayList<String>()
    private var historyIndex: Int64 = -1   // -1=正常输入；0=最新一条；越大越旧
    private var historyDraft: String = ""  // 浏览历史前保存的当前输入（↓ 回底部恢复）
    private let historyMax: Int64 = 50

    // ===== 大粘贴折叠（[Paste #N] marker，对齐 atomcode 阈值）=====
    // 粘贴 ≥ pasteFoldLines 行 或 ≥ pasteFoldChars 字符（码点）折叠为单个原子
    // marker（原文存 pasteStore 不进输入框，避免长内容淹没输入区）；
    // 未达阈值的粘贴原文进入输入框走软换行多行显示。
    // 阈值对齐 atomcode：PASTE_FOLD_LINES=5 / PASTE_FOLD_CHARS=400
    private var pasteStore: ArrayList<String> = ArrayList<String>()
    private var pasteCounter: Int64 = 0
    private let pasteFoldLines: Int64 = 5
    private let pasteFoldChars: Int64 = 400

    // ===== 多行显示状态（v1.3.20 软换行）=====
    // 显示区上限行数（含真实换行 + 软换行）：超长内容视口跟随光标，
    // 避免长粘贴撑满终端；TuiApp 用 displayHeight() 动态布局输入区
    private let maxVisibleRows: Int64 = 5
    // 视口顶端行号（软换行后的行）：滚动状态跨帧保持，光标移出视口时
    // 自动滚动（上滚一行 / 下滚到顶）
    private var viewportTop: Int64 = 0
    // 最近一次提交的文本——供上层回显
    private var lastEcho: String = ""
    // Ctrl+R 历史搜索模式：输入子串实时过滤历史，↑↓ 浏览匹配（对齐 shell reverse-search）
    private var searchMode: Bool = false
    private var searchQuery: String = ""  // 搜索子串（独立于选中项 text_）

    public init() {}

    public init(prompt: String) {
        this.promptText = prompt
        this.promptRendered = Ansi.fg(Ansi.THEME_ACCENT) + prompt + Ansi.reset()
    }

    /**
     * 设置终端 UTF-8 能力（TuiApp 启动时接线；false 时提示符降级 "+-- > "）
     */
    public func setUtf8(v: Bool): Unit {
        this.utf8 = v
        this.rebuildPrompt()
    }

    /**
     * 按 utf8 能力 + 搜索模式重建提示符文本/着色文本
     */
    private func rebuildPrompt(): Unit {
        if (this.searchMode) {
            let icon = if (this.utf8) { "🔍 " } else { "? " }
            let head = if (this.utf8) { "╰─ " } else { "+-- " }
            this.promptText = head + icon
            this.promptRendered = Ansi.fg(Ansi.THEME_BORDER) + head + Ansi.reset() +
                Ansi.fg(Ansi.THEME_WARN) + icon + Ansi.reset()
        } else {
            let head = if (this.utf8) { "╰─ " } else { "+-- " }
            this.promptText = head + "❯ "
            this.promptRendered = Ansi.fg(Ansi.THEME_BORDER) + head + Ansi.reset() +
                Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset()
        }
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
            this.cursorPos = Int64(t.size)  // 外部设置内容：光标置尾
            this.onChange(t)
        }
    }

    /**
     * 设置内容但不触发 onChange（补全确认等场景，避免重新弹候选）
     */
    public func setTextSilent(t: String): Unit {
        this.text_ = t
        this.cursorPos = Int64(t.size)  // 补全确认：光标置尾
    }

    /**
     * 清空内容（不触发 onChange）
     */
    public func clear(): Unit {
        this.text_ = ""
        this.cursorPos = 0
    }

    // ===== 光标移动（UTF-8 字节安全）=====

    /** 光标左移一个字符（UTF-8 多字节跳过连续字节 0x80-0xBF） */
    private func cursorLeft(): Unit {
        if (this.cursorPos > 0) {
            var pos = this.cursorPos - 1
            while (pos > 0 && (this.text_[pos] & 0xC0u8) == 0x80u8) {
                pos -= 1
            }
            this.cursorPos = pos
        }
    }

    /** 光标右移一个字符 */
    private func cursorRight(): Unit {
        if (this.cursorPos < this.text_.size) {
            var pos = this.cursorPos + 1
            while (pos < this.text_.size && (this.text_[pos] & 0xC0u8) == 0x80u8) {
                pos += 1
            }
            this.cursorPos = pos
        }
    }

    /** 光标移到行首 */
    private func cursorHome(): Unit {
        this.cursorPos = 0
    }

    /** 光标移到行尾 */
    private func cursorEnd(): Unit {
        this.cursorPos = this.text_.size
    }

    /** 在光标位置插入文本（UTF-8 字节安全切片） */
    private func insertAtCursor(s: String): Unit {
        let before = if (this.cursorPos > 0) { this.text_[0..this.cursorPos] } else { "" }
        let after = if (this.cursorPos < this.text_.size) { this.text_[this.cursorPos..this.text_.size] } else { "" }
        this.text_ = before + s + after
        this.cursorPos += s.size
    }

    /** 删除光标前一个字符（UTF-8 字节安全） */
    private func backspaceAtCursor(): Unit {
        if (this.cursorPos > 0) {
            var pos = this.cursorPos - 1
            while (pos > 0 && (this.text_[pos] & 0xC0u8) == 0x80u8) {
                pos -= 1
            }
            this.text_ = this.text_[0..pos] + this.text_[this.cursorPos..this.text_.size]
            this.cursorPos = pos
        }
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
     * 最近一次提交的文本——上层回显用
     */
    public func lastEchoText(): String {
        return this.lastEcho
    }

    /**
     * 粘贴追加到光标处：真实换行保留（CRLF→LF 归一化）。
     * 折叠判定（对齐 atomcode PASTE_FOLD_LINES/PASTE_FOLD_CHARS）：
     * ≥5 行 或 ≥400 字符（码点）→ 折叠为原子 marker——多行用 "[Paste #N, +M lines]"、
     * 单行用 "[Paste #N, M chars]"（原文存 pasteStore 不进输入框）；
     * 未达阈值 → 原文插入光标处，按显示宽度自动软换行多行显示。
     * 粘贴后光标置尾（对齐 atomcode "paste places cursor at end"）。
     */
    private func addPasteLine(paste: String): Unit {
        let norm = paste.replace("\r\n", "\n").replace("\r", "\n")
        let lines = this.countLines(norm)
        let chars = this.runeCount(norm)
        if (lines >= this.pasteFoldLines || chars >= this.pasteFoldChars) {
            this.pasteCounter += 1
            this.pasteStore.add(norm)
            let metric = if (lines > 1) {
                "+${Int64(lines)} lines"
            } else {
                "${Int64(chars)} chars"
            }
            this.insertAtCursor("[Paste #${this.pasteCounter}, ${metric}]")
        } else {
            this.insertAtCursor(norm)
        }
    }

    /**
     * 有效内容行数（折叠判定指标）：'\n' 计数，末尾换行不计新行
     * （"l1\nl2"=2、"l1\nl2\n"=2、空串=1）；≥ pasteFoldLines(5) 折叠
     */
    private func countLines(s: String): Int64 {
        if (s.size == 0) {
            return 1
        }
        var n: Int64 = 0
        var i: Int64 = 0
        while (i < s.size) {
            if (s[i] == 10u8) {
                n += 1
            }
            i += 1
        }
        if (s[s.size - 1] != 10u8) {
            n += 1  // 末尾无换行：最后一行没有 '\n'
        }
        return n
    }

    /**
     * 码点数（折叠判定指标，对齐 atomcode text.chars().count()）：
     * CJK 每字计 1（区别于字节/显示宽度）；≥ pasteFoldChars(400) 折叠
     */
    private func runeCount(s: String): Int64 {
        return Int64(s.toRuneArray().size)
    }

    /**
     * 展开提交文本：把文本中的折叠 marker 替换为原文（保留前缀/后缀）。
     * marker 形如 "[Paste #N, +M lines]"：N-1 在 pasteStore 范围内 → 展开；
     * 否则原样保留（用户手敲的同形文本按字面处理）
     */
    public func expandedText(): String {
        let t = this.text_
        if (!t.contains("[Paste #")) {
            return t
        }
        var out = StringBuilder()
        var pos: Int64 = 0
        while (pos < t.size) {
            let hit = this.indexOf(t, "[Paste #", pos)
            if (hit < 0) {
                out.append(t[pos..t.size])
                break
            }
            if (pos < hit) {
                out.append(t[pos..hit])
            }
            let (span, idx) = this.markerSpanAt(t, hit)
            if (span <= 0) {
                out.append(String(Rune(t[hit])))  // 不完整 marker：按普通文本前进一步
                pos = hit + 1
            } else if (idx >= 0 && idx < Int64(this.pasteStore.size)) {
                out.append(this.pasteStore[idx])  // 展开为原文
                pos = hit + span
            } else {
                out.append(t[hit..hit + span])  // 同形但序号无效：原样
                pos = hit + span
            }
        }
        return out.toString()
    }

    /**
     * 解析 "[Paste #N, +X lines]" 折叠 marker（全文即 marker 时）
     * @return (是否 marker, 序号 N-1 或 -1)
     */
    private func parsePasteMarker(s: String): (Bool, Int64) {
        let (span, idx) = this.markerSpanAt(s, 0)
        if (span > 0) {
            return (true, idx)
        }
        return (false, -1)
    }

    /**
     * 解析 hit 位置（"[Paste #" 起点）的折叠 marker：
     * @return (marker 长度(不含结尾) 或 0, 序号 N-1 或 -1)
     */
    private func markerSpanAt(t: String, hit: Int64): (Int64, Int64) {
        let tsize = t.size
        if (tsize < hit + 8) {
            return (0, -1)
        }
        // 前缀 8 个 ASCII 字节逐字节比较——t[hit..hit+8] 切片终点可能落在
        // 多字节字符中部抛 Invalid utf8（§3.15 同族；Backspace 每次都会走到这里）
        let prefix: String = "[Paste #"
        var k: Int64 = 0
        while (k < 8) {
            if (t[hit + k] != prefix[k]) {
                return (0, -1)
            }
            k += 1
        }
        var i: Int64 = hit + 8
        var numStr = ""
        while (i < tsize && t[i] >= 48u8 && t[i] <= 57u8) {  // 数字
            numStr += String(Rune(t[i]))
            i += 1
        }
        if (numStr.size == 0 || i >= tsize || t[i] != 44u8) {  // 数字后须 ","
            return (0, -1)
        }
        let close = this.indexOf(t, "]", i)  // 闭合 "]"
        if (close < 0) {
            return (0, -1)
        }
        try {
            let n = Int64.parse(numStr)
            return (close - hit + 1, n - 1)
        } catch (e: Exception) {
            return (0, -1)
        }
    }

    /**
     * 光标所在软换行行号（从 0 计）：与 wrappedLines 同一换行模型
     * （首行预算 width-提示符宽，续行预算 width-2 缩进），'\n' 计一次换行。
     * 行号上限 4096 防异常数据死循环（粘贴有 2000 码点上界）。
     */
    private func cursorVisualLine(width: Int64): Int64 {
        let (total, pairs) = this.wrappedLines(width)
        var i: Int64 = 0
        let len = this.text_.size
        while (i < pairs.size) {
            let (s, e) = pairs[i]
            if (this.cursorPos > s && this.cursorPos <= e) {
                return i
            }
            i += 1
        }
        return if (total > 1) { total - 1 } else { 0 }
    }

    /**
     * 输入区当前显示行数（1..maxVisibleRows）——TuiApp 动态布局输入区用。
     * 与 render 的 wrappedLines 同源，保证布局行数与渲染行数一致。
     */
    public func displayHeight(width: Int64): Int64 {
        let w = if (width > 1) { width } else { 80 }
        let (total, _) = this.wrappedLines(w)
        if (total > this.maxVisibleRows) {
            return this.maxVisibleRows
        }
        return if (total < 1) { 1 } else { total }
    }

    /**
     * 字节偏移查找子串（仓颉 String 无 indexOf：逐窗口比较，
     * 单行输入框长度有限，O(n*m) 可接受）。
     * 窗口起点必须是 UTF-8 字符边界（首字节 < 0xC0），否则字节切片
     * 落在多字节字符中部会抛 Invalid utf8（§3.15 乱码坑同族）。
     */
    private func indexOf(s: String, sub: String, from: Int64): Int64 {
        if (sub.size == 0 || s.size < sub.size) {
            return -1
        }
        var pos = if (from > 0) { from } else { 0 }
        let limit = s.size - sub.size
        while (pos <= limit) {
            // 0x80-0xBF 是多字节 UTF-8 的后续字节：跳到下一字符边界
            if ((s[pos] & 0xC0u8) == 0x80u8) {
                pos += 1
                continue
            }
            // 窗口终点可能落在多字节字符中部（如 ASCII 窗口切到 CJK
            // 序列中间）：切片抛 Invalid utf8 时推进到下一位置重试
            try {
                if (s[pos..pos + sub.size] == sub) {
                    return pos
                }
            } catch (e: Exception) {
                ()
            }
            pos += 1
        }
        return -1
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

    /**
     * 按显示宽度软换行：'\n' 强制断行，累计显示宽度超可用列数软断行。
     * 每行输出 (起始字节, 结束字节(不含)) 对；末尾 '\n' 产生空尾行。
     * 首行可用宽度 width-promptWidth，后续行用 width（对齐 omp composer：
     * 续行从栏左缘开始）。行宽预算下限 8 列防窄屏死循环。
     * 返回 (总行数, 全部行段)——行段不截断：render 视口滚动后取段
     * 仍命中正确行（截断到视口行数会让滚动视口读到过期首行段，
     * 光标错位——2026-09-09 粘贴光标 bug 根因）。
     */
    private func wrappedLines(width: Int64): (Int64, ArrayList<(Int64, Int64)>) {
        var starts = ArrayList<Int64>()
        var ends = ArrayList<Int64>()
        // 首行预算 = 屏宽 - 提示符宽；续行预算 = 屏宽 - 2 列缩进
        // （续行渲染为 "  "+seg，两列缩进占位；下限 8 列防窄屏死循环）
        let firstAvail = if (width > this.promptWidth() + 8) { width - this.promptWidth() } else { 8 }
        let contAvail = if (width > 10) { width - 2 } else { 8 }
        let len = this.text_.size
        var pos: Int64 = 0
        var segStart: Int64 = 0
        var col: Int64 = 0
        var budget = firstAvail  // 当前行总宽度预算（剩余= budget-col）
        var guardCount: Int64 = 0
        while (pos < len && guardCount < 4096) {
            let b = this.text_[pos]
            if (b == 10u8) {
                starts.add(segStart)
                ends.add(pos)
                pos += 1
                segStart = pos
                col = 0
                budget = contAvail
            } else {
                // 码点显示宽度：CJK/全角=2 列，其余=1 列（对齐 displayWidth 规则）
                let b1 = if (pos + 1 < len) { this.text_[pos + 1] } else { 0u8 }
                let adv: Int64
                let cw: Int64
                if (b < 0x80u8) { adv = 1; cw = 1 }
                else if (b >= 0xF0u8) { adv = 4; cw = 2 }
                else if (b >= 0xE0u8) { adv = 3; cw = 2 }
                else if (b >= 0xC0u8 && b1 >= 0x80u8) { adv = 3; cw = 2 }
                else if (b >= 0xC2u8) { adv = 2; cw = 1 }
                else if (b == 0xC0u8 || b == 0xC1u8 || b1 == 0u8) { adv = 2; cw = 1 }
                else { adv = 3; cw = 1 }
                if (col + cw > budget) {
                    starts.add(segStart)
                    ends.add(pos)
                    segStart = pos
                    col = 0
                    budget = contAvail
                } else {
                    col += cw
                }
                pos += adv
            }
            guardCount += 1
        }
        starts.add(segStart)
        ends.add(len)
        let count = Int64(starts.size)
        var pairs = ArrayList<(Int64, Int64)>()
        for (k in 0..count) {
            pairs.add((starts[k], ends[k]))
        }
        return (count, pairs)
    }

    /** 取前 n 项（行数裁剪辅助） */
    private func firstN(list: ArrayList<Int64>, n: Int64): ArrayList<Int64> {
        var out = ArrayList<Int64>()
        let lim = if (Int64(list.size) < n) { Int64(list.size) } else { n }
        var k: Int64 = 0
        while (k < lim) {
            out.add(list[k])
            k += 1
        }
        return out
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let (total, pairs) = this.wrappedLines(width)
        // 视口跟随光标：光标行高于视口顶 → 上滚一行；低于视口底 → 下滚到顶
        let cursorLine = this.cursorVisualLine(width)
        let viewH = this.maxVisibleRows
        if (cursorLine < this.viewportTop) {
            this.viewportTop = cursorLine
        } else if (cursorLine >= this.viewportTop + viewH) {
            this.viewportTop = cursorLine - viewH + 1
        }
        if (this.viewportTop > total - 1) {
            this.viewportTop = if (total > 1) { total - 1 } else { 0 }
        }
        if (this.viewportTop < 0) {
            this.viewportTop = 0
        }
        let curLineNo: Int64 = this.viewportTop
        for (k in 0..viewH) {
            let lineNo = curLineNo + k
            if (lineNo >= total) {
                break
            }
            let (s, e) = pairs[Int64(lineNo)]
            let seg = if (s < e) { this.text_[s..e] } else { "" }
            let content: String = if (lineNo == 0) {
                this.promptRendered + seg
            } else {
                "  " + seg  // 续行缩进 2 列（与 ❯ 对齐，可读性）
            }
            canvas.setLine(row + k, content)
        }
        // 光标定位：光标行在视口内时落在其软换行行，否则落在视口末行
        let curRowOff: Int64
        if (cursorLine >= curLineNo && cursorLine < curLineNo + viewH) {
            curRowOff = cursorLine - curLineNo
        } else if (cursorLine >= curLineNo + viewH) {
            curRowOff = viewH - 1
        } else {
            curRowOff = 0
        }
        // 列 = 提示符宽（仅首行）+ 2 列缩进（仅续行）+ 光标前文本从行首
        // 累计的显示宽度（与 wrappedLines 同一预算模型；到行尾软换行点截断）。
        // 行段按绝对行号取（curLineNo+curRowOff=光标所在软换行行），非视口内偏移
        let cursorRowAbs: Int64 = if (curRowOff < 0) { 0 } else { curRowOff }
        let (lineStart, _) = pairs[Int64(curLineNo + cursorRowAbs)]
        let tlen = this.text_.size
        let firstAvail = if (width > this.promptWidth() + 8) { width - this.promptWidth() } else { 8 }
        let contAvail = if (width > 10) { width - 2 } else { 8 }
        var col: Int64 = 0
        var budget = if (curRowOff == 0) { firstAvail } else { contAvail }
        var i: Int64 = lineStart
        while (i < this.cursorPos && i < tlen && col < budget) {
            let b = this.text_[i]
            if (b == 10u8) {
                i += 1  // 正常路径不会进入（行内无换行）；防御
                col = 0
                budget = contAvail
            } else {
                let b1 = if (i + 1 < tlen) { this.text_[i + 1] } else { 0u8 }
                let adv: Int64
                let cw: Int64
                if (b < 0x80u8) { adv = 1; cw = 1 }
                else if (b >= 0xF0u8) { adv = 4; cw = 2 }
                else if (b >= 0xE0u8) { adv = 3; cw = 2 }
                else if (b >= 0xC0u8 && b1 >= 0x80u8) { adv = 3; cw = 2 }
                else if (b >= 0xC2u8) { adv = 2; cw = 1 }
                else if (b == 0xC0u8 || b == 0xC1u8 || b1 == 0u8) { adv = 2; cw = 1 }
                else { adv = 3; cw = 1 }
                if (col + cw > budget) {
                    break  // 光标在此软换行点之后：停在行首
                }
                col += cw
                i += adv
            }
        }
        let baseCols = if (curRowOff == 0) { TuiCanvas.displayWidth(this.promptText) } else { 2 }
        canvas.setCursor(row + curRowOff + 1, baseCols + col)
        return viewH
    }

    public override func handleKey(key: KeyEvent): Bool {
        // Ctrl+R：历史搜索模式开关（输入子串实时过滤，↑↓ 浏览匹配）
        if (key.ch == 18 && !key.isEsc) {
            this.toggleSearch()
            return true
        }
        // 历史导航：↑ 上一条 / ↓ 下一条（终端滚轮在非鼠标模式下发 ↑↓ 序列，天然覆盖）
        if (key.isArrowUp) {
            this.historyUp()
            return true
        }
        if (key.isArrowDown) {
            this.historyDown()
            return true
        }
        // 光标移动：← 左移 / → 右移
        if (key.isArrowLeft) {
            this.cursorLeft()
            return true
        }
        if (key.isArrowRight) {
            this.cursorRight()
            return true
        }
        if (key.isEnter) {
            // 提交（即使内容为空也回调，由上层决定是否忽略）：
            // 折叠 marker 展开为原文提交（多行换行保留）；加入历史；
            // 记录回显文本（展开原文，输出区自动软换行）；清空并复位视口
            let expanded = this.expandedText()
            this.lastEcho = expanded
            this.addToHistory(expanded)
            this.onSubmit(expanded)
            this.text_ = ""
            this.cursorPos = 0
            this.viewportTop = 0
            return true
        }
        if (key.isBackspace) {
            if (this.searchMode) {
                // 搜索模式：删 query 尾字符，重新过滤
                if (this.searchQuery.size > 0) {
                    var cut = this.searchQuery.size - 1
                    while (cut >= 0) {
                        try {
                            this.searchQuery = this.searchQuery[0..cut]
                            break
                        } catch (e: Exception) {
                            cut -= 1
                        }
                    }
                    this.historyIndex = -1
                    this.jumpToFirstMatch()
                }
                this.onChange(this.text_)
                return true
            }
            // 折叠 marker 是原子 token：光标在末尾时退格整体删除（对齐 omp/atomcode）；
            // 其余按光标位置删除前一个字符（UTF-8 字节安全）
            let (isMarker, _) = this.parsePasteMarker(this.text_)
            if (isMarker && this.cursorPos == this.text_.size) {
                this.text_ = ""
                this.cursorPos = 0
            } else {
                this.backspaceAtCursor()
            }
            this.historyIndex = -1  // 编辑内容：退出历史浏览
            this.onChange(this.text_)
            return true
        }
        // 粘贴事件：在光标位置追加（bracketed paste 含换行也不触发 Enter 提交）。
        // v1.3.20：真实换行保留并归一化 CRLF→LF；≥5 行或 ≥400 字符折叠为
        // [Paste #N] 原子 marker（对齐 atomcode PASTE_FOLD_LINES/CHARS），
        // 未达阈值原文走软换行多行显示；光标置尾。
        if (key.isPaste) {
            if (key.text.size > 0) {
                this.addPasteLine(key.text)
                this.historyIndex = -1
                this.onChange(this.text_)
            }
            return true
        }
        // 可打印字符（含中文等多字节 UTF-8；排除控制键）
        if (key.text.size > 0 && !key.isEsc && !key.isEnter && !key.isBackspace) {
            // 编辑内容：退出历史浏览（draft 失效）
            this.historyIndex = -1
            if (this.searchMode) {
                this.searchQuery += key.text  // 搜索：输入进 query，实时跳转匹配
                this.jumpToFirstMatch()
            } else {
                // 在光标位置插入字符
                this.insertAtCursor(key.text)
            }
            this.onChange(this.text_)
            return true
        }
        return false
    }

    /**
     * 历史搜索模式切换（Ctrl+R）：进入后提示符变 🔍，输入子串实时过滤历史
     */
    private func toggleSearch(): Unit {
        this.searchMode = !this.searchMode
        this.rebuildPrompt()
        if (this.searchMode) {
            this.searchQuery = ""
            this.historyIndex = -1
            this.historyDraft = ""
            this.jumpToFirstMatch()  // 显示最近一条（若历史非空）
        } else {
            this.searchQuery = ""
            this.text_ = ""  // 退出搜索：清空（与进入时对称）
            this.historyIndex = -1
            this.historyDraft = ""
        }
        this.onChange(this.text_)
    }

    /**
     * 搜索模式：跳到包含当前子串的最近一条匹配（空子串=最近一条）
     */
    private func jumpToFirstMatch(): Unit {
        if (!this.searchMode) {
            return
        }
        let list = this.filteredHistory()
        if (list.size == 0) {
            this.text_ = this.searchQuery  // 无匹配：显示 query
            this.cursorPos = Int64(this.text_.size)
            this.historyIndex = -1
            return
        }
        this.text_ = list[list.size - 1]  // 最近一条匹配
        this.cursorPos = Int64(this.text_.size)
        this.historyIndex = 0
    }

    /**
     * ↑：上一条历史（首次保存当前输入到 draft；继续↑ 更旧）。
     * 当前输入以 / 开头 → 只翻 / 命令历史（对齐通用 CLI 的按前缀过滤）
     */
    private func historyUp(): Unit {
        let list = this.filteredHistory()
        if (list.size == 0) {
            return
        }
        if (this.historyIndex == -1) {
            this.historyDraft = this.text_  // 保存当前输入，↓ 回底部恢复
            this.historyIndex = 0
        } else if (this.historyIndex < Int64(list.size) - 1) {
            this.historyIndex += 1
        } else {
            return  // 已到最旧
        }
        this.text_ = list[list.size - 1 - this.historyIndex]
        this.cursorPos = Int64(this.text_.size)  // 历史浏览：光标置尾
        this.onChange(this.text_)
    }

    /**
     * ↓：下一条历史；回到底部恢复 draft（当前输入）
     */
    private func historyDown(): Unit {
        let list = this.filteredHistory()
        if (this.historyIndex == -1) {
            return  // 已在底部
        }
        if (this.historyIndex > 0) {
            this.historyIndex -= 1
            this.text_ = list[list.size - 1 - this.historyIndex]
            this.cursorPos = Int64(this.text_.size)  // 历史浏览：光标置尾
        } else {
            this.historyIndex = -1
            this.text_ = this.historyDraft
            this.cursorPos = Int64(this.text_.size)  // 恢复 draft：光标置尾
        }
        this.onChange(this.text_)
    }

    /**
     * 历史过滤：搜索模式 → 包含子串匹配（reverse-search）；
     * 否则当前输入以 / 开头 → 只返回 / 命令历史（对齐 shell 前缀匹配）
     */
    private func filteredHistory(): ArrayList<String> {
        if (this.searchMode) {
            var list = ArrayList<String>()
            for (h in this.history) {
                if (this.searchQuery.size == 0 || h.contains(this.searchQuery)) {
                    list.add(h)
                }
            }
            return list
        }
        let prefix = if (this.historyDraft.size > 0) { this.historyDraft } else { this.text_ }
        if (!prefix.startsWith("/")) {
            return this.history
        }
        var list = ArrayList<String>()
        for (h in this.history) {
            if (h.startsWith("/")) {
                list.add(h)
            }
        }
        return list
    }
}
