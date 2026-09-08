package cjterm

/**
 * 字节安全截断：最多截取 maxBytes 字节，若落在 UTF-8 多字节字符中间则递减到合法边界。
 *
 * 内联自 cjutil（独立库自包含，零外部依赖）；避免 String 切片在字符中间抛
 * IllegalArgumentException: Invalid utf8 byte sequence。
 */
internal func truncateUtf8(text: String, maxBytes: Int64): String {
    if (text.size <= maxBytes) {
        return text
    }
    var k = maxBytes
    while (k > 0) {
        try {
            return text[0..k]
        } catch (e: Exception) {
            k -= 1
        }
    }
    return ""
}

/**
 * 统一边框字符集（所有组件 ASCII 降级的唯一来源）
 *
 * 背景（v1.3.16 修复 Windows 框线混排）：此前各组件各自 if (utf8) {...} 硬编码，
 * 部分组件（InputBox/StatusBar/TabBar/TasksPanel）甚至直接写死 UTF-8 框线、无视
 * 标志——Windows 非 65001 代码页下"logo ASCII + 输入框 UTF-8"混排。
 * 现统一从本类取字符：圆角（UI 主体）+ 直角/T 型连接（markdown 表格）。
 */
public class BoxChars {
    // 圆角（欢迎页/弹窗/状态栏/输入框/Tasks 面板）
    public let tl: String   // ╭ / +
    public let tr: String   // ╮ / +
    public let bl: String   // ╰ / +
    public let br: String   // ╯ / +
    public let hc: String   // ─ / -
    public let vc: String   // │ / |
    // 直角 + T 型连接（markdown 表格边框）
    public let stl: String  // ┌ / +
    public let str: String  // ┐ / +
    public let sbl: String  // └ / +
    public let sbr: String  // ┘ / +
    public let tTop: String     // ┬ / +
    public let tBottom: String  // ┴ / +
    public let tLeft: String    // ├ / +
    public let tRight: String   // ┤ / +
    public let tCross: String   // ┼ / +

    public init(utf8: Bool) {
        if (utf8) {
            this.tl = "╭"
            this.tr = "╮"
            this.bl = "╰"
            this.br = "╯"
            this.hc = "─"
            this.vc = "│"
            this.stl = "┌"
            this.str = "┐"
            this.sbl = "└"
            this.sbr = "┘"
            this.tTop = "┬"
            this.tBottom = "┴"
            this.tLeft = "├"
            this.tRight = "┤"
            this.tCross = "┼"
        } else {
            this.tl = "+"
            this.tr = "+"
            this.bl = "+"
            this.br = "+"
            this.hc = "-"
            this.vc = "|"
            this.stl = "+"
            this.str = "+"
            this.sbl = "+"
            this.sbr = "+"
            this.tTop = "+"
            this.tBottom = "+"
            this.tLeft = "+"
            this.tRight = "+"
            this.tCross = "+"
        }
    }
}

/**
 * 现代终端环境检测（环境变量判据，平台无关、可单测）
 *
 * 判据：Windows Terminal（WT_SESSION/WT_PROFILE_ID）、ConPTY 系
 * （ConEmuANSI/ConEmuTask）、或显式 CJH_FORCE_UTF8 强制。
 *
 * 原理：cjh TUI 渲染的前提是终端支持 VT 转义（enableRaw 失败会直接报错退出）。
 * 任何能渲染 VT 的终端都是恒按 UTF-8 渲染的现代终端——Windows Terminal 内部
 * 恒 UTF-8、根本不读控制台代码页（中文系统 CP 仍是 936）。因此不能只用
 * GetConsoleOutputCP()==65001 判定（v1.3.7 Windows 混排根因）。
 */
public func isModernTerminalEnv(): Bool {
    if ((TermEnv.getenv("CJH_FORCE_UTF8") ?? "").size > 0) {
        return true
    }
    if ((TermEnv.getenv("WT_SESSION") ?? "").size > 0) {
        return true
    }
    if ((TermEnv.getenv("WT_PROFILE_ID") ?? "").size > 0) {
        return true
    }
    if ((TermEnv.getenv("ConEmuANSI") ?? "").size > 0) {
        return true
    }
    if ((TermEnv.getenv("ConEmuTask") ?? "").size > 0) {
        return true
    }
    return false
}
