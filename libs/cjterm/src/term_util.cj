package cjterm

import std.collection.*
import std.fs.*

/**
 * UTF-8 安全解码：非法字节序列用替换字符（U+FFFD）代替，不抛异常。
 *
 * 内联自 cjutil（与 truncateUtf8 同策略：独立库自包含，零外部依赖）。
 * 背景：cjterm 全库只此一处需要 cjutil，却让整个终端库被迫依赖一个带 stdx 的
 * 重包——Windows 原生构建会因此连 `cjpm build` 都过不去（stdx 无 windows 平台
 * 目录时报 `can not find package 'stdx.encoding.json'`）。
 */
@When[os != "Windows"]
internal func safeFromUtf8(bytes: Array<UInt8>): String {
    var sb = StringBuilder()
    var i = 0
    let n = bytes.size
    while (i < n) {
        let b0 = bytes[i]
        var len = 1
        var valid = true
        if (b0 < 0x80u8) {
            len = 1
        } else if ((b0 & 0xE0u8) == 0xC0u8) {
            len = 2
        } else if ((b0 & 0xF0u8) == 0xE0u8) {
            len = 3
        } else if ((b0 & 0xF8u8) == 0xF0u8) {
            len = 4
        } else {
            valid = false
        }
        if (valid && i + len > n) {
            valid = false
        }
        if (valid) {
            for (j in 1..len) {
                if ((bytes[i + j] & 0xC0u8) != 0x80u8) {
                    valid = false
                    break
                }
            }
        }
        if (valid) {
            try {
                sb.append(String.fromUtf8(bytes[i..i + len]))
            } catch (e: Exception) {
                sb.append("\u{FFFD}")
            }
            i += len
        } else {
            sb.append("\u{FFFD}")
            i += 1
        }
    }
    return sb.toString()
}

/** 字节安全截断（已废弃）——
 *
 * 上游面板改为 `TuiCanvas.truncate`（ANSI/显示宽感知）后本函数已无调用方，
 * 删除以免 Cangjie 1.2.0 报 unused function；保留此注记解释历史。
 */

/**
 * 单个控制字符判定（`KeyEvent.text` 契约兜底）：控制键的 text 应为空串。
 *
 * 背景（v1.4.0）：`KeyEvent(ch)` 旧实现无条件 `text = Rune(ch).toString()`，
 * Ctrl+O(0x0F)、Ctrl+Z(0x1A) 等控制字节因此带上 text，经 InputBox/Editor
 * 可打印分支（只判 `!isEsc && !isEnter && !isBackspace`）漏进输入框。
 * `\t`(9)/`\n`(10)/`\r`(13) 例外——Enter/Tab 语义由 isEnter/isTab 承载，
 * 且粘贴聚合判定依赖其 `text.size == 1`（见 term.cj isPasteCandidate）。
 */
internal func isLoneControlText(s: String): Bool {
    if (s.size != 1) {
        return false
    }
    let b = s.toArray()[0]
    if (b >= 32u8 && b != 127u8) {
        return false
    }
    return b != 9u8 && b != 10u8 && b != 13u8
}

/**
 * token 计数的人类可读格式（k 单位）——UI 侧唯一入口。
 *
 * 契约：< 1000 原样十进制（842）；1000 ~ 99999 一位小数 k（1.2k、99.9k）；
 * ≥ 100000 取整 k（128k，省宽度，避免 6 位数字挤爆状态行）；负值原样返回兜底。
 *
 * 集中定义（勿在各调用点各写一份）：实时状态行 `↑ 1.2k tokens`、思考折叠行
 * `(↑ 1.2k tokens)`、回合总结条 `1.5k tokens` 共用同一格式，避免小数位/单位漂移。
 * 整数运算实现（不用浮点格式化）：1.0k 恰为 "1.0k"、进位不产生 "1.10k"。
 */
public func fmtTokenCount(n: Int64): String {
    if (n < 1000) {
        return n.toString()
    }
    let kInt = n / 1000
    if (kInt >= 100) {
        return kInt.toString() + "k"
    }
    return kInt.toString() + "." + ((n % 1000) / 100).toString() + "k"
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
 * **v1.6.2 修（Git 装在非 C 盘时 bash 工具整条死掉）**：原实现只试三个写死的
 * `C:\Program Files\...` 候选、且**不做存在性校验**，于是 Git 装在 `D:\Program Files\Git`
 * 这类机器的 `shellPath` 指向不存在的文件，任何 spawn 都报 Windows error 2
 * （"The system cannot find the file specified"），bash 工具一次都跑不起来。
 * 现在：① 候选由**环境变量**（%ProgramFiles% / %ProgramW6432% / %ProgramFiles(x86)% /
 * %LOCALAPPDATA%）与 **PATH 里的 git.exe** 推导；② 逐个做存在性校验；
 * ③ 一个都不存在就降级 `powershell.exe`（isBash=false，永远存在），**绝不返回死路径**。
 * 依赖：只用到 `std.fs.File.exists`（核心 std，不引 stdx，符合本包零依赖策略）。
 */
public class ShellProvider {
    public let shellPath: String
    public let isBash: Bool  // true = POSIX bash 语法（{ cmd; } 2>&1）；false = PowerShell
    /** 这个 shell 是怎么找到的（`CJH_SHELL` / Git Bash 命中 / `POWERSHELL_SYSROOT` / `POWERSHELL_PATH`）——排障一句话说清 */
    public let source: String

    public init() {
        // 1. CJH_SHELL 环境变量覆盖（用户强制指定任意 shell）
        let custom = TermEnv.getenv("CJH_SHELL") ?? ""
        if (custom.size > 0) {
            this.shellPath = custom
            this.isBash = true  // 假定用户指定的是 bash 兼容 shell
            this.source = "CJH_SHELL"
            return
        }
        // 2. 平台检测 → 自动降级
        if (ShellProvider.isWindows()) {
            // Git Bash 候选：由**环境变量 + PATH 里的 git.exe** 推导（不再写死 C 盘），
            // 并逐个做存在性校验；一个都没有就降级 PowerShell（见下方 else 分支）。
            let cands = ShellProvider.windowsBashCandidates(
                TermEnv.getenv("ProgramFiles") ?? "",
                TermEnv.getenv("ProgramW6432") ?? "",
                TermEnv.getenv("ProgramFiles(x86)") ?? "",
                TermEnv.getenv("LOCALAPPDATA") ?? "",
                TermEnv.getenv("PATH") ?? "",
                ["C", "D", "E", "F", "G", "H"])
            for (c in cands) {
                if (ShellProvider.fileExists(c)) {
                    this.shellPath = c
                    this.isBash = true
                    this.source = "GIT_BASH"
                    return
                }
            }
            // 三级降级：没有任何 Git Bash 就退 PowerShell。**优先用 SystemRoot 的绝对路径**
            // （PATH 被改坏的机器上 `powershell.exe` 这名字也可能起不来），再退裸命令名。
            let sysRoot = TermEnv.getenv("SystemRoot") ?? ""
            let psAbs = if (sysRoot.size > 0) {
                sysRoot + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
            } else {
                ""
            }
            if (psAbs.size > 0 && ShellProvider.fileExists(psAbs)) {
                this.shellPath = psAbs
                this.source = "POWERSHELL_SYSROOT"
            } else {
                this.shellPath = "powershell.exe"
                this.source = "POWERSHELL_PATH"
            }
            this.isBash = false
        } else {
            // Unix：/bin/bash 标准路径（POSIX 系统必有，不存在则 launch 报错）
            this.shellPath = "/bin/bash"
            this.isBash = true
            this.source = "UNIX_DEFAULT"
        }
    }

    /**
     * Windows 上的 Git Bash 候选（**纯函数**，供单测）：环境变量目录 + PATH 里的 git.exe 推导。
     *
     * 顺序：%ProgramFiles% → %ProgramW6432% → %ProgramFiles(x86)% → %LOCALAPPDATA%\Programs
     *      → PATH 里每个含 `\Git\cmd` 或 `\Git\mingw64\bin` 的目录（推导到 `<Git>\bin\bash.exe`）。
     * 去重，保持发现顺序。
     */
    public static func windowsBashCandidates(programFiles: String, programW6432: String,
        programFilesX86: String, localAppData: String, pathEnv: String,
        driveLetters: Array<String>): ArrayList<String> {
        let out = ArrayList<String>()
        let dirs = ArrayList<String>()
        if (programFiles.size > 0) {
            dirs.add(programFiles)
        }
        if (programW6432.size > 0) {
            dirs.add(programW6432)
        }
        if (programFilesX86.size > 0) {
            dirs.add(programFilesX86)
        }
        for (d in dirs) {
            out.add(d + "\\Git\\bin\\bash.exe")
        }
        if (localAppData.size > 0) {
            out.add(localAppData + "\\Programs\\Git\\bin\\bash.exe")
        }
        // PATH 里的 git.exe：`...\Git\cmd\git.exe` / `...\Git\mingw64\bin\git.exe`
        for (seg in pathEnv.split(";", -1)) {
            let p = seg.trimAscii()
            if (p.size == 0) {
                continue
            }
            let derived = bashPathFromGitExe(p + "\\git.exe")
            if (derived.size > 0) {
                out.add(derived)
            }
            let derived2 = bashPathFromGitExe(p + "\\bash.exe")
            if (derived2.size > 0) {
                out.add(derived2)
            }
        }
        // 兜底扫描：任何盘符的 Program Files，以及常见自定义安装根
        // （Git 装在 D:/E: 且不在 PATH 时全靠这一层；更冷门的路径用 CJH_SHELL）
        for (letter in driveLetters) {
            for (root in ["Program Files", "Program Files (x86)"]) {
                out.add("${letter}:\\${root}\\Git\\bin\\bash.exe")
            }
            for (root in ["Git", "tools\\Git", "dev\\Git"]) {
                out.add("${letter}:\\${root}\\bin\\bash.exe")
            }
        }
        // 去重（保持发现顺序；放在最后，避免各层重复命中同一路径）
        let uniq = ArrayList<String>()
        for (c in out) {
            var seen = false
            for (u in uniq) {
                if (u == c) {
                    seen = true
                }
            }
            if (!seen) {
                uniq.add(c)
            }
        }
        return uniq
    }

    /**
     * 从一个可执行文件路径推导同装 Git 目录下的 `bin\bash.exe`（**纯函数**）。
     *
     * `D:\Program Files\Git\cmd\git.exe`        → `D:\Program Files\Git\bin\bash.exe`
     * `D:\Program Files\Git\mingw64\bin\git.exe` → `D:\Program Files\Git\bin\bash.exe`
     * 其它（不含 git 段）→ 空串（不瞎猜）。
     */
    public static func bashPathFromGitExe(exe: String): String {
        let p = exe.trimAscii()
        let lower = p.toAsciiLower()
        let marker = "\\git\\"
        let idx = lower.lastIndexOf(marker)
        match (idx) {
            case Some(i) => return p[0..(i + marker.size - 1)] + "\\bin\\bash.exe"
            case None =>
                // `...\git\cmd\git.exe` 之外，也认 `...\Git\bin\bash.exe` 这类直接给的 bash
                let marker2 = "\\git\\bin\\bash.exe"
                match (lower.lastIndexOf(marker2)) {
                    case Some(_) => return p
                    case None => return ""
                }
        }
    }

    /** 文件是否存在（std.fs 的顶层 `exists(Path)`；不存在/异常一律 false，调用方据此跳过） */
    private static func fileExists(p: String): Bool {
        try {
            return exists(Path(p))
        } catch (e: Exception) {
            return false
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

/** 当前构建是否跑在 Windows 上（`@When` 判据，无需运行时 FFI） */
@When[os == "Windows"]
public func isWindowsHost(): Bool {
    return true
}

@When[os != "Windows"]
public func isWindowsHost(): Bool {
    return false
}

/**
 * 提示符是否用"花体图标"（❯ / 🔍）而不是 ASCII（> / ?）
 *
 * 与 UTF-8 能力**分开判**：conhost（PowerShell / 老控制台窗口）在 cjh 切到代码页 65001 后
 * `isUtf8()` 为 true、框线也能画，但**字体**常常没有 U+276F ❯ 的字形 → 渲染成方框
 * （用户实测，Windows Terminal 正常）。故 Windows 上额外要求"现代终端环境"
 * （Windows Terminal / ConEmu），否则降级成 ASCII 图标。
 *
 * 覆盖开关：`CJH_ASCII_ICONS=1` 强制 ASCII（任何终端可用），
 * `CJH_FORCE_UTF8=1` 强制花体（经 isModernTerminalEnv 生效）。
 */
public func useFancyPromptGlyphs(): Bool {
    return useFancyPromptGlyphsFrom(
        TermEnv.getenv("CJH_ASCII_ICONS"),
        TermEnv.getenv("CJH_FORCE_UTF8"),
        isModernTerminalEnv(),
        isWindowsHost())
}

/**
 * 纯函数判据（不读环境变量，供单测）
 *
 * @param asciiIcons    CJH_ASCII_ICONS 的值（非空 = 强制 ASCII 图标）
 * @param forceUtf8     CJH_FORCE_UTF8 的值（非空 = 强制花体图标）
 * @param modernTerminal 是否现代终端环境（Windows Terminal / ConEmu 等）
 * @param isWindows     是否 Windows
 */
public func useFancyPromptGlyphsFrom(asciiIcons: ?String, forceUtf8: ?String,
    modernTerminal: Bool, isWindows: Bool): Bool {
    if (let Some(v) <- asciiIcons) {
        if (v.size > 0) {
            return false  // 显式强制 ASCII（conhost 字体缺字形的兜底开关）
        }
    }
    if (let Some(v) <- forceUtf8) {
        if (v.size > 0) {
            return true  // 显式强制花体
        }
    }
    if (isWindows) {
        return modernTerminal  // Windows 只信现代终端的字体
    }
    return true  // POSIX 终端字体普遍覆盖 ❯/🔍
}
