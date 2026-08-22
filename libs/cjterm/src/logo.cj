package cjterm

/**
 * CJ 徽标生成器：box-drawing 字符的艺术字 "CJ"（仓颉 Cangjie）
 *
 * 设计：5 行，C 和 J 各 8 列对齐（避免错位），C 用主题蓝，J 用亮青。
 * 非 UTF-8 终端自动降级为纯 ASCII "CJ"。
 *
 *   ██████╗   ██╗
 *  ██╔════╝   ██║
 *  ██║        ██║
 *  ██║        ██║
 *  ╚██████╗   ██║
 *   ╚═════╝   ╚═╝
 */
public class Logo {
    // 普通 ASCII art "CJ"（任何终端渲染一致，避免 box-drawing 字体差异）
    // C 用主题蓝，J 用亮青，双色拼接
    // 大写 CJ（普通 ASCII，任何终端一致）：C 蓝 + J 青，中间 3 空格
    private static let C_LINES: Array<String> = [
        "  ____   ",
        " / ___|  ",
        "| |      ",
        "| |___   ",
        " \\____|  ",
    ]
    private static let J_LINES: Array<String> = [
        "   _    ",
        "  | |   ",
        "  | |   ",
        "  | |   ",
        "  |_|   ",
    ]

    /**
     * 渲染 logo 行数组（每行已着色），返回 Array<String>
     * C 与 J 间 3 空格分隔，J 用宽竖线字形避免误读为 I
     */
    public static func renderLines(utf8: Bool): Array<String> {
        var lines = Array<String>(5, repeat: "")
        for (i in 0..5) {
            let cPart = C_LINES[i] + "   "   // 3 空格
            let jPart = J_LINES[i]
            lines[i] = Ansi.fg(Ansi.THEME_PRIMARY) + cPart + Ansi.fg(Ansi.THEME_ACCENT) + jPart + Ansi.reset()
        }
        return lines
    }

    /**
     * 生成标题栏右侧标题（含版本徽章）
     */
    public static func titleBar(utf8: Bool, model: String): String {
        let name = if (utf8) { "cjh · Cangjie Agent" } else { "cjh - Cangjie Agent" }
        return Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + name + Ansi.reset() +
            "  " + Ansi.fg(Ansi.THEME_MUTED) + "[" + model + "]" + Ansi.reset()
    }

    /**
     * 生成分隔线（按列宽）
     */
    public static func separator(cols: Int64, utf8: Bool): String {
        let ch = if (utf8) { "─" } else { "-" }
        var sb = StringBuilder()
        for (i in 0..cols) {
            sb.append(ch)
        }
        return Ansi.fg(Ansi.THEME_MUTED) + sb.toString() + Ansi.reset()
    }

    /**
     * 状态徽章（● 圆点 + 文本）
     */
    public static func badge(text: String, color: Int64): String {
        return Ansi.fg(color) + "● " + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + text + Ansi.reset()
    }
}
