package cjterm

import std.collection.*

/**
 * TUI 组件接口（参考 oh-my-pi pi-tui 的 Component 契约简化）
 *
 * pi-tui 契约：render(width) 返回行数组（每行 ≤ width，不变时返回同一引用
 * 以便 memoize）；handleInput 处理焦点输入；invalidate 清缓存。cjh 侧
 * 简化为显式行定位：组件渲染到 TuiCanvas（canvas 负责差分与截断），
 * handleKey 处理按键并返回是否消费（true = 已消费，不再向下分发）。
 */
public interface Component {
    /**
     * 渲染组件内容到 canvas。row 为组件起始行（0-based），height 为该组件
     * 可用的最大行数，width 为最大列宽（canvas 会按此截断）。
     * 返回组件实际占用的行数（供上层布局/滚动计算）。
     */
    func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64

    /**
     * 处理按键。返回 true 表示消费该按键（上层不再分发）。
     */
    func handleKey(key: KeyEvent): Bool

    /**
     * 组件获得焦点（默认空实现）
     */
    func onFocus(): Unit {}

    /**
     * 组件失去焦点（默认空实现）
     */
    func onBlur(): Unit {}
}

/**
 * 行级差分画布：本次渲染各行内容与上次对比，只输出变化行。
 *
 * 用法（每帧）：
 *   canvas.begin(rows, cols, sizeChanged)  // 开始新帧；尺寸变化清缓存强制全量
 *   canvas.setLine(row, text)              // 写一行（自动截断到列宽）
 *   canvas.setCursor(row, col)             // 设置硬件光标（1-based）
 *   let out = canvas.flush()               // 差分渲染指令 + 光标定位
 *
 * 从 TuiApp 的 prevLines 差分逻辑抽出，供任意组件组合复用。
 */
public class TuiCanvas {
    private var prevLines: ArrayList<String> = ArrayList<String>()
    private var lines: ArrayList<String> = ArrayList<String>()
    private var rows: Int64 = 0
    private var cols: Int64 = 0
    private var cursorRow: Int64 = 1
    private var cursorCol: Int64 = 1
    // 列偏移：内容区左侧预留列数（Box 内嵌子组件时设置，子组件 setLine/setCursor
    // 自动左移 offsetCol 列，避免覆盖左/右边框）
    private var offsetCol: Int64 = 0

    /**
     * 开始新帧。sizeChanged 为 true（首帧或终端尺寸变化）时清空缓存强制全量重绘。
     */
    public func begin(rows: Int64, cols: Int64, sizeChanged: Bool): Unit {
        this.rows = rows
        this.cols = cols
        this.lines = ArrayList<String>()
        for (i in 0..rows) {
            this.lines.add("")
        }
        if (sizeChanged) {
            this.prevLines = ArrayList<String>()
        }
        this.offsetCol = 0
    }

    /**
     * 设置当前列偏移（内容区左侧预留列数；0 = 无偏移）。容器组件（Box）在委托
     * 子组件渲染前设置，渲染完成后恢复 0。
     */
    public func setOffset(off: Int64): Unit {
        this.offsetCol = off
    }

    /**
     * 当前列偏移
     */
    public func getOffset(): Int64 {
        return this.offsetCol
    }

    public func getCols(): Int64 { return this.cols }
    public func getRows(): Int64 { return this.rows }

    /**
     * 设置某行内容（0-based；自动截断到列宽；越界忽略）
     */
    public func setLine(row: Int64, text: String): Unit {
        if (row < 0 || row >= this.rows) {
            return
        }
        var line = text
        if (this.offsetCol > 0) {
            line = this.fillSpaces(this.offsetCol) + line
        }
        this.lines[row] = this.truncate(line, this.cols)
    }

    /**
     * 设置硬件光标位置（1-based 行列，默认 (1,1)；自动叠加列偏移）
     */
    public func setCursor(row: Int64, col: Int64): Unit {
        this.cursorRow = row
        this.cursorCol = col + this.offsetCol
    }

    /**
     * 完成本帧：返回差分渲染指令（只重绘变化行），并定位光标。
     */
    public func flush(): String {
        var sb = StringBuilder()
        for (i in 0..this.rows) {
            let content = this.lines[i]
            if (this.prevLines.size <= i || this.prevLines[i] != content) {
                sb.append(Ansi.moveTo(i + 1, 1))
                sb.append(Ansi.clearLine())
                sb.append(content)
                // 扩容并写入缓存
                while (this.prevLines.size <= i) {
                    this.prevLines.add("")
                }
                this.prevLines[i] = content
            }
        }
        sb.append(Ansi.moveTo(this.cursorRow, this.cursorCol))
        return sb.toString()
    }

    /**
     * 按列宽截断行（ANSI 感知 + 显示宽度感知）：
     * - ANSI 转义序列不计入可见宽度、整体复制；
     * - 可见宽度按东亚宽字符（CJK/全角/谚文）=2 列、其余=1 列计算，
     *   与终端实际渲染对齐——否则含中文的行实际超宽，被终端折行，
     *   挤乱分隔线等宽布局。
     * 修复 1：旧实现按原始字节数截断，ANSI 序列（约 14 字节）吃掉预算，
     *         导致带色行（分隔线/Box 边框）比纯文本行短——长短不一。
     * 修复 2：可见字符必须用【字节切片】text[i..i+len] 复制，保留原始
     *         UTF-8 序列；禁止逐字节 Rune(byte).toString() 拼回——
     *         那会把多字节字符按 Latin-1 误解码（"对话"→"å¯¹"乱码）。
     */
    public func truncate(text: String, cols: Int64): String {
        let maxVisible = cols - 1
        var sb = StringBuilder()
        var visible: Int64 = 0
        var i: Int64 = 0
        let n = text.size
        while (i < n) {
            let b = text[i]
            if (b == 27u8) {
                // ANSI 转义序列：整体复制，不计可见宽度（全 ASCII，逐字节切片安全）
                sb.append(text[i..i + 1])
                i += 1
                // CSI 序列（ESC [ ... 终结字母 0x40..0x7E）：复制到终结符
                if (i < n && text[i] == 91u8 /* '[' */) {
                    sb.append(text[i..i + 1])   // 复制 '['
                    i += 1                       // 跳过 '['，进入参数/终结字母循环
                    while (i < n) {
                        let c = text[i]
                        sb.append(text[i..i + 1])
                        i += 1
                        if (Int32(c) >= 0x40 && Int32(c) <= 0x7E) {
                            break
                        }
                    }
                }
                continue
            }
            // 可见字符：按首字节判定完整字符字节数，整体切片复制（保留原始 UTF-8）
            let b0 = Int32(text[i])
            var len: Int64 = 1
            if (b0 >= 0xF0) {
                len = 4
            } else if (b0 >= 0xE0) {
                len = 3
            } else if (b0 >= 0xC0) {
                len = 2
            }
            if (i + len > n) {
                len = n - i
            }
            // 数据异常（半截 UTF-8）时递减到合法边界，与旧实现 try/catch 语义一致
            var ch: String = ""
            var appended: Bool = false
            while (len > 0) {
                try {
                    ch = text[i..i + len]
                    appended = true
                    break
                } catch (e: Exception) {
                    len -= 1
                }
            }
            if (!appended) {
                // 理论不可达：单字节必合法
                ch = text[i..i + 1]
            }
            // 显示宽度：东亚宽字符=2 列，其余=1 列；放不下则停止（不切半字符）
            let w = this.charWidth(ch)
            if (visible + w > maxVisible) {
                break
            }
            sb.append(ch)
            visible += w
            i += ch.size
        }
        return sb.toString()
    }

    /**
     * 字符显示宽度：东亚宽字符（CJK/全角/谚文等）=2 列，其余=1 列
     */
    private func charWidth(ch: String): Int64 {
        let runes = ch.toRuneArray()
        if (runes.size == 0) {
            return 0
        }
        let cp = UInt32(runes[0])
        return if (TuiCanvas.isWideCp(cp)) { 2 } else { 1 }
    }

    /**
     * 东亚宽字符码点判断（wcwidth wide 简化版，覆盖 CJK/全角/谚文/emoji 等；
     * public 供 StatusBar/ConfirmDialog 等组件复用宽度计算）
     */
    public static func isWideCp(cp: UInt32): Bool {
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
        if (cp >= 0x1F000 && cp <= 0x1FAFF) { return true }  // emoji（📁 等，终端占 2 列）
        if (cp >= 0x2600 && cp <= 0x27BF) { return true }    // 杂项符号/装饰（★ ☀ ♥ ▶ ● ⬢ 等，部分终端占 2 列）
        return false
    }

    /**
     * 字符串显示宽度（ANSI 感知）：转义序列整体跳过不计宽，可见字符按
     * 码点判断（CJK/emoji=2 列）。与 truncate 同规则，供组件做宽度对齐
     * 填充（边框线、两栏布局）时复用——若把 ANSI 序列按字符计宽，
     * 带色内容宽度会虚高，导致填充不足、边框不铺满。
     */
    public static func displayWidth(s: String): Int64 {
        var n: Int64 = 0
        var i: Int64 = 0
        let len = s.size
        while (i < len) {
            let b = s[i]
            if (b == 27u8) {
                // ANSI 转义序列：整体跳过，不计可见宽度
                i += 1
                // CSI 序列（ESC [ ... 终结字母 0x40..0x7E）
                if (i < len && s[i] == 91u8 /* '[' */) {
                    i += 1
                    while (i < len) {
                        let c = s[i]
                        i += 1
                        if (Int32(c) >= 0x40 && Int32(c) <= 0x7E) {
                            break
                        }
                    }
                }
                continue
            }
            // 可见字符：按首字节判定完整字符字节数
            let b0 = Int32(b)
            var chLen: Int64 = 1
            if (b0 >= 0xF0) {
                chLen = 4
            } else if (b0 >= 0xE0) {
                chLen = 3
            } else if (b0 >= 0xC0) {
                chLen = 2
            }
            if (i + chLen > len) {
                chLen = len - i
            }
            var cp: UInt32 = UInt32(b)
            if (chLen > 1) {
                // 多字节字符：取首个码点判宽
                try {
                    let runes = s[i..i + chLen].toRuneArray()
                    if (runes.size > 0) {
                        cp = UInt32(runes[0])
                    }
                } catch (e: Exception) {
                    ()
                }
            }
            n += if (TuiCanvas.isWideCp(cp)) { 2 } else { 1 }
            i += chLen
        }
        return n
    }

    /**
     * 重复空格填充（列偏移占位）
     */
    private func fillSpaces(n: Int64): String {
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < n) {
            sb.append(" ")
            i += 1
        }
        return sb.toString()
    }
}
