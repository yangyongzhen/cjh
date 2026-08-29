package cjterm

import std.convert.Parsable
import std.time.*

/**
 * 终端控制器：原始模式管理 + 按键读取 + 尺寸（平台无关层）
 *
 * 平台相关实现委托给 TerminalBackend（见 term_backend.cj）：
 *   - POSIX（Linux/macOS）：term_posix.cj（termios/ioctl/select）
 *   - Windows：term_windows.cj（Win32 Console API）
 * 输出侧 ANSI/VT 转义（备用屏/鼠标/差分渲染）跨平台统一，无需分平台。
 */

/**
 * 按键事件
 */
public class KeyEvent {
    public let ch: Int32
    public let isEsc: Bool
    public let isEnter: Bool
    public let isCtrlC: Bool
    public let isBackspace: Bool
    public let isTab: Bool
    public let isArrowUp: Bool
    public let isArrowDown: Bool
    public let isArrowLeft: Bool
    public let isArrowRight: Bool
    public let isPageUp: Bool
    public let isPageDown: Bool
    public let isCtrlU: Bool
    public let isCtrlD: Bool
    public let escapeSeq: String   // 完整转义序列（如 ESC[A）；普通键为空
    public let text: String        // 输入字符（支持多字节 UTF-8，如中文）；控制键为空
    // 鼠标事件（SGR 编码 ESC[<b;x;yM/m）
    public let isMouse: Bool
    public let mouseButton: Int64  // 0=左 1=中 2=右（低 2 位）；64=滚轮上 65=滚轮下
    public let mouseX: Int64       // 1-based 列
    public let mouseY: Int64       // 1-based 行
    // 粘贴事件（bracketed paste ESC[200~...ESC[201~）：text=整段粘贴内容，
    // 含换行/转义也不逐键解析（防粘贴内容触发 Enter/Esc 穿透弹窗）
    public let isPaste: Bool

    public init(ch: Int32) {
        this.ch = ch
        this.isEsc = (ch == 27)
        this.isEnter = (ch == 13 || ch == 10)
        this.isCtrlC = (ch == 3)
        this.isBackspace = (ch == 127 || ch == 8)
        this.isTab = (ch == 9)
        this.isArrowUp = false
        this.isArrowDown = false
        this.isArrowLeft = false
        this.isArrowRight = false
        this.isPageUp = false
        this.isPageDown = false
        this.isCtrlU = (ch == 21)
        this.isCtrlD = (ch == 4)
        this.escapeSeq = ""
        this.text = Rune(ch).toString()
        this.isMouse = false
        this.mouseButton = -1
        this.mouseX = -1
        this.mouseY = -1
        this.isPaste = false
    }

    /**
     * 粘贴事件构造：整段文本整体追加（不做按键语义解析）
     */
    public init(pasteText: String) {
        this.ch = 0
        this.isEsc = false
        this.isEnter = false
        this.isCtrlC = false
        this.isBackspace = false
        this.isTab = false
        this.isArrowUp = false
        this.isArrowDown = false
        this.isArrowLeft = false
        this.isArrowRight = false
        this.isPageUp = false
        this.isPageDown = false
        this.isCtrlU = false
        this.isCtrlD = false
        this.escapeSeq = ""
        this.text = pasteText
        this.isMouse = false
        this.mouseButton = -1
        this.mouseX = -1
        this.mouseY = -1
        this.isPaste = true
    }

    public init(ch: Int32, seq: String) {
        // seq 可能是转义序列（ESC[...）或输入字符（中文等）
        this.ch = ch
        this.isEsc = (ch == 27)
        this.isEnter = (ch == 13 || ch == 10)
        this.isCtrlC = (ch == 3)
        this.isBackspace = (ch == 127 || ch == 8)
        this.isTab = (ch == 9)
        this.isArrowUp = (seq == TermEsc.UP || seq == TermEsc.SS3_UP)
        this.isArrowDown = (seq == TermEsc.DOWN || seq == TermEsc.SS3_DOWN)
        this.isArrowRight = (seq == TermEsc.RIGHT || seq == TermEsc.SS3_RIGHT)
        this.isArrowLeft = (seq == TermEsc.LEFT || seq == TermEsc.SS3_LEFT)
        this.isPageUp = (seq == TermEsc.PGUP)
        this.isPageDown = (seq == TermEsc.PGDN)
        this.isCtrlU = (ch == 21)
        this.isCtrlD = (ch == 4)
        // 若是转义序列则 text 为空（非输入字符）；否则为输入字符
        this.escapeSeq = if (seq.startsWith(TermEsc.ESC)) { seq } else { "" }
        this.text = if (seq.startsWith(TermEsc.ESC)) { "" } else { seq }
        this.isPaste = false
        // SGR 鼠标：ESC[<b;x;yM（按下）或 m（释放）
        if (seq.startsWith(TermEsc.ESC + "[<")) {
            let body = seq[3..seq.size - 1]
            let parts = body.split(";", -1)
            this.isMouse = true
            if (parts.size >= 3) {
                var b: Int64 = -1
                var x: Int64 = -1
                var y: Int64 = -1
                try { b = Int64.parse(parts[0]) } catch (e: Exception) {}
                try { x = Int64.parse(parts[1]) } catch (e: Exception) {}
                try { y = Int64.parse(parts[2]) } catch (e: Exception) {}
                this.mouseButton = b
                this.mouseX = x
                this.mouseY = y
            } else {
                this.mouseButton = -1
                this.mouseX = -1
                this.mouseY = -1
            }
        } else {
            this.isMouse = false
            this.mouseButton = -1
            this.mouseX = -1
            this.mouseY = -1
        }
    }
}

/**
 * 终端控制器：委托 TerminalBackend 实现平台差异，对外 API 与旧版一致
 */
public class Term {
    private let backend: TerminalBackend
    private var rawOn: Bool = false

    public init() {
        this.backend = createTerminalBackend()
    }

    public func enableRaw(): Bool {
        if (this.rawOn) {
            return true
        }
        if (this.backend.enableRaw()) {
            this.rawOn = true
            return true
        }
        return false
    }

    public func disableRaw(): Unit {
        if (!this.rawOn) {
            return
        }
        this.backend.disableRaw()
        this.rawOn = false
    }

    public func hasInput(): Bool {
        return this.backend.hasInput()
    }

    /**
     * 带超时等待输入（select timeout）。
     * 真实终端/SSH 中转义序列字节可能分批到达：ESC 后跟的字节常在同一
     * 个 select 批次，但网络/PTY 缓冲下可能延迟。等待 timeoutMs 毫秒，
     * 期间有输入返回 true，超时返回 false。
     */
    public func waitInput(timeoutMs: Int64): Bool {
        return this.backend.waitInput(timeoutMs)
    }

    /**
     * 非阻塞读按键；无输入返回 None
     */
    public func readKey(): Option<KeyEvent> {
        return this.backend.readKey()
    }

    /**
     * 检测终端是否支持 UTF-8
     * 非 UTF-8 终端（如 GBK/Latin-1）下 UI 应降级为 ASCII
     */
    public func isUtf8(): Bool {
        return this.backend.isUtf8()
    }

    public func size(): (Int64, Int64) {
        // 每帧返回真实尺寸（resize 感知），不做静态缓存——
        // 历史缓存目的（stderr suppress 后 ioctl(STDERR) 失效回退 80 列）
        // 已被 backend 的 STDIN/STDOUT/STDERR 依次尝试覆盖
        return this.backend.size()
    }

    // ===== 尺寸变化探测（resize 自动感知）=====
    private var lastRows: Int64 = -1
    private var lastCols: Int64 = -1

    /**
     * 检测终端尺寸是否变化（与上次调用对比；首次调用返回 true）
     */
    public func sizeChanged(): Bool {
        let (rows, cols) = this.size()
        let changed = (rows != this.lastRows || cols != this.lastCols)
        this.lastRows = rows
        this.lastCols = cols
        return changed
    }

    // ===== 备用缓冲区 / 鼠标模式便捷封装（ANSI 转义，跨平台）=====
    public func enterAltScreen(): Unit {
        print(Ansi.enterAltScreen(), flush: true)
    }

    public func exitAltScreen(): Unit {
        print(Ansi.exitAltScreen(), flush: true)
    }

    public func enableMouse(): Unit {
        print(Ansi.enableMouse(), flush: true)
    }

    public func disableMouse(): Unit {
        print(Ansi.disableMouse(), flush: true)
    }
}

/**
 * 环境变量读取（cjterm 零依赖，自带 getenv FFI）
 */
@C
foreign func getenv(name: CString): CPointer<UInt8>

public class TermEnv {
    public static func getenv(name: String): Option<String> {
        unsafe {
            let p = getenv(LibC.mallocCString(name))
            if (p.isNull()) {
                return None
            }
            let cs = CString(p)
            return Some(cs.toString())
        }
    }
}

/**
 * 转义序列常量（Rune(27) 构造 ESC，避免 \u 转义问题）
 */
public class TermEsc {
    public static let ESC: String = Rune(27).toString()
    // CSI 方向键（多数终端）：ESC [ A/B/C/D
    public static let UP: String = ESC + "[A"
    public static let DOWN: String = ESC + "[B"
    public static let RIGHT: String = ESC + "[C"
    public static let LEFT: String = ESC + "[D"
    public static let PGUP: String = ESC + "[5~"
    public static let PGDN: String = ESC + "[6~"
    // SS3 应用方向键（xterm/alt-screen 下滚轮映射、部分终端默认）：
    // ESC O A/B/C/D —— 与 CSI 形式同义，必须识别，否则被拆成 ESC/O/A 残留字母
    public static let SS3_UP: String = ESC + "OA"
    public static let SS3_DOWN: String = ESC + "OB"
    public static let SS3_RIGHT: String = ESC + "OC"
    public static let SS3_LEFT: String = ESC + "OD"
}

/**
 * stderr 屏蔽便捷入口（委托平台后端；POSIX 重定向 /dev/null，
 * Windows 重定向 NUL 设备）
 */
public class Stderr {
    private static var backend: ?TerminalBackend = None

    private static func getBackend(): TerminalBackend {
        if (let Some(b) <- Stderr.backend) {
            return b
        }
        let b = createTerminalBackend()
        Stderr.backend = Some(b)
        return b
    }

    /**
     * 屏蔽 stderr（重定向到 /dev/null 或 NUL），返回是否成功
     */
    public static func suppress(): Bool {
        return Stderr.getBackend().suppressStderr()
    }

    /**
     * 恢复 stderr
     */
    public static func restore(): Unit {
        Stderr.getBackend().restoreStderr()
    }
}
