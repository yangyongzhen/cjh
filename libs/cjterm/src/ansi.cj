package cjterm


/**
 * ANSI 终端控制：颜色、光标、清屏
 */
public class Ansi {
    public static func esc(): String { return Rune(27).toString() }

    public static func clearScreen(): String { return Ansi.esc() + "[2J" + Ansi.esc() + "[H" }
    public static func clearLine(): String { return Ansi.esc() + "[2K" }
    public static func moveTo(row: Int64, col: Int64): String { return Ansi.esc() + "[${row};${col}H" }
    public static func hideCursor(): String { return Ansi.esc() + "[?25l" }
    public static func showCursor(): String { return Ansi.esc() + "[?25h" }
    // 颜色/样式转义：NO_COLOR 时返回空串（标准语义，纯文本输出）
    public static func reset(): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[0m" } }
    public static func bold(): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[1m" } }
    public static func italic(): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[3m" } }
    public static func dim(): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[2m" } }
    public static func underline(): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[4m" } }
    public static func fg(code: Int64): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[38;5;${code}m" } }
    public static func bg(code: Int64): String { return if (Ansi.noColor) { "" } else { Ansi.esc() + "[48;5;${code}m" } }

    // ===== 备用缓冲区（alt screen）=====
    // 进入后程序拥有独立屏幕，退出时恢复调用前画面（smcup/rmcup）
    public static func enterAltScreen(): String { return Ansi.esc() + "[?1049h" }
    public static func exitAltScreen(): String { return Ansi.esc() + "[?1049l" }

    // ===== 鼠标模式 =====
    // ?1000 基础点击；?1006 SGR 编码（坐标 1-based，支持 >223 列）；?1003 全区域移动
    public static func enableMouse(): String { return Ansi.esc() + "[?1000h" + Ansi.esc() + "[?1006h" }
    public static func disableMouse(): String { return Ansi.esc() + "[?1000l" + Ansi.esc() + "[?1006l" }

    // 常用色
    public static let COLOR_RESET: Int64 = 0
    public static let COLOR_BLACK: Int64 = 0
    public static let COLOR_GRAY: Int64 = 245
    public static let COLOR_WHITE: Int64 = 15
    public static let COLOR_CYAN: Int64 = 51
    public static let COLOR_GREEN: Int64 = 82
    public static let COLOR_YELLOW: Int64 = 226
    public static let COLOR_RED: Int64 = 196
    public static let COLOR_BLUE: Int64 = 39
    public static let COLOR_DARK: Int64 = 240
    // 主题色（运行时可变，Theme.apply(name) 切换；详见 docs/cjh-TUI主题设计方案.md）
    // 初始值 = omp-dark 配色，由 Theme.apply 在启动时写入
    public static var THEME_PRIMARY: Int64 = 31    // 品牌蓝（omp #178fb9 近似）
    public static var THEME_ACCENT: Int64 = 214    // 琥珀（omp #febc38 近似）
    public static var THEME_PURPLE: Int64 = 74     // 代码关键字（omp #569CD6 近似）
    public static var THEME_OK: Int64 = 114        // 成功绿（omp #89d281 近似）
    public static var THEME_WARN: Int64 = 178      // 警告黄（omp #e4c00f 近似）
    public static var THEME_ERR: Int64 = 203       // 错误红（omp #fc3a4b 近似）
    public static var THEME_MUTED: Int64 = 243     // 次要灰（omp #777d88 近似）
    public static var THEME_INFO: Int64 = 103      // 上下文淡蓝灰（omp #8787af）
    public static var THEME_HIGHLIGHT: Int64 = 214 // 选中行高亮（与 THEME_ACCENT 同色码）
    public static var COLOR_TEXT: Int64 = 254      // 正文（omp #e5e5e7 近似）
    public static var COLOR_BG: Int64 = 235        // 深炭灰（背景层，暂未启用背景色）

    // ===== 视觉层次：背景卡片色 + 边框色 + 链接色（参考 omp dark.json，xterm-256 近似）=====
    // 仅用户回显与状态栏铺整行背景；工具/思考行改为无背景（避免与内容不贴合的色块）。
    public static var THEME_STATUS_BG: Int64 = 233   // 状态栏整行背景（≈ omp statusLineBg #121212）
    public static var THEME_USER_BG: Int64 = 235     // 用户输入回显行背景（≈ omp userMessageBg #221d1a 提亮）
    public static var THEME_TOOL_BG: Int64 = 235     // 工具卡片背景（内置工具行已不用）
    public static var THEME_THINKING_BG: Int64 = 233 // 思考卡片背景（内置思考块已不用）
    public static var THEME_CODE_BG: Int64 = 236     // 行内代码芯片背景（≈ omp mdCodeBlock）
    public static var THEME_LINK: Int64 = 33         // 链接色（≈ omp #0088fa）
    public static var THEME_BORDER: Int64 = 31       // 边框实线色（≈ omp border #178fb9）

    // NO_COLOR（标准语义）：设了则所有颜色/样式转义返回空串（纯文本输出，管道/CI 干净）
    // static var（非 let）：测试可切换；默认读 NO_COLOR 环境变量
    public static var noColor: Bool = (TermEnv.getenv("NO_COLOR") ?? "") != ""

    /**
     * 整行背景卡片：把 line（预渲染 ANSI）按 displayWidth 补空格到 cols，外包 bg(code)…reset。
     * 用于用户回显/工具行/思考块整行铺背景（对齐 omp 卡片）。
     * 约束：line 内部配色只能用 fg()/bg() 增量设置，禁止中途 reset（否则背景被截断）；
     *       行尾的 reset 由本函数统一补，truncate 截断后仍有 flush 行尾 reset 兜底防泄漏。
     * NO_COLOR 时原样返回（不铺背景、不补空格）。
     */
    public static func padBg(line: String, cols: Int64, code: Int64): String {
        if (Ansi.noColor) { return line }
        if (cols <= 0) { return Ansi.bg(code) + line + Ansi.reset() }
        let used = TuiCanvas.displayWidth(line)
        var pad = cols - used
        if (pad < 0) { pad = 0 }
        var sb = StringBuilder()
        sb.append(Ansi.bg(code))
        sb.append(line)
        var i: Int64 = 0
        while (i < pad) {
            sb.append(" ")
            i += 1
        }
        sb.append(Ansi.reset())
        return sb.toString()
    }
}

/**
 * 终端尺寸查询（每帧实时，resize 感知）
 */
public class TermSize {
    // 共享实例（size() 无状态，避免每帧 new backend）
    private static let shared: Term = Term()

    public static func get(): (Int64, Int64) {
        return TermSize.shared.size()
    }
}
