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
