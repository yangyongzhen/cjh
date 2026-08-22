package cjterm

/**
 * CJ 徽标生成器：box-drawing 字符的艺术字 "CJ"（仓颉 Cangjie）
 *
 * 设计：4 行 × 12 列，C 用主题蓝，J 用亮青，双色拼接。
 * 非 UTF-8 终端自动降级为纯 ASCII "CJ"。
 *
 *   ██████╗     ██╗
 *  ██╔════╝     ██║
 *  ██║     ████████║
 *  ╚██████╗     ╚═╝
 *   ╚═════╝
 */
public class Logo {
    // box-drawing 字符（UTF-8）
    private static let C_LINES: Array<String> = [
        "██████╗ ",
        "██╔════╝",
        "██║     ",
        "╚██████╗",
        " ╚═════╝",
    ]
    private static let J_LINES: Array<String> = [
        " ██╗",
        " ██║",
        " ████████║",
        " ╚═╝",
        "    ",
    ]

    /**
     * 渲染 logo 行数组（每行已着色），返回 Array<String>
     * @param utf8 终端是否支持 UTF-8（否则 ASCII 降级）
     */
    public static func renderLines(utf8: Bool): Array<String> {
        if (!utf8) {
            // ASCII 降级
            var ascii = Array<String>(4, repeat: "")
            ascii[0] = "  __ _   _   _ "
            ascii[1] = " / _| | | | | |"
            ascii[2] = "| |_| |_| |_| |"
            ascii[3] = " \\__|\\__,_\\__,_|"
            return ascii
        }
        var lines = Array<String>(5, repeat: "")
        for (i in 0..5) {
            let cPart = C_LINES[i]
            let jPart = if (i < J_LINES.size) { J_LINES[i] } else { "" }
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
