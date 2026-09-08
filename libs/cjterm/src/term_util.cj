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
/**
 * 平台感知的 shell 解析器（三级降级）：
 * - Windows：Git Bash（POSIX 兼容，保留 bash 语法）→ PowerShell → cmd.exe
 * - Linux/macOS：/bin/bash → /bin/sh
 * - CJH_SHELL 环境变量可强制指定 shell 路径（覆盖所有自动检测）
 *
 * 设计背景（v1.3.17）：cjh 的 bash 工具在 Windows 上直接调用 /bin/bash
 * 导致 ProcessException（Git for Windows 未安装时 /bin/bash 不存在）。
 * Claude Code 的方案：Git Bash 优先 → PowerShell 兜底 → 环境变量覆盖。
 * 本类提供同样的三级降级，BashSession/BashTool 根据 isBash 选择命令语法。
 *
 * 文件存在性不在此处校验——若路径无效，BashSession 的 launch 会抛异常
 * 并由上层（BashTool）捕获返回错误提示，避免 std.fs 依赖。
 */
public class ShellProvider {
    public let shellPath: String
    public let isBash: Bool  // true = POSIX bash 语法（{ cmd; } 2>&1）；false = PowerShell

    public init() {
        // 1. CJH_SHELL 环境变量覆盖（用户强制指定任意 shell）
        let custom = TermEnv.getenv("CJH_SHELL") ?? ""
        if (custom.size > 0) {
            this.shellPath = custom
            this.isBash = true  // 假定用户指定的是 bash 兼容 shell
            return
        }
        // 2. 平台检测 → 自动降级
        if (ShellProvider.isWindows()) {
            // Git Bash 路径候选（按优先级）：优先系统级 → 用户级
            let home = ShellProvider.getHomeUser()
            let gitCandidates = [
                "C:\\Program Files\\Git\\bin\\bash.exe",
                "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
                "C:\\Users\\${home}\\AppData\\Local\\Programs\\Git\\bin\\bash.exe",
            ]
            // 不做 exists 校验——launch 失败由 BashTool 捕获并给出明确提示
            this.shellPath = gitCandidates[0]  // 默认选第一个候选
            this.isBash = true
        } else {
            // Unix：/bin/bash 标准路径（POSIX 系统必有，不存在则 launch 报错）
            this.shellPath = "/bin/bash"
            this.isBash = true
        }
    }

    /** 平台检测：Windows 环境变量 OS=Windows_NT / windir 存在 */
    private static func isWindows(): Bool {
        let os = TermEnv.getenv("OS") ?? ""
        let windir = TermEnv.getenv("windir") ?? ""
        return (os == "Windows_NT" || windir.size > 0)
    }

    /** 取 Windows HOME 用户名（拼 Git portable 路径用） */
    private static func getHomeUser(): String {
        let home = TermEnv.getenv("USERPROFILE") ?? ""
        // USERPROFILE = C:\Users\username → 取最后一路段
        let parts = home.split("\\", -1)
        if (parts.size >= 2) {
            return parts[parts.size - 1]
        }
        return ""
    }
}

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
