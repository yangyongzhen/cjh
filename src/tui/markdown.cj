package cjh.tui

import cjterm.*
import std.collection.*

/**
 * Markdown 增量渲染器：把 LLM 回复中的 markdown 语法转为 ANSI 高亮
 *
 * 支持（流式安全，增量 token 逐个处理）：
 * - **粗体** → 加粗
 * - `行内代码` → 青色
 * - ``` 代码块 → 灰底/斜体
 * - | 表格 → 边框 + 列对齐（表头定列宽，数据行对齐，CJK 宽度感知）
 * - 保持其余文本原样
 *
 * 用法：对 onDelta 的每个增量片段调用 process()，返回渲染后的 ANSI 字符串。
 *
 * 表格流式策略：行首 `|` 进入表格行缓冲，遇 `\n` 处理行——
 *   - 分隔行（| --- |）→ 确定列数，渲染表头 + 分隔线
 *   - 数据行 → 按表头列宽对齐渲染
 *   - 非表格行 → 结束表格（缓冲 flush 为普通文本）
 *
 * 反引号状态机（v2，修复三连代码块失效）：
 * 连续反引号先累积计数（跨帧保留），遇到非反引号字符时统一 flush：
 *   count >= 3 → 代码块开/关切换
 *   count 1-2  → 行内代码开/关切换
 * 旧实现逐字符处理，第 2 个反引号就开代码块、第 3 个立即关闭，
 * ``` 代码块渲染完全失效且 inlineCodeOn 状态残留。
 */
public class MarkdownRender {
    private var boldOn: Bool = false
    private var inlineCodeOn: Bool = false
    private var codeBlockOn: Bool = false
    // 素白前景是否已开启（连续普通文本合并为单次 fg，避免逐 rune ANSI 膨胀）
    private var textOn: Bool = false
    // ===== 代码块语法高亮状态（对齐 OMP：有语言标注才高亮，防误判）=====
    private var codeBlockLang: String = ""     // 代码块语言（```python → python）
    private var langBuf: StringBuilder = StringBuilder()  // 语言累积（开块后到 \n）
    private var langDone: Bool = false         // 语言是否已确定（\n 后）
    // 词法状态机：normal / lineComment / blockComment / string
    private var hlState: String = "normal"
    private var hlQuote: String = ""           // 字符串引号
    private var hlWord: StringBuilder = StringBuilder()  // 标识符累积
    private var hlWordOn: Bool = false
    private var hlNum: StringBuilder = StringBuilder()   // 数字累积
    private var hlNumOn: Bool = false
    private var pendingStar: Bool = false      // 等下一个 * 确认 **
    private var tickCount: Int64 = 0           // 未决反引号计数（跨帧累积，遇非反引号 flush）

    // ===== 表格状态 =====
    private var atLineStart: Bool = true       // 当前是否行首（\n 后）
    // ATX 标题状态：行首 # 进入缓冲，\n 时判断是否为标题（# 文本）再渲染
    private var headingMode: Bool = false      // 行首 # 缓冲中
    private var headingLine: String = ""       // 标题行缓冲
    private var tableMode: Bool = false        // 检测到行首 | 进入表格行缓冲
    private var tableOn: Bool = false          // 确认是表格（见过分隔行），数据行渲染中
    private var tableLine: StringBuilder = StringBuilder()  // 当前表格行缓冲
    private var tableHeader: ArrayList<String> = ArrayList<String>()  // 表头单元格
    private var tableCols: Int64 = 0           // 列数（分隔行确定）
    private var tableWidths: ArrayList<Int64> = ArrayList<Int64>()    // 各列宽
    private var tableData: ArrayList<String> = ArrayList<String>()    // 数据行缓冲（表格结束统一渲染，列宽=全部行最大值）

    public init() {}

    /**
     * 处理一个增量片段，返回带 ANSI 高亮的字符串
     *
     * 注意：必须用 toRuneArray() 迭代码点而非 for-in 迭代 String——
     * 仓颉 for-in 迭代 String 得 Byte，Rune(byte) 重建会把中文拆成
     * Latin-1 形态乱码（"你好"→"ä½\xa0å¥½"）
     */
    public func process(delta: String): String {
        var sb = StringBuilder()
        for (r in delta.toRuneArray()) {
            let s = r.toString()
            if (s == "\n") {
                // 标题行结束：判断是否为 ATX 标题并渲染（或原样输出）
                if (this.headingMode) {
                    this.flushHeading(sb)
                    this.headingMode = false
                    this.headingLine = ""
                }
                // 普通行的 \n：flush 未决反引号（非反引号字符语义）；表格行内不 flush
                if (!this.tableMode) {
                    this.flushTicks(sb)
                }
                // 行结束：处理表格行 or flush 普通行。
                // 表格行缓冲期间的 \n 不输出——表格在 endTable 统一渲染，
                // 缓冲期若输出 \n 会在表格上方堆叠成一片空行（旧 bug）
                let wasTableLine = this.tableMode
                this.flushLine(sb)
                if (!wasTableLine) {
                    sb.append("\n")
                }
                this.atLineStart = true
                // 代码块：换行结束行注释/刷新词；首行 \n 后语言确定
                if (this.codeBlockOn) {
                    this.hlNewline(sb)
                }
                continue
            }
            if (this.tableMode) {
                // 表格行累积（等 \n 统一处理）
                this.tableLine.append(s)
                continue
            }
            // 表格缓冲中遇到非表格内容（非行首 |、非 \n）→ 表格结束，统一渲染
            if (this.tableOn && !(this.atLineStart && s == "|")) {
                this.endTable(sb)
            }
            // 行首 | → 可能表格行
            if (this.atLineStart && s == "|") {
                this.tableMode = true
                this.tableLine.append(s)
                this.atLineStart = false
                continue
            }
            // 代码块内：语法高亮状态机（行首 # 是注释，不触发标题）
            if (this.codeBlockOn) {
                this.atLineStart = false
                this.hlRune(s, sb)
                continue
            }
            // 行首 # → ATX 标题候选（缓冲整行，\n 时判断：`# 文本` 才是标题）
            if (this.atLineStart && s == "#") {
                this.headingMode = true
                this.headingLine = s
                this.atLineStart = false
                continue
            }
            if (this.headingMode) {
                this.headingLine += s
                continue
            }
            this.atLineStart = false
            // 普通行：原有 rune 处理（反引号/粗体）
            this.processInline(s, sb)
        }
        return sb.toString()
    }

    /**
     * 行结束处理：表格行渲染 or 普通行输出
     */
    private func flushLine(sb: StringBuilder): Unit {
        if (this.tableMode) {
            this.processTableLine(sb)
            this.tableMode = false
            this.tableLine = StringBuilder()
            return
        }
        // 普通行：无额外处理（rune 已即时输出）
    }

    /**
     * ATX 标题渲染（对齐 omp）：行首 # 1-6 级 + 空格 → 主题色 + 加粗，
     * H1 额外下划线，H3+ 保留 # 前缀；非标题（#tag、# 列表）原样输出。
     * 流式安全：整行缓冲后统一判断（跨帧 # 分片不误判）。
     */
    private func flushHeading(sb: StringBuilder): Unit {
        let line = this.headingLine
        var level: Int64 = 0
        var i: Int64 = 0
        let n = line.size
        while (i < n && line[i] == 35u8) {  // '#'
            level += 1
            i += 1
        }
        // ATX 要求：#{1,6} 后跟空格或制表符
        if (level >= 1 && level <= 6 && i < n && (line[i] == 32u8 || line[i] == 9u8)) {
            var text = line[i..n].trimAscii()
            // 去尾部闭合 #（"## 标题 ##" → "## 标题"；尾部 # 前需空格）
            var t = text.size
            while (t > 0 && text[t - 1] == 35u8) {
                t -= 1
            }
            if (t < text.size) {
                text = text[0..t].trimAscii()
            }
            if (text.size > 0) {
                // 主题色 + 加粗；H1 额外下划线；H3+ 保留 # 前缀（对齐 omp heading）
                var prefix = ""
                if (level >= 3) {
                    for (j in 0..level) {
                        prefix += "#"
                    }
                    prefix += " "
                }
                var style = Ansi.fg(Ansi.THEME_ACCENT) + Ansi.bold()
                if (level == 1) {
                    style += Ansi.underline()
                }
                sb.append(style + prefix + text + Ansi.reset())
                return
            }
        }
        // 非标题：原样输出（如 #tag、# 无序列表、#### 分隔线）
        sb.append(line)
    }

    /**
     * 处理一个表格行：
     *   - 分隔行（| --- |）→ 确定列数 + 渲染表头 + 分隔线
     *   - 表头行（首个非分隔行）→ 缓冲
     *   - 数据行（tableOn）→ 按列宽对齐渲染
     *   - 空行/非表格行 → 结束表格
     */
    private func processTableLine(sb: StringBuilder): Unit {
        // 表格行独立渲染（单元格/边框各自 fg+reset），清素白状态避免残留
        this.textOn = false
        let line = this.tableLine.toString()
        let trimmed = line.trimAscii()
        // 空行 → 结束表格
        if (trimmed.size == 0) {
            if (this.tableOn) {
                this.endTable(sb)
            }
            return
        }
        // 分隔行：| --- | --- |（含 --- 且无其他内容）
        if (this.isSeparatorRow(trimmed)) {
            if (this.tableHeader.size > 0) {
                // 表头已缓冲：确认表格（列数由表头决定），统一渲染推迟到表格结束
                this.tableCols = Int64(this.tableHeader.size)
                this.tableOn = true
            }
            return
        }
        // 数据行（tableOn）：缓冲，表格结束统一渲染（列宽=全部行最大值，完美对齐）
        if (this.tableOn) {
            this.tableData.add(trimmed)
            return
        }
        // 首个非分隔行：缓冲为表头（还没看到分隔行）
        if (this.tableHeader.size == 0) {
            let cells = this.splitCells(trimmed)
            for (c in cells) {
                this.tableHeader.add(c)
            }
            return
        }
        // 已缓冲表头但没分隔行（可能不是表格）：当作普通文本输出
        this.endTable(sb)
        sb.append(line)
    }

    /**
     * 分隔行判断：| --- | --- |（单元格均为 --- 或 -: 对齐标记）
     */
    private func isSeparatorRow(trimmed: String): Bool {
        let cells = this.splitCells(trimmed)
        if (cells.size == 0) {
            return false
        }
        var allSep: Bool = true
        for (c in cells) {
            let t = c.trimAscii()
            if (t.size == 0) {
                continue
            }
            var isDash: Bool = true
            for (r in t.toRuneArray()) {
                if (r.toString() != "-" && r.toString() != ":" && r.toString() != " ") {
                    isDash = false
                    break
                }
            }
            if (!isDash) {
                allSep = false
                break
            }
        }
        return allSep
    }

    /**
     * 解析 | 分隔单元格（去首尾管道符）
     */
    private func splitCells(line: String): ArrayList<String> {
        var cells = ArrayList<String>()
        // 去首尾 |
        var body = line
        if (body.startsWith("|")) {
            body = body[1..body.size]
        }
        if (body.endsWith("|")) {
            body = body[0..body.size - 1]
        }
        let parts = body.split("|", -1)
        for (p in parts) {
            cells.add(p.trimAscii())
        }
        return cells
    }

    /**
     * 计算各列宽（CJK 宽度感知）
     */
    private func calcWidths(rows: ArrayList<String>): ArrayList<Int64> {
        var widths = ArrayList<Int64>()
        for (i in 0..this.tableCols) {
            var w: Int64 = 0
            for (row in rows) {
                let cells = this.splitCells(row)
                if (i < cells.size) {
                    let cw = TuiCanvas.displayWidth(cells[i])
                    if (cw > w) {
                        w = cw
                    }
                }
            }
            widths.add(w)
        }
        return widths
    }

    /**
     * 渲染表头（边框 + 对齐 + 粗体）+ 分隔线
     */
    private func renderTableHeader(sb: StringBuilder): Unit {
        sb.append(this.renderBorderRow(this.tableHeader, true))
        // 分隔线：├───┼───┤
        sb.append("\n")
        var sep = "├"
        for (i in 0..this.tableCols) {
            let w = this.tableWidths[i]
            for (j in 0..w + 2) {
                sep += "─"
            }
            if (i < this.tableCols - 1) {
                sep += "┼"
            }
        }
        sep += "┤"
        sb.append(Ansi.fg(Ansi.THEME_MUTED) + sep + Ansi.reset())
    }

    /**
     * 表格顶边框：┌───┬───┐（完整表格观感，对齐 omp 表格边框）
     */
    private func renderTableTopBorder(sb: StringBuilder): Unit {
        sb.append(this.renderTableHLine("┌", "┬", "┐"))
    }

    /**
     * 表格底边框：└───┴───┘
     */
    private func renderTableBottomBorder(sb: StringBuilder): Unit {
        sb.append(this.renderTableHLine("└", "┴", "┘"))
    }

    /**
     * 表格横向边框线（顶/底）
     */
    private func renderTableHLine(left: String, mid: String, right: String): String {
        var line = left
        for (i in 0..this.tableCols) {
            let w = this.tableWidths[i]
            for (j in 0..w + 2) {
                line += "─"
            }
            if (i < this.tableCols - 1) {
                line += mid
            }
        }
        line += right
        return Ansi.fg(Ansi.THEME_MUTED) + line + Ansi.reset()
    }

    /**
     * 渲染数据行（按表头列宽对齐）
     */
    private func renderTableRow(sb: StringBuilder, line: String): Unit {
        let cells = this.splitCells(line)
        sb.append("\n")
        sb.append(this.renderBorderRow(cells, false))
    }

    /**
     * 渲染一行单元格：│ 单元格（补空格对齐）│
     */
    private func renderBorderRow(cells: ArrayList<String>, isHeader: Bool): String {
        var sb = StringBuilder()
        sb.append(Ansi.fg(Ansi.THEME_MUTED) + "│ " + Ansi.reset())
        for (i in 0..this.tableCols) {
            var cell = ""
            if (i < cells.size) {
                cell = cells[i]
            }
            let cw = TuiCanvas.displayWidth(cell)
            let pad = if (this.tableWidths[i] - cw > 0) {
                this.tableWidths[i] - cw
            } else { 0 }
            var cellText = cell
            if (isHeader) {
                cellText = Ansi.bold() + Ansi.fg(Ansi.COLOR_TEXT) + cell + Ansi.reset()
            } else {
                cellText = Ansi.fg(Ansi.COLOR_TEXT) + cell + Ansi.reset()
            }
            sb.append(cellText)
            for (j in 0..pad) {
                sb.append(" ")
            }
            // 列间 " │ "；最后一列行尾 " │"（去尾空格，与分隔线宽度精确对齐）
            if (i < this.tableCols - 1) {
                sb.append(Ansi.fg(Ansi.THEME_MUTED) + " │ " + Ansi.reset())
            } else {
                sb.append(Ansi.fg(Ansi.THEME_MUTED) + " │" + Ansi.reset())
            }
        }
        return sb.toString()
    }

    /**
     * 结束表格：统一渲染全部行（列宽 = 表头 + 所有数据行最大值，完美对齐），
     * 然后重置表格状态
     */
    private func endTable(sb: StringBuilder): Unit {
        if (this.tableOn && this.tableHeader.size > 0) {
            // 列宽：表头 + 全部数据行的最大宽度
            var allRows = ArrayList<String>()
            for (h in this.tableHeader) {
                allRows.add(h)
            }
            for (d in this.tableData) {
                allRows.add(d)
            }
            this.tableWidths = this.calcWidths(allRows)
            this.renderTableTopBorder(sb)
            sb.append("\n")
            this.renderTableHeader(sb)
            for (d in this.tableData) {
                this.renderTableRow(sb, d)
            }
            sb.append("\n")
            this.renderTableBottomBorder(sb)
            // 表格结束后另起一行：底边框后紧跟的内容（普通文本/代码块等）
            // 不再贴边（旧实现 └──┘代码结构清晰… 挤在一起）
            sb.append("\n")
        } else if (this.tableHeader.size > 0) {
            // 只有表头没有分隔行/数据：当作普通文本输出（可能不是表格）
            for (h in this.tableHeader) {
                sb.append("| " + h + " |\n")
            }
        }
        this.tableOn = false
        this.tableMode = false
        this.tableHeader = ArrayList<String>()
        this.tableWidths = ArrayList<Int64>()
        this.tableCols = 0
        this.tableLine = StringBuilder()
        this.tableData = ArrayList<String>()
    }

    /**
     * 普通行内处理：反引号/粗体（原有逻辑）
     */
    private func processInline(s: String, sb: StringBuilder): Unit {
        if (s == "`") {
            // 累积反引号，不立即输出（需等序列结束才知道是行内还是代码块）
            this.tickCount += 1
            return
        }
        // 遇到非反引号：先 flush 累积的反引号
        this.flushTicks(sb)
        // 开块后的第一个字符：重定向到代码块高亮（语言标注进 langBuf）
        if (this.codeBlockOn) {
            this.hlRune(s, sb)
            return
        }
        if (s == "*") {
            if (this.pendingStar) {
                // ** 成对 → 切换粗体（素白加粗，避免纯白粗体刺眼）
                this.boldOn = !this.boldOn
                if (this.boldOn) {
                    sb.append(Ansi.bold() + Ansi.fg(Ansi.COLOR_TEXT))
                    this.textOn = true
                } else {
                    sb.append(Ansi.reset())
                    this.textOn = false
                }
                this.pendingStar = false
            } else {
                this.pendingStar = true
            }
            return
        }
        if (this.pendingStar) {
            // 单 * 是普通字符
            sb.append("*")
            this.pendingStar = false
        }
        // 普通文本：素白（对齐 omp 正文 #e5e5e7，避免终端默认纯白刺眼）
        // 粗体/行内代码/代码块内已有各自的颜色语义，不重复着色；
        // 连续普通文本只开一次 fg（textOn 状态），reset 在各样式切换处统一处理
        if (this.boldOn || this.inlineCodeOn || this.codeBlockOn) {
            sb.append(s)
        } else {
            if (!this.textOn) {
                sb.append(Ansi.fg(Ansi.COLOR_TEXT))
                this.textOn = true
            }
            sb.append(s)
        }
    }

    /**
     * 处理累积的反引号：>=3 切代码块，1-2 切行内代码
     */
    private func flushTicks(sb: StringBuilder): Unit {
        if (this.tickCount == 0) {
            return
        }
        if (this.tickCount >= 3) {
            this.codeBlockOn = !this.codeBlockOn
            if (this.codeBlockOn) {
                sb.append(Ansi.fg(Ansi.THEME_MUTED))
            } else {
                sb.append(Ansi.reset())
                this.textOn = false
            }
            if (this.codeBlockOn) {
                // 开块：重置高亮状态，准备提取语言（``` 后到 \n 为语言标注）
                this.hlReset()
                this.langBuf = StringBuilder()
                this.langDone = false
            } else {
                // 关块：flush 未决词
                var tmp = StringBuilder()
                this.hlFlushWord(tmp)
                sb.append(tmp.toString())
            }
        } else {
            this.inlineCodeOn = !this.inlineCodeOn
            if (this.inlineCodeOn) {
                sb.append(Ansi.fg(Ansi.THEME_ACCENT))
            } else {
                sb.append(Ansi.reset())
                this.textOn = false
            }
        }
        this.tickCount = 0
    }


    // ==================== 代码块语法高亮状态机 ====================
    // 对齐 OMP：有语言标注才高亮（无标注保持灰底，防止把散文误判成代码着色）
    // 通用词法：字符串/注释/数字/跨语言关键字，语言映射补充关键字与注释风格

    /**
     * 重置高亮状态（代码块开/关时）
     */
    private func hlReset(): Unit {
        this.hlState = "normal"
        this.hlQuote = ""
        this.hlWord = StringBuilder()
        this.hlWordOn = false
        this.hlNum = StringBuilder()
        this.hlNumOn = false
        this.codeBlockLang = ""
        this.langDone = false
        this.hlPendingSlash = false
        this.hlInBlockStar = false
    }

    /**
     * 代码块内换行处理：行注释结束、词 flush、语言确定
     */
    private func hlNewline(sb: StringBuilder): Unit {
        // 语言提取：开块后首行（```lang）的内容就是语言标注
        if (!this.langDone) {
            this.codeBlockLang = this.langBuf.toString().trimAscii()
            this.langDone = true
        }
        // 行注释：\n 结束
        if (this.hlState == "lineComment") {
            this.hlState = "normal"
        }
        // flush 未决词
        this.hlFlushWord(sb)
        // flush 未决数字
        if (this.hlNumOn) {
            let numStr = this.hlNum.toString()
            this.hlNum = StringBuilder()
            this.hlNumOn = false
            sb.append(Ansi.fg(Ansi.THEME_ACCENT) + numStr + Ansi.reset())
        }
        // 字符串跨行：不关闭（多行字符串少见，保持着色直到闭合）
    }

    /**
     * 代码块内 rune 处理（语法高亮状态机）
     */
    private func hlRune(s: String, sb: StringBuilder): Unit {
        // 反引号：累积（代码块结束标记 ``` 检测；1-2 反引号在代码块内保持累积）
        if (s == "`") {
            this.tickCount += 1
            return
        }
        // 非反引号：flush 累积反引号（>=3 关块）
        if (this.tickCount > 0) {
            this.flushTicks(sb)
            if (!this.codeBlockOn) {
                // 块已关闭：当前字符按普通行处理
                this.processInline(s, sb)
                return
            }
        }
        // 语言提取阶段（开块首行）：``` 后的字符累积为语言标注
        if (!this.langDone) {
            this.langBuf.append(s)
            return
        }
        // 无语言标注：不逐词高亮（对齐 OMP 防误判），保持灰底
        if (this.codeBlockLang.size == 0) {
            sb.append(s)
            return
        }
        // 块注释：检测 */ 结束
        if (this.hlState == "blockComment") {
            sb.append(Ansi.fg(Ansi.THEME_INFO) + s + Ansi.reset())
            if (this.hlInBlockStar) {
                if (s == "/") {
                    this.hlState = "normal"
                    this.hlInBlockStar = false
                } else if (s != "*") {
                    this.hlInBlockStar = false
                }
                return
            }
            if (s == "*") {
                this.hlInBlockStar = true
            }
            return
        }
        // 词法状态机
        match (this.hlState) {
            case "lineComment" =>
                sb.append(Ansi.fg(Ansi.THEME_INFO) + s + Ansi.reset())
            case "string" =>
                sb.append(Ansi.fg(Ansi.THEME_OK) + s + Ansi.reset())
                if (s == this.hlQuote) {
                    this.hlState = "normal"
                }
            case _ =>
                let v = UInt32(s.toRuneArray()[0])
                // 标识符字符（字母/_）：累积成词（flushWord 在非字母时触发）
                if ((v >= 97 && v <= 122) || (v >= 65 && v <= 90) || v == 95) {
                    // 数字后直接跟字母：先 flush 数字（如 42abc）
                    if (this.hlNumOn) {
                        let numStr = this.hlNum.toString()
                        this.hlNum = StringBuilder()
                        this.hlNumOn = false
                        sb.append(Ansi.fg(Ansi.THEME_ACCENT) + numStr + Ansi.reset())
                    }
                    this.hlWord.append(s)
                    this.hlWordOn = true
                    return
                }
                // 非标识符：先 flush 未决词
                if (this.hlWordOn) {
                    this.hlFlushWord(sb)
                    this.hlWordOn = false
                }
                // 数字：累积（非数字时 flush 整段青色）
                if (v >= 48 && v <= 57) {
                    this.hlNum.append(s)
                    this.hlNumOn = true
                    return
                }
                if (this.hlNumOn) {
                    let numStr = this.hlNum.toString()
                    this.hlNum = StringBuilder()
                    this.hlNumOn = false
                    sb.append(Ansi.fg(Ansi.THEME_ACCENT) + numStr + Ansi.reset())
                }
                // 注释开始检测：先查 pendingSlash（// 或 /* 的第二个字符）
                if (this.hlPendingSlash) {
                    this.hlPendingSlash = false
                    if (s == "/") {
                        this.hlState = "lineComment"
                        sb.append(Ansi.fg(Ansi.THEME_INFO) + "//" + Ansi.reset())
                        return
                    }
                    if (s == "*") {
                        this.hlState = "blockComment"
                        sb.append(Ansi.fg(Ansi.THEME_INFO) + "/*" + Ansi.reset())
                        return
                    }
                    // 不是注释：输出 '/' + 当前字符
                    sb.append("/" + s)
                    return
                }
                if (s == "/") {
                    // // 或 /*（需看下一个字符——用标志 pendingSlash）
                    this.hlPendingSlash = true
                    return
                }
                // 字符串开始
                if (s == "\"" || s == "'" || s == "`") {
                    this.hlState = "string"
                    this.hlQuote = s
                    sb.append(Ansi.fg(Ansi.THEME_OK) + s + Ansi.reset())
                    return
                }
                // # 注释（python/sh/ruby 等语言）
                if (s == "#" && this.hashCommentEnabled()) {
                    this.hlState = "lineComment"
                    sb.append(Ansi.fg(Ansi.THEME_INFO) + s + Ansi.reset())
                    return
                }
                sb.append(s)
        }
    }

    /**
     * flush 未决标识符词：匹配关键字则着色，否则灰底
     */
    private func hlFlushWord(sb: StringBuilder): Unit {
        if (!this.hlWordOn && this.hlWord.toString().size == 0) {
            return
        }
        let word = this.hlWord.toString()
        this.hlWord = StringBuilder()
        this.hlWordOn = false
        if (this.isKeyword(word)) {
            sb.append(Ansi.fg(Ansi.THEME_PURPLE) + word + Ansi.reset())
        } else {
            sb.append(word)
        }
    }

    /**
     * 关键字判断：通用集 + 当前语言补充集
     */
    private func isKeyword(word: String): Bool {
        if (MarkdownRender.GENERIC_KEYWORDS.contains(word)) {
            return true
        }
        let extra = MarkdownRender.langKeywords(this.codeBlockLang)
        if (extra.size > 0 && extra.contains(word)) {
            return true
        }
        return false
    }

    /**
     * 跨语言通用关键字
     */
    private static let GENERIC_KEYWORDS: Array<String> = [
        "if", "else", "elif", "for", "while", "do", "return", "break", "continue",
        "function", "func", "fn", "def", "class", "struct", "enum", "interface",
        "import", "from", "export", "public", "private", "protected", "static",
        "let", "var", "const", "true", "false", "null", "nil", "None", "new",
        "this", "self", "super", "try", "catch", "finally", "throw", "throws",
        "match", "case", "switch", "default", "in", "of", "as", "is", "and", "or",
        "not", "lambda", "async", "await", "yield", "with", "pass",
    ]

    /**
     * 批量添加关键字（仓颉 ArrayList 无 addAll）
     */
    private static func addKeywords(list: ArrayList<String>, words: Array<String>): Unit {
        for (w in words) {
            list.add(w)
        }
    }

    /**
     * 语言补充关键字（常见语言）
     */
    private static func langKeywords(lang: String): ArrayList<String> {
        var list = ArrayList<String>()
        match (lang) {
            case "python" | "py" =>
                // 关键字 + 内置函数（print/len/range 等此前缺失——"代码不能高亮"主因）
                MarkdownRender.addKeywords(list, ["def", "None", "True", "False", "self", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "break", "continue", "try", "except", "finally", "with", "as", "lambda", "yield", "global", "nonlocal", "pass", "raise", "assert", "del", "in", "is", "not", "and", "or", "print", "input", "len", "range", "type", "str", "int", "float", "bool", "list", "dict", "set", "tuple", "open", "read", "write", "append", "super", "isinstance", "enumerate", "zip", "map", "filter", "sorted", "sum", "min", "max", "abs", "repr", "format", "join", "split", "strip", "keys", "values", "items", "get", "update", "pop", "remove", "extend", "insert", "copy", "count", "index", "startswith", "endswith", "replace", "find", "upper", "lower"])
            case "javascript" | "js" | "jsx" | "ts" | "typescript" | "tsx" =>
                MarkdownRender.addKeywords(list, ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "new", "this", "async", "await", "export", "import", "from", "default", "typeof", "instanceof", "null", "undefined", "true", "false", "try", "catch", "throw", "switch", "case", "break", "continue", "interface", "type", "enum", "extends", "implements"])
            case "cangjie" | "cj" =>
                MarkdownRender.addKeywords(list, ["func", "let", "var", "match", "case", "if", "else", "for", "while", "return", "class", "struct", "enum", "interface", "import", "public", "private", "protected", "static", "init", "this", "true", "false", "None", "Some", "Unit", "Bool", "Int64", "String", "Array", "try", "catch", "finally", "throw", "in", "is", "as", "spawn", "lambda", "open", "override", "abstract", "const", "macro"])
            case "rust" | "rs" =>
                MarkdownRender.addKeywords(list, ["fn", "let", "mut", "impl", "trait", "struct", "enum", "match", "if", "else", "for", "while", "loop", "return", "pub", "use", "mod", "crate", "self", "Self", "true", "false", "Option", "Result", "Some", "None", "Ok", "Err", "async", "await", "move", "ref", "dyn", "where", "unsafe"])
            case "go" | "golang" =>
                MarkdownRender.addKeywords(list, ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "return", "go", "defer", "select", "switch", "case", "default", "break", "continue", "fallthrough", "true", "false", "nil", "make", "new", "len", "cap", "append"])
            case "c" | "h" | "cpp" | "c++" | "cxx" | "java" | "c#" | "csharp" =>
                MarkdownRender.addKeywords(list, ["int", "void", "char", "long", "short", "double", "float", "bool", "unsigned", "signed", "sizeof", "typedef", "struct", "union", "enum", "class", "public", "private", "protected", "static", "const", "volatile", "register", "extern", "inline", "virtual", "override", "template", "typename", "namespace", "using", "new", "delete", "malloc", "free", "printf", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "true", "false", "null", "NULL"])
            case "sql" =>
                MarkdownRender.addKeywords(list, ["SELECT", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "GROUP", "ORDER", "BY", "HAVING", "LIMIT", "OFFSET", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "AND", "OR", "NOT", "NULL", "IN", "BETWEEN", "LIKE", "COUNT", "SUM", "AVG", "MAX", "MIN", "AS", "ON", "VALUES", "SET", "PRIMARY", "KEY", "FOREIGN", "REFERENCES"])
            case "shell" | "sh" | "bash" | "zsh" =>
                MarkdownRender.addKeywords(list, ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "return", "exit", "export", "local", "readonly", "echo", "cd", "ls", "grep", "sed", "awk", "true", "false", "set", "unset", "shift", "source", "test"])
            case _ => ()
        }
        return list
    }

    /**
     * # 注释是否启用（python/sh/ruby 等）
     */
    private func hashCommentEnabled(): Bool {
        return this.codeBlockLang == "python" || this.codeBlockLang == "py" ||
            this.codeBlockLang == "shell" || this.codeBlockLang == "sh" ||
            this.codeBlockLang == "bash" || this.codeBlockLang == "zsh" ||
            this.codeBlockLang == "ruby" || this.codeBlockLang == "rb" ||
            this.codeBlockLang == "yaml" || this.codeBlockLang == "yml" ||
            this.codeBlockLang == "toml" || this.codeBlockLang == "perl"
    }

    // 注释状态辅助
    private var hlPendingSlash: Bool = false
    private var hlInBlockStar: Bool = false

    /**
     * 流式结束时调用：flush 未决反引号 + 关闭所有未闭合状态，返回收尾 ANSI
     */
    public func finish(): String {
        var sb = StringBuilder()
        this.flushLine(sb)   // 最后一行可能未以 \n 结束（表格行）
        if (this.tableMode || this.tableOn) {
            this.endTable(sb)
        }
        // 未以 \n 结尾的标题行（流式结尾无换行）
        if (this.headingMode) {
            this.flushHeading(sb)
            this.headingMode = false
            this.headingLine = ""
        }
        this.flushTicks(sb)
        if (this.codeBlockOn) {
            sb.append(Ansi.reset())
            this.codeBlockOn = false
        }
        if (this.inlineCodeOn) {
            sb.append(Ansi.reset())
            this.inlineCodeOn = false
        }
        if (this.boldOn) {
            sb.append(Ansi.reset())
            this.boldOn = false
        }
        if (this.textOn) {
            sb.append(Ansi.reset())
            this.textOn = false
        }
        return sb.toString()
    }
}
