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
 * - omp-dark（默认）：对齐 oh-my-pi dark 主题，蓝/青/琥珀 + 中性灰
 * - starfrost（星霜青）：鸿蒙生态同源品牌色，低饱和雾面青
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
    // P2b 视觉层次（背景卡片 + 边框 + 链接）
    // 卡片底色统一用近背景中性灰阶：用户卡片 235（≈ omp userMessageBg #221d1a 的
    // 提亮近似），状态栏 233（≈ omp statusLineBg #121212）。工具/思考行不再铺
    // 整行背景（见 TuiApp.appendToolLine / OutputView.thinkingLine），
    // toolBg/thinkingBg 仅保留给插件或后续自定义卡片。
    public var statusBg: Int64 = 233    // 状态栏整行背景
    public var userBg: Int64 = 235      // 用户输入回显行背景
    public var toolBg: Int64 = 235      // 工具卡片背景（内置工具行已不用）
    public var thinkingBg: Int64 = 233  // 思考卡片背景（内置思考块已不用）
    public var codeBg: Int64 = 236      // 行内代码芯片背景
    public var link: Int64 = 33         // 链接色（omp #0088fa 近似）
    public var border: Int64 = 244      // 边框实线色

    public init() {}
}

public class Theme {
    // 当前生效的主题名
    public static var currentName: String = "omp-dark"

    // 主题注册表：name -> Palette
    private static var themes: HashMap<String, Palette> = Theme.buildInbuiltThemes()

    /**
     * 构建内置主题表
     */
    private static func buildInbuiltThemes(): HashMap<String, Palette> {
        var map = HashMap<String, Palette>()

        // omp-dark：oh-my-pi dark 主题的 xterm-256 近似（默认）
        // 目标色见 omp packages/coding-agent/src/modes/theme/dark.json：
        // accent #febc38 / primary #178fb9 / success #89d281 / error #fc3a4b /
        // muted #777d88 / link #0088fa / text #e5e5e7。
        let ompDark = Palette()
        ompDark.primary = 31         // 品牌蓝 #178fb9
        ompDark.accent = 214         // 琥珀 #febc38
        ompDark.purple = 74          // 代码关键字 #569CD6
        ompDark.ok = 114             // 成功绿 #89d281
        ompDark.warn = 178           // 警告黄 #e4c00f
        ompDark.err = 203            // 错误红 #fc3a4b
        ompDark.muted = 243          // 次要灰 #777d88
        ompDark.info = 103           // 上下文淡蓝灰 #8787af
        ompDark.highlight = 214      // 选中行高亮
        ompDark.text = 254           // 正文 #e5e5e7
        ompDark.bg = 235             // 深炭灰
        ompDark.statusBg = 233       // #121212
        ompDark.userBg = 235         // #221d1a 的提亮近似
        ompDark.toolBg = 235         // #1d2129 近似（内置工具行已不用）
        ompDark.thinkingBg = 233     // #141414 近似（内置思考块已不用）
        ompDark.codeBg = 236
        ompDark.link = 33            // #0088fa
        ompDark.border = 31          // #178fb9
        map["omp-dark"] = ompDark

        // starfrost：星霜青（鸿蒙生态同源品牌色，保留为可选主题）
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
        starfrost.border = 73        // 星霜青 accent（品牌主色，输入框╰─/状态栏边框）
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
        classic.border = 51          // 亮青 accent（高饱和亮青，醒目）
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
        dracula.border = 177         // 紫 #BD93F9（注释意图 border=purple）
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
        nord.border = 110            // 冰蓝青 nord8 #88C0D0（比 nord10 更亮，保醒目）
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
        gruvbox.border = 208         // 橙 #FE8019（accent，暖复古醒目）
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
        tokyoNight.border = 33       // 蓝 #7AA2F7（注释意图 border=blue）
        map["tokyo-night"] = tokyoNight

        // catppuccin：柔和暖色暗色主题（粉橙薰衣草）
        // 参考 omp dark-catppuccin：accent=peach, border=blue, borderAccent=lavender
        let catppuccin = Palette()
        catppuccin.primary = 111     // 柔蓝 (blue #89B4FA 近似)
        catppuccin.accent = 216      // 桃橙 (peach #FAB387 近似)
        catppuccin.purple = 183      // 薰衣草 (mauve #CBA6F7 近似)
        catppuccin.ok = 151          // 柔绿 (green #A6E3A1 近似)
        catppuccin.warn = 229        // 暖黄 (yellow #F9E2AF 近似)
        catppuccin.err = 211         // 柔粉红 (red #F38BA8 近似)
        catppuccin.muted = 102       // 灰蓝 (overlay1 #7F849C 近似)
        catppuccin.info = 147        // 淡薰衣草 (lavender #B4BEFE 近似)
        catppuccin.highlight = 216   // 桃橙（选中行高亮）
        catppuccin.text = 189        // 近白 (text #CDD6F4 近似)
        catppuccin.bg = 235          // 深炭灰 (base #1E1E2E 近似)
        catppuccin.border = 111      // 柔蓝 blue #89B4FA（注释意图 border=blue）
        map["catppuccin"] = catppuccin

        // rose-pine：玫瑰松石暗色主题（玫红松绿金）
        // 参考 omp dark-rose-pine：accent=iris, border=pine, borderAccent=foam
        let rosePine = Palette()
        rosePine.primary = 30        // 松石青 (pine #31748F 近似)
        rosePine.accent = 183        // 鸢尾紫 (iris #C4A7E7 近似)
        rosePine.purple = 183        // 鸢尾紫
        rosePine.ok = 152            // 泡沫青 (foam #9CCFD8 近似)
        rosePine.warn = 222          // 玫瑰金 (gold #F6C177 近似)
        rosePine.err = 204           // 玫红 (love #EB6F92 近似)
        rosePine.muted = 60          // 暗紫灰 (muted #6E6A86 近似)
        rosePine.info = 181          // 玫瑰粉 (rose #EBBCBA 近似)
        rosePine.highlight = 183     // 鸢尾紫（选中行高亮）
        rosePine.text = 189          // 近白 (text #E0DEF4 近似)
        rosePine.bg = 235            // 深炭灰 (base #191724 近似)
        rosePine.border = 30         // 松石青 pine #31748F（注释意图 border=pine）
        map["rose-pine"] = rosePine

        // solarized：经典护眼暗色主题（蓝青绿黄）
        // 参考 omp dark-solarized：accent=blue, border=base01, borderAccent=cyan
        let solarized = Palette()
        solarized.primary = 66       // 深蓝灰 (base01 #586E75 近似)
        solarized.accent = 33        // 太阳蓝 (blue #268BD2 近似)
        solarized.purple = 62        // 紫罗兰 (violet #6C71C4 近似)
        solarized.ok = 100           // 深苔绿 (green #859900 近似)
        solarized.warn = 136         // 琥珀黄 (yellow #B58900 近似)
        solarized.err = 166          // 深红 (red #DC322F 近似)
        solarized.muted = 102        // 暗蓝灰 (base00 #657B83 近似)
        solarized.info = 37          // 青绿 (cyan #2AA198 近似)
        solarized.highlight = 33     // 太阳蓝（选中行高亮）
        solarized.text = 230         // 暖白 (base3 #FDF6E3 近似)
        solarized.bg = 235           // 深炭灰 (base03 #002B36 近似)
        solarized.border = 37        // 青绿 cyan #2AA198（base01 太暗，取亮青绿保醒目）
        map["solarized"] = solarized

        // monokai：经典编辑器暗色主题（粉绿黄橙紫）
        // 参考 omp dark-monokai：accent=orange, border=cyan, borderAccent=pink
        let monokai = Palette()
        monokai.primary = 81         // 青绿 (cyan #66D9EF 近似)
        monokai.accent = 214         // 橙 (orange #FD971F 近似)
        monokai.purple = 141         // 紫 (purple #AE81FF 近似)
        monokai.ok = 119             // 鲜绿 (green #A6E22E 近似)
        monokai.warn = 186           // 暖黄 (yellow #E6DB74 近似)
        monokai.err = 197            // 粉红 (pink #F92672 近似)
        monokai.muted = 247          // 中灰 (gray #999999 近似)
        monokai.info = 101           // 暗橄榄 (comment #75715E 近似)
        monokai.highlight = 214      // 橙（选中行高亮）
        monokai.text = 231           // 近白 (foreground #F8F8F2 近似)
        monokai.bg = 235             // 深炭灰 (background #272822 近似)
        monokai.border = 81          // 青绿 cyan #66D9EF（注释意图 border=cyan）
        map["monokai"] = monokai

        return map
    }

    /**
     * 应用指定主题：查表 → 写回 Ansi.THEME_* 静态变量
     * @param name 主题名（omp-dark / starfrost / classic / ...）；空或未知名回退 omp-dark
     * @return 实际生效的主题名
     */
    public static func apply(name: String): String {
        let key = if (name.size == 0) { "omp-dark" } else { name }
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
            Ansi.THEME_STATUS_BG = p.statusBg
            Ansi.THEME_USER_BG = p.userBg
            Ansi.THEME_TOOL_BG = p.toolBg
            Ansi.THEME_THINKING_BG = p.thinkingBg
            Ansi.THEME_CODE_BG = p.codeBg
            Ansi.THEME_LINK = p.link
            Ansi.THEME_BORDER = p.border
            Theme.currentName = key
            return key
        }
        // 未知主题名：回退默认 omp-dark
        return Theme.apply("omp-dark")
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
