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
    // UTF-8 版：box-drawing CJ（C 蓝 + J 青）。J 顶钩 ██╗ + 底钩 ╚═╝，
    // 钩子特征鲜明，绝不会误读为 I（旧 ASCII 竖线字形 |_| 正是 CI 误读根源）
    private static let C_BOX_LINES: Array<String> = [
        " ██████╗ ",
        " ██╔════╝",
        " ██║     ",
        " ██║     ",
        " ╚██████╗",
    ]
    private static let J_BOX_LINES: Array<String> = [
        " ██╗ ",
        " ██║ ",
        " ██║ ",
        " ██║ ",
        " ╚═╝ ",
    ]
    // ASCII 降级版：C 保持原样，J 改带左钩字形（|_/），避免竖线+横读成 I
    private static let C_LINES: Array<String> = [
        "  ____   ",
        " / ___|  ",
        "| |      ",
        "| |___   ",
        " \\____|  ",
    ]
    private static let J_LINES: Array<String> = [
        "   __  ",
        "  |  | ",
        "  |  | ",
        "  |  | ",
        "  |_/  ",
    ]

    /**
     * 渲染 logo 行数组（每行已着色），返回 Array<String>
     * C 与 J 间 3 空格分隔；UTF-8 用 box-drawing（J 顶钩+底钩），
     * 非 UTF-8 降级 ASCII（J 带左钩），两版 J 都不再像 I
     */
    public static func renderLines(utf8: Bool): Array<String> {
        var lines = Array<String>(5, repeat: "")
        let cSet = if (utf8) { Logo.C_BOX_LINES } else { Logo.C_LINES }
        let jSet = if (utf8) { Logo.J_BOX_LINES } else { Logo.J_LINES }
        for (i in 0..5) {
            let cPart = cSet[i] + "   "   // 3 空格
            let jPart = jSet[i]
            lines[i] = Ansi.fg(Ansi.THEME_PRIMARY) + cPart + Ansi.fg(Ansi.THEME_ACCENT) + jPart + Ansi.reset()
        }
        return lines
    }

    /**
     * 渲染紧凑版 logo 行数组（3 行，压缩顶部空间给输出区）
     * 保留 CJ 字形特征：C 的左上/下边框 + J 的顶钩/底钩
     */
    public static func renderLinesCompact(utf8: Bool): Array<String> {
        // UTF-8 紧凑版（3 行）：C 保留上下两横 + J 顶钩/底钩
        let cSet = if (utf8) {
            [" ██████╗ ", " ██╔════╝", " ╚██████╗"]
        } else {
            ["  ____   ", " / ___|  ", " \\____|  "]
        }
        let jSet = if (utf8) {
            [" ██╗ ", " ██║ ", " ╚═╝ "]
        } else {
            ["   __  ", "  |  | ", "  |_/  "]
        }
        var lines = Array<String>(3, repeat: "")
        for (i in 0..3) {
            lines[i] = Ansi.fg(Ansi.THEME_PRIMARY) + cSet[i] + "  " + Ansi.fg(Ansi.THEME_ACCENT) + jSet[i] + Ansi.reset()
        }
        return lines
    }

    /**
     * 渲染现代版 logo 行数组（5 行，参考 omp 风格）
     * C：半块字符（▀▄）圆润左弧、右侧开口，一眼是 C
     * J：box-drawing 顶钩 ╗ + 长底钩 ╝，绝不误读为 I（旧紧凑版 J 竖线像 CI）
     * 对齐要求：C 每行统一 10 列、J 每行统一 8 列；
     * J 竖线 ██ 在列 4-5，顶钩 ╗ 与底钩 ╝ 同在列 6——5 行拼接后 J 垂直对齐。
     * 非 UTF-8 降级 ASCII（斜线圆润 C + 顶横竖线底钩 J，同样等宽对齐）。
     */
    public static func renderLinesModern(utf8: Bool): Array<String> {
        let cSet = if (utf8) {
            [
                "▀████████ ",
                "██▀▀▀▀▀▀▀ ",
                "██       ",
                "██▄▄▄▄▄▄▄ ",
                "▄████████ ",
            ]
        } else {
            [
                "  ____    ",
                " / ___|   ",
                "| |       ",
                "| |___    ",
                " \\____|   ",
            ]
        }
        let jSet = if (utf8) {
            [
                "    ████ ",
                "      ██ ",
                "      ██ ",
                "      ██ ",
                "  █████  ",
            ]
        } else {
            [
                "   __   ",
                "    |   ",
                "    |   ",
                "    |   ",
                "  __/   ",
            ]
        }
        var lines = Array<String>(5, repeat: "")
        for (i in 0..5) {
            let cPart = cSet[i] + "   "   // 3 空格分隔
            let jPart = jSet[i]
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
