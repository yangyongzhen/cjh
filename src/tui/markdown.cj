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
    private var pendingStar: Bool = false      // 等下一个 * 确认 **
    private var tickCount: Int64 = 0           // 未决反引号计数（跨帧累积，遇非反引号 flush）

    // ===== 表格状态 =====
    private var atLineStart: Bool = true       // 当前是否行首（\n 后）
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
                // 普通行的 \n：flush 未决反引号（非反引号字符语义）；表格行内不 flush
                if (!this.tableMode) {
                    this.flushTicks(sb)
                }
                // 行结束：处理表格行 or flush 普通行
                this.flushLine(sb)
                sb.append("\n")
                this.atLineStart = true
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
     * 处理一个表格行：
     *   - 分隔行（| --- |）→ 确定列数 + 渲染表头 + 分隔线
     *   - 表头行（首个非分隔行）→ 缓冲
     *   - 数据行（tableOn）→ 按列宽对齐渲染
     *   - 空行/非表格行 → 结束表格
     */
    private func processTableLine(sb: StringBuilder): Unit {
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
                cellText = Ansi.bold() + cell + Ansi.reset()
            }
            sb.append(cellText)
            for (j in 0..pad) {
                sb.append(" ")
            }
            sb.append(Ansi.fg(Ansi.THEME_MUTED) + " │ " + Ansi.reset())
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
            this.renderTableHeader(sb)
            for (d in this.tableData) {
                this.renderTableRow(sb, d)
            }
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
        if (s == "*") {
            if (this.pendingStar) {
                // ** 成对 → 切换粗体
                this.boldOn = !this.boldOn
                sb.append(if (this.boldOn) { Ansi.bold() } else { Ansi.reset() })
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
        sb.append(s)
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
            sb.append(if (this.codeBlockOn) { Ansi.fg(Ansi.THEME_MUTED) } else { Ansi.reset() })
        } else {
            this.inlineCodeOn = !this.inlineCodeOn
            sb.append(if (this.inlineCodeOn) { Ansi.fg(Ansi.THEME_ACCENT) } else { Ansi.reset() })
        }
        this.tickCount = 0
    }

    /**
     * 流式结束时调用：flush 未决反引号 + 关闭所有未闭合状态，返回收尾 ANSI
     */
    public func finish(): String {
        var sb = StringBuilder()
        this.flushLine(sb)   // 最后一行可能未以 \n 结束（表格行）
        if (this.tableMode || this.tableOn) {
            this.endTable(sb)
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
        return sb.toString()
    }
}
