package cjterm

import std.env.*

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
    public static func reset(): String { return Ansi.esc() + "[0m" }
    public static func bold(): String { return Ansi.esc() + "[1m" }
    public static func italic(): String { return Ansi.esc() + "[3m" }
    public static func dim(): String { return Ansi.esc() + "[2m" }
    public static func fg(code: Int64): String { return Ansi.esc() + "[38;5;${code}m" }
    public static func bg(code: Int64): String { return Ansi.esc() + "[48;5;${code}m" }

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
    // 初始值 = starfrost 星霜青配色，由 Theme.apply 在启动时写入
    public static var THEME_PRIMARY: Int64 = 67    // 雾面深青蓝（鸿蒙蓝灰调，品牌辅色）
    public static var THEME_ACCENT: Int64 = 73     // 星霜青（低饱和雾面青，品牌主色）
    public static var THEME_PURPLE: Int64 = 141    // 紫
    public static var THEME_OK: Int64 = 108        // 低饱和鼠尾草绿（成功 / 就绪）
    public static var THEME_WARN: Int64 = 179      // 浅琥珀金（警告 / 高亮交互 / 状态栏边框）
    public static var THEME_ERR: Int64 = 167       // 低饱和暖红（错误 / 崩溃栈）
    public static var THEME_MUTED: Int64 = 245     // 中性灰（静音 / 分隔线 / 次要文本）
    public static var THEME_INFO: Int64 = 103      // 淡灰蓝（次要信息 / 后台状态）
    public static var THEME_HIGHLIGHT: Int64 = 179 // 浅琥珀金（选中行 / 预览卡片高亮，与 THEME_WARN 同色码）
    public static var COLOR_TEXT: Int64 = 254      // 素白（基础文本层，#E8EAEF 近似）
    public static var COLOR_BG: Int64 = 235        // 深炭灰（背景层，#1A1F26 近似，暂未启用背景色）
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
