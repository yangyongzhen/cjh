package cjh.tui

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
    public static func dim(): String { return Ansi.esc() + "[2m" }
    public static func fg(code: Int64): String { return Ansi.esc() + "[38;5;${code}m" }
    public static func bg(code: Int64): String { return Ansi.esc() + "[48;5;${code}m" }

    // 常用色
    public static let COLOR_RESET: Int64 = 0
    public static let COLOR_GRAY: Int64 = 245
    public static let COLOR_WHITE: Int64 = 15
    public static let COLOR_CYAN: Int64 = 51
    public static let COLOR_GREEN: Int64 = 82
    public static let COLOR_YELLOW: Int64 = 226
    public static let COLOR_RED: Int64 = 196
    public static let COLOR_BLUE: Int64 = 39
    public static let COLOR_DARK: Int64 = 240
}

/**
 * 终端尺寸查询（FFI ioctl TIOCGWINSZ）
 */
public class TermSize {
    public static func get(): (Int64, Int64) {
        let t = Term()
        return t.size()
    }
}
