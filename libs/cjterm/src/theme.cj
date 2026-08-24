package cjterm

import std.collection.*

/**
 * 终端 UI 主题管理系统
 *
 * 设计目标：
 * - 支持运行时主题切换（/theme 命令）
 * - 调用点零改动：Ansi.THEME_* 从 static let 改 static var，
 *   Theme.apply(name) 批量写回 Ansi.THEME_*
 * - 内置主题可扩展：themes 表 + apply(name) 查表写入
 *
 * 内置主题：
 * - starfrost（星霜青，默认）：鸿蒙生态同源品牌色，低饱和雾面青
 * - classic（经典亮青）：旧版高饱和亮青配色，向后兼容
 *
 * 配色体系详见 docs/cjh-TUI主题设计方案.md
 */
/**
 * 主题色板定义
 * 每个字段对应一个 Ansi.THEME_* 静态变量
 */
public class Palette {
    public var primary: Int64 = 67      // 雾面深青蓝（品牌辅色）
    public var accent: Int64 = 73       // 星霜青（品牌主色）
    public var purple: Int64 = 141      // 紫
    public var ok: Int64 = 108          // 低饱和鼠尾草绿（成功 / 就绪）
    public var warn: Int64 = 179        // 浅琥珀金（警告 / 高亮交互 / 状态栏边框）
    public var err: Int64 = 167         // 低饱和暖红（错误 / 崩溃栈）
    public var muted: Int64 = 245       // 中性灰（静音 / 分隔线 / 次要文本）
    public var info: Int64 = 103        // 淡灰蓝（次要信息 / 后台状态）
    public var highlight: Int64 = 179   // 浅琥珀金（选中行 / 预览卡片高亮）
    public var text: Int64 = 254        // 素白（基础文本层）
    public var bg: Int64 = 235          // 深炭灰（背景层，暂未启用）

    public init() {}
}

public class Theme {
    // 当前生效的主题名
    public static var currentName: String = "starfrost"

    // 主题注册表：name -> Palette
    private static var themes: HashMap<String, Palette> = Theme.buildInbuiltThemes()

    /**
     * 构建内置主题表
     */
    private static func buildInbuiltThemes(): HashMap<String, Palette> {
        var map = HashMap<String, Palette>()

        // starfrost：星霜青（默认，鸿蒙生态同源）
        let starfrost = Palette()
        starfrost.primary = 67       // 雾面深青蓝
        starfrost.accent = 73        // 星霜青
        starfrost.purple = 141       // 紫
        starfrost.ok = 108           // 低饱和鼠尾草绿
        starfrost.warn = 179         // 浅琥珀金
        starfrost.err = 167          // 低饱和暖红
        starfrost.muted = 245        // 中性灰
        starfrost.info = 103         // 淡灰蓝
        starfrost.highlight = 179    // 浅琥珀金
        starfrost.text = 254         // 素白
        starfrost.bg = 235           // 深炭灰
        map["starfrost"] = starfrost

        // classic：经典亮青（旧版配色，向后兼容）
        let classic = Palette()
        classic.primary = 33         // 华为蓝
        classic.accent = 51          // 亮青
        classic.purple = 141         // 紫
        classic.ok = 82              // 亮绿
        classic.warn = 226           // 亮黄
        classic.err = 196            // 高饱和红
        classic.muted = 240          // 暗灰
        classic.info = 103           // 淡灰蓝
        classic.highlight = 226      // 亮黄（选中行高亮）
        classic.text = 15            // 纯白
        classic.bg = 235             // 深炭灰
        map["classic"] = classic

        // dracula：经典暗色主题（紫粉青绿）
        // 参考 omp dark-dracula：accent=purple, border=purple, borderAccent=pink
        let dracula = Palette()
        dracula.primary = 61         // 深紫 (#563f66 近似)
        dracula.accent = 177         // 紫 (#BD93F9)
        dracula.purple = 141         // 紫
        dracula.ok = 84              // 绿 (#50FA7B)
        dracula.warn = 222           // 黄 (#F1FA8C)
        dracula.err = 203            // 红 (#FF5555)
        dracula.muted = 60           // 暗紫灰 (#44475A)
        dracula.info = 117           // 青 (#8BE9FD)
        dracula.highlight = 177      // 紫（选中行高亮）
        dracula.text = 231           // 近白 (#F8F8F2)
        dracula.bg = 235             // 深炭灰 (#282A36 近似)
        map["dracula"] = dracula

        // nord：北欧极简冷色主题（蓝灰冰原）
        // 参考 omp dark-nord：accent=nord8, border=nord10, muted=nord3
        let nord = Palette()
        nord.primary = 67            // 深青蓝 (nord10 近似)
        nord.accent = 110            // 冰蓝青 (nord8 #88C0D0 近似)
        nord.purple = 139            // 北欧紫 (nord15 #B48EAD)
        nord.ok = 150                // 绿 (nord14 #A3BE8C)
        nord.warn = 222              // 黄 (nord13 #EBCB8B)
        nord.err = 174               // 红 (nord11 #BF616A)
        nord.muted = 60              // 深蓝灰 (nord3 #4C566A 近似)
        nord.info = 110              // 冰蓝青
        nord.highlight = 222         // 黄（选中行高亮）
        nord.text = 254              // 素白 (nord6 #ECEFF4 近似)
        nord.bg = 235                // 深炭灰 (nord0 #2E3440 近似)
        map["nord"] = nord

        // gruvbox：复古暖色主题（橙黄绿棕）
        // 参考 omp dark-gruvbox：accent=orange, border=neutralBlue
        let gruvbox = Palette()
        gruvbox.primary = 66         // 复古蓝灰 (neutralBlue #458588 近似)
        gruvbox.accent = 208         // 橙 (#FE8019)
        gruvbox.purple = 175         // 紫粉 (neutralPurple #B16286)
        gruvbox.ok = 142             // 复古绿 (neutralGreen #98971A 近似)
        gruvbox.warn = 214           // 亮黄橙 (yellow #FABD2F 近似)
        gruvbox.err = 160            // 复古红 (neutralRed #CC241D 近似)
        gruvbox.muted = 241          // 中性灰 (bg4 #7C6F64 近似)
        gruvbox.info = 108           // 复古青绿 (aqua #689D6A 近似)
        gruvbox.highlight = 208      // 橙（选中行高亮）
        gruvbox.text = 230           // 暖白 (fg1 #EBDBB2 近似)
        gruvbox.bg = 235             // 深炭灰 (bg0 #282828 近似)
        map["gruvbox"] = gruvbox

        // tokyo-night：东京夜色主题（深蓝紫粉霓虹感）
        // 参考 omp dark-tokyo-night：accent=purple, border=blue, info=cyan
        let tokyoNight = Palette()
        tokyoNight.primary = 33      // 华为蓝 (blue #7AA2F7 近似)
        tokyoNight.accent = 141      // 紫 (purple #BB9AF7)
        tokyoNight.purple = 141      // 紫
        tokyoNight.ok = 114          // 鼠尾草绿 (green #9ECE6A 近似)
        tokyoNight.warn = 179        // 浅琥珀金 (yellow #E0AF68 近似)
        tokyoNight.err = 168         // 樱花粉红 (red #F7768E 近似)
        tokyoNight.muted = 60        // 深蓝紫灰 (comment #51597D 近似)
        tokyoNight.info = 117        // 青 (cyan #7DCFFF)
        tokyoNight.highlight = 141   // 紫（选中行高亮）
        tokyoNight.text = 189        // 浅蓝灰白 (lightBlue #C0CAF5 近似)
        tokyoNight.bg = 235          // 深炭灰 (bg #1A1B26 近似)
        map["tokyo-night"] = tokyoNight

        return map
    }

    /**
     * 应用指定主题：查表 → 写回 Ansi.THEME_* 静态变量
     * @param name 主题名（starfrost / classic）；未知名回退 starfrost
     * @return 实际生效的主题名
     */
    public static func apply(name: String): String {
        let key = if (name.size == 0) { "starfrost" } else { name }
        if (let Some(p) <- Theme.themes.get(key)) {
            Ansi.THEME_PRIMARY = p.primary
            Ansi.THEME_ACCENT = p.accent
            Ansi.THEME_PURPLE = p.purple
            Ansi.THEME_OK = p.ok
            Ansi.THEME_WARN = p.warn
            Ansi.THEME_ERR = p.err
            Ansi.THEME_MUTED = p.muted
            Ansi.THEME_INFO = p.info
            Ansi.THEME_HIGHLIGHT = p.highlight
            Ansi.COLOR_TEXT = p.text
            Ansi.COLOR_BG = p.bg
            Theme.currentName = key
            return key
        }
        // 未知主题名：回退默认 starfrost
        return Theme.apply("starfrost")
    }

    /**
     * 获取当前主题名
     */
    public static func current(): String {
        return Theme.currentName
    }

    /**
     * 列出所有可用主题名
     */
    public static func list(): ArrayList<String> {
        var result = ArrayList<String>()
        for (name in Theme.themes.keys()) {
            result.add(name)
        }
        return result
    }
}
