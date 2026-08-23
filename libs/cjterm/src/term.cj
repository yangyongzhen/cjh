package cjterm

import std.convert.Parsable

/**
 * termios 纯 FFI 实现（直接调 libc，无外部 .so 依赖）
 *
 * Linux termios 结构体布局（x86_64，60 字节）：
 *   tcflag_t c_iflag;   // offset 0, 4 bytes
 *   tcflag_t c_oflag;   // offset 4
 *   tcflag_t c_cflag;   // offset 8
 *   tcflag_t c_lflag;   // offset 12
 *   cc_t     c_line;    // offset 16
 *   cc_t     c_cc[32];  // offset 17..48
 *   speed_t  c_ispeed;  // offset 48 (padding)
 *   speed_t  c_ospeed;  // offset 52
 *   // padding to 60
 */

@C
foreign func tcgetattr(fd: Int32, termios: CPointer<UInt8>): Int32

@C
foreign func tcsetattr(fd: Int32, optionalActions: Int32, termios: CPointer<UInt8>): Int32

@C
foreign func read(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64

@C
foreign func ioctl(fd: Int32, request: UInt64, arg: CPointer<UInt8>): Int32

// C 辅助库（native/libcjterm_helper.so）：非变参封装的 winsize 查询
@C
foreign func cj_get_winsize(fd: Int32, rows: CPointer<UInt16>, cols: CPointer<UInt16>): Int32

@C
foreign func select(nfds: Int32, readfds: CPointer<UInt8>, writefds: CPointer<UInt8>, exceptfds: CPointer<UInt8>, timeout: CPointer<UInt8>): Int32

// termios 标志（Linux）
// 本地模式 c_lflag
private let ICANON: UInt32 = 0x2
private let ECHO: UInt32 = 0x8
private let ISIG: UInt32 = 0x1
private let IEXTEN: UInt32 = 0x8000
// 输入模式 c_iflag
private let IXON: UInt32 = 0x400
private let ICRNL: UInt32 = 0x100
private let BRKINT: UInt32 = 0x2
private let INPCK: UInt32 = 0x10
private let ISTRIP: UInt32 = 0x20
// 输出模式 c_oflag
private let OPOST: UInt32 = 0x1
// 控制模式 c_cflag
private let CS8: UInt32 = 0x30

// tcsetattr actions
private let TCSANOW: Int32 = 0
private let TCSAFLUSH: Int32 = 2

// 标准文件描述符
private let STDIN: Int32 = 0
private let STDOUT: Int32 = 1
private let STDERR: Int32 = 2

// ioctl TIOCGWINSZ = 0x5413
private let TIOCGWINSZ: UInt64 = 0x5413

// 缓冲区常量
private let TERMIOS_SIZE: Int64 = 60
private let TIMEVAL_SIZE: Int64 = 16

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
 * 终端控制器：原始模式管理 + 按键读取 + 尺寸（纯 libc FFI）
 */
public class Term {
    private var rawOn: Bool = false
    private var orig: Array<UInt8>
    // 静态缓存：Stderr.suppress() 前通过 TermSize.prefetch() 设置，
    // 之后 size() 优先返回缓存值（避免 ioctl(STDERR) 失效回退到 80 列）
    private static var cachedRows: Int64 = -1
    private static var cachedCols: Int64 = -1

    public init() {
        this.orig = Array<UInt8>(TERMIOS_SIZE, repeat: 0)
    }

    /**
     * 预缓存终端尺寸（在屏蔽 stderr 前调用）
     */
    public static func prefetch(rows: Int64, cols: Int64): Unit {
        Term.cachedRows = rows
        Term.cachedCols = cols
    }

    public func enableRaw(): Unit {
        if (this.rawOn) {
            return
        }
        unsafe {
            // 读当前属性
            if (let buf <- LibC.malloc<UInt8>(count: TERMIOS_SIZE)) {
                let r = tcgetattr(STDIN, buf)
                if (r != 0) {
                    LibC.free(buf)
                    return
                }
                // 保存原始值
                for (i in 0..TERMIOS_SIZE) {
                    this.orig[i] = buf.read(i)
                }
                // 修改 c_lflag（offset 12）：清 ICANON|ECHO|ISIG|IEXTEN
                var lflag = this.readU32(buf, 12)
                lflag = lflag & !(ICANON | ECHO | ISIG | IEXTEN)
                this.writeU32(buf, 12, lflag)
                // 修改 c_iflag（offset 0）：清 IXON|ICRNL|BRKINT|INPCK|ISTRIP
                var iflag = this.readU32(buf, 0)
                iflag = iflag & !(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
                this.writeU32(buf, 0, iflag)
                // 修改 c_oflag（offset 4）：清 OPOST
                var oflag = this.readU32(buf, 4)
                oflag = oflag & !OPOST
                this.writeU32(buf, 4, oflag)
                // 修改 c_cflag（offset 8）：置 CS8
                var cflag = this.readU32(buf, 8)
                cflag = cflag | CS8
                this.writeU32(buf, 8, cflag)
                // 写回
                tcsetattr(STDIN, TCSAFLUSH, buf)
                LibC.free(buf)
                this.rawOn = true
            }
        }
    }

    public func disableRaw(): Unit {
        if (!this.rawOn) {
            return
        }
        unsafe {
            if (let buf <- LibC.malloc<UInt8>(count: TERMIOS_SIZE)) {
                // 恢复原始值
                for (i in 0..TERMIOS_SIZE) {
                    buf.write(i, this.orig[i])
                }
                tcsetattr(STDIN, TCSAFLUSH, buf)
                LibC.free(buf)
                this.rawOn = false
            }
        }
    }

    public func hasInput(): Bool {
        unsafe {
            if (let tv <- LibC.malloc<UInt8>(count: TIMEVAL_SIZE)) {
                // timeval { tv_sec: 0, tv_usec: 0 } → 非阻塞轮询
                this.writeU64(tv, 0, 0)
                this.writeU64(tv, 8, 0)
                // fd_set 简化：只用 fd 0 的位，fd_set 用 128 字节缓冲
                if (let fds <- LibC.malloc<UInt8>(count: 128)) {
                    for (i in 0..128) {
                        fds.write(i, 0)
                    }
                    // FD_SET(0, fds): 设置 bit 0
                    fds.write(0, 1)
                    let n = select(1, fds, CPointer<UInt8>(), CPointer<UInt8>(), tv)
                    LibC.free(fds)
                    LibC.free(tv)
                    return n > 0
                }
                LibC.free(tv)
            }
            return false
        }
    }

    /**
     * 带超时等待输入（select timeout）。
     * 真实终端/SSH 中转义序列字节可能分批到达：ESC 后跟的字节常在同一
     * 个 select 批次，但网络/PTY 缓冲下可能延迟。等待 timeoutMs 毫秒，
     * 期间有输入返回 true，超时返回 false。
     */
    public func waitInput(timeoutMs: Int64): Bool {
        unsafe {
            if (let tv <- LibC.malloc<UInt8>(count: TIMEVAL_SIZE)) {
                // timeval { tv_sec, tv_usec }
                this.writeU64(tv, 0, UInt64(timeoutMs / 1000))
                this.writeU64(tv, 8, UInt64((timeoutMs % 1000) * 1000))
                if (let fds <- LibC.malloc<UInt8>(count: 128)) {
                    for (i in 0..128) {
                        fds.write(i, 0)
                    }
                    fds.write(0, 1)
                    let n = select(1, fds, CPointer<UInt8>(), CPointer<UInt8>(), tv)
                    LibC.free(fds)
                    LibC.free(tv)
                    return n > 0
                }
                LibC.free(tv)
            }
            return false
        }
    }

    /**
     * 非阻塞读按键；无输入返回 None
     */
    public func readKey(): Option<KeyEvent> {
        if (!this.hasInput()) {
            return None
        }
        unsafe {
            if (let buf <- LibC.malloc<UInt8>(count: 1)) {
                let n = read(STDIN, buf, 1)
                if (n <= 0) {
                    LibC.free(buf)
                    return None
                }
                let ch = Int32(buf.read(0))
                // 多字节 UTF-8（中文等）：按首字节判断长度，读完整字符
                if (ch >= 0xC0 && ch < 0xF8) {
                    var need: Int64 = 0
                    if (ch >= 0xF0) { need = 3 }        // 4 字节
                    else if (ch >= 0xE0) { need = 2 }   // 3 字节
                    else { need = 1 }                   // 2 字节
                    var bytes = Array<UInt8>(need + 1, repeat: 0)
                    bytes[0] = buf.read(0)
                    var got: Int64 = 1
                    while (got <= need) {
                        if (this.waitInput(100)) {
                            if (let b2 <- LibC.malloc<UInt8>(count: 1)) {
                                let n2 = read(STDIN, b2, 1)
                                if (n2 > 0) {
                                    bytes[got] = b2.read(0)
                                    got += 1
                                }
                                LibC.free(b2)
                            }
                        } else {
                            break
                        }
                    }
                    LibC.free(buf)
                    if (got > need) {
                        // 拼完整字符
                        let s = String.fromUtf8(bytes)
                        return Some(KeyEvent(ch, s))
                    }
                    // 不完整：按单字节处理
                    return Some(KeyEvent(ch))
                }
                // ESC 开头：读完整转义序列（方向键/功能键/鼠标 SGR + X10）
                if (ch == 27) {
                    var seq = Rune(27).toString()
                    // 读第一个后续字节；若是 '[' 则按 CSI 序列读到终结字母（0x40..0x7E）
                    if (this.waitInput(100)) {
                        if (let b2 <- LibC.malloc<UInt8>(count: 1)) {
                            let n2 = read(STDIN, b2, 1)
                            if (n2 > 0) {
                                let b = Int32(b2.read(0))
                                seq += Rune(b).toString()
                                if (b == 91 /* '[' */) {
                                    // CSI 序列：先读下一个字节判断类型
                                    //   'M' → X10 鼠标（ESC[M + 3 字节数据）
                                    //   '<' → SGR 鼠标（ESC[<b;x;yM）
                                    //   其他 → 普通 CSI（方向键 ESC[A 等）
                                    var next: Int32 = -1
                                    if (this.waitInput(100)) {
                                        if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                            let n3 = read(STDIN, b3, 1)
                                            if (n3 > 0) {
                                                next = Int32(b3.read(0))
                                                seq += Rune(next).toString()
                                            }
                                            LibC.free(b3)
                                        }
                                    }
                                    if (next == 77 /* 'M' X10 鼠标 */) {
                                        // X10 鼠标协议：ESC[M + 3 字节（按钮+32, x+32, y+32）
                                        // 必须完整消费 3 个数据字节，否则残留被当普通字符输入
                                        var data = Array<UInt8>(3, repeat: 0)
                                        var got: Int64 = 0
                                        var retry: Int64 = 0
                                        // waitInput(30) 已等待输入窗口；重试上限 3（每字节最多等 30ms）
                                        while (got < 3 && retry < 3) {
                                            if (this.waitInput(100)) {
                                                if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                                    let n3 = read(STDIN, b3, 1)
                                                    if (n3 > 0) {
                                                        data[got] = b3.read(0)
                                                        got += 1
                                                        retry = 0
                                                    }
                                                    LibC.free(b3)
                                                }
                                            } else {
                                                retry += 1
                                            }
                                        }
                                        LibC.free(b2)
                                        LibC.free(buf)
                                        if (got == 3) {
                                            // 转成 SGR 形式（ESC[<b;x;yM）复用 KeyEvent 鼠标解析
                                            let btn = Int64(data[0]) - 32
                                            let mx = Int64(data[1]) - 32
                                            let my = Int64(data[2]) - 32
                                            let sgr = "${TermEsc.ESC}[<${btn};${mx};${my}M"
                                            return Some(KeyEvent(ch, sgr))
                                        }
                                        // 数据不完整：按裸 ESC 处理（不输入残留字节）
                                        return Some(KeyEvent(ch))
                                    }
                                    if (next == 60 /* '<' SGR 鼠标 */) {
                                        // SGR：ESC[<b;x;yM 读到终结字母 M/m
                                        var guard: Int64 = 0
                                        while (guard < 64) {
                                            if (this.waitInput(100)) {
                                                if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                                    let n3 = read(STDIN, b3, 1)
                                                    if (n3 > 0) {
                                                        let bb = Int32(b3.read(0))
                                                        seq += Rune(bb).toString()
                                                        LibC.free(b3)
                                                        // 终结符：M（按下）/m（释放）
                                                        if (bb == 77 || bb == 109) {
                                                            break
                                                        }
                                                    } else {
                                                        LibC.free(b3)
                                                        break
                                                    }
                                                } else {
                                                    break
                                                }
                                            } else {
                                                break
                                            }
                                            guard += 1
                                        }
                                    } else {
                                        // 普通 CSI（方向键/功能键）：读到终结字母（0x40..0x7E）
                                        var guard: Int64 = 0
                                        while (guard < 64) {
                                            if (this.waitInput(100)) {
                                                if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                                    let n3 = read(STDIN, b3, 1)
                                                    if (n3 > 0) {
                                                        let bb = Int32(b3.read(0))
                                                        seq += Rune(bb).toString()
                                                        LibC.free(b3)
                                                        // 终结符：ASCII 字母/波浪号/其他可见符
                                                        if (bb >= 0x40 && bb <= 0x7E) {
                                                            break
                                                        }
                                                    } else {
                                                        LibC.free(b3)
                                                        break
                                                    }
                                                } else {
                                                    break
                                                }
                                            } else {
                                                break
                                            }
                                            guard += 1
                                        }
                                    }
                                } else if (b == 77 /* 'M' 裸 X10 鼠标（无 '['） */) {
                                    // X10 鼠标协议：ESC[M + 3 字节（按钮+32, x+32, y+32）
                                    // 不完整读取会残留数据字节被当普通字符输入（滚轮触发字母 bug）
                                    var data = Array<UInt8>(3, repeat: 0)
                                    var got: Int64 = 0
                                    var retry: Int64 = 0
                                    // waitInput(30) 已等待输入窗口；重试上限 3（每字节最多等 30ms）
                                    while (got < 3 && retry < 3) {
                                        if (this.waitInput(100)) {
                                            if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                                let n3 = read(STDIN, b3, 1)
                                                if (n3 > 0) {
                                                    data[got] = b3.read(0)
                                                    got += 1
                                                    retry = 0
                                                }
                                                LibC.free(b3)
                                            }
                                        } else {
                                            retry += 1
                                        }
                                    }
                                    LibC.free(b2)
                                    LibC.free(buf)
                                    if (got == 3) {
                                        // 转成 SGR 形式（ESC[<b;x;yM）复用 KeyEvent 鼠标解析
                                        let btn = Int64(data[0]) - 32
                                        let mx = Int64(data[1]) - 32
                                        let my = Int64(data[2]) - 32
                                        let sgr = "${TermEsc.ESC}[<${btn};${mx};${my}M"
                                        return Some(KeyEvent(ch, sgr))
                                    }
                                    // 数据不完整：按裸 ESC 处理（不输入残留字节）
                                    return Some(KeyEvent(ch))
                                } else if (b == 79 /* 'O' SS3 应用方向键 */) {
                                    // SS3 应用方向键：ESC O + 1 字母（A/B/C/D）。
                                    // xterm 等终端在 alt-screen 下把滚轮映射为 SS3 方向键
                                    // （ESC O A/B 连续多次），必须整组识别，否则残留字母输入
                                    if (this.waitInput(100)) {
                                        if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                            let n3 = read(STDIN, b3, 1)
                                            if (n3 > 0) {
                                                seq += Rune(Int32(b3.read(0))).toString()
                                            }
                                            LibC.free(b3)
                                        }
                                    }
                                } else {
                                    // 其他非 CSI 转义（如 ESC x = Alt+x）：只补读 1 个字符，
                                    // 不再盲目补读 3 字节——否则连续事件（如滚轮）会被混读错位
                                    if (this.waitInput(100)) {
                                        if (let b3 <- LibC.malloc<UInt8>(count: 1)) {
                                            let n3 = read(STDIN, b3, 1)
                                            if (n3 > 0) {
                                                seq += Rune(Int32(b3.read(0))).toString()
                                            }
                                            LibC.free(b3)
                                        }
                                    }
                                }
                            }
                            LibC.free(b2)
                        }
                    }
                    LibC.free(buf)
                    return Some(KeyEvent(ch, seq))
                }
                LibC.free(buf)
                return Some(KeyEvent(ch))
            }
            return None
        }
    }

    /**
     * 检测终端是否支持 UTF-8（查 LANG/LC_ALL/LC_CTYPE）
     * 非 UTF-8 终端（如 GBK/Latin-1）下 UI 应降级为 ASCII
     */
    public func isUtf8(): Bool {
        let lang = TermEnv.getenv("LC_ALL") ?? TermEnv.getenv("LC_CTYPE") ??
            TermEnv.getenv("LANG") ?? "en_US.UTF-8"
        return lang.contains("UTF-8") || lang.contains("utf-8") ||
            lang.contains("UTF8") || lang.contains("utf8")
    }

    public func size(): (Int64, Int64) {
        // 优先返回预缓存尺寸（Stderr.suppress() 前由 TermSize.get() 设置）
        if (Term.cachedRows > 0 && Term.cachedCols > 0) {
            return (Term.cachedRows, Term.cachedCols)
        }
        unsafe {
            // cj_get_winsize：非变参封装，绕过 Cangjie FFI 对变参 ioctl 的支持问题
            if (let rowsBuf <- LibC.malloc<UInt16>(count: 1)) {
                if (let colsBuf <- LibC.malloc<UInt16>(count: 1)) {
                    let fds = [STDIN, STDOUT, STDERR]
                    for (fd in fds) {
                        let r = cj_get_winsize(fd, rowsBuf, colsBuf)
                        if (r == 0) {
                            let rows = Int64(rowsBuf.read(0))
                            let cols = Int64(colsBuf.read(0))
                            if (rows > 0 && cols > 0) {
                                LibC.free(colsBuf)
                                LibC.free(rowsBuf)
                                return (rows, cols)
                            }
                        }
                    }
                    LibC.free(colsBuf)
                }
                LibC.free(rowsBuf)
            }
            // cj_get_winsize 全部失败：用环境变量 COLUMNS/LINES 兜底
            let envCols = TermEnv.getenv("COLUMNS") ?? ""
            let envRows = TermEnv.getenv("LINES") ?? ""
            var cols: Int64 = 80
            var rows: Int64 = 24
            try { cols = Int64.parse(envCols) } catch (e: Exception) { () }
            try { rows = Int64.parse(envRows) } catch (e: Exception) { () }
            if (cols < 1) { cols = 80 }
            if (rows < 1) { rows = 24 }
            return (rows, cols)
        }
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

    // ===== 备用缓冲区 / 鼠标模式便捷封装 =====
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

    // ===== 内存读写辅助 =====
    private func readU32(p: CPointer<UInt8>, offset: Int64): UInt32 {
        unsafe {
            var v: UInt32 = 0
            for (i in 0..4) {
                v = v | (UInt32(p.read(offset + i)) << (i * 8))
            }
            return v
        }
    }

    private func writeU32(p: CPointer<UInt8>, offset: Int64, v: UInt32): Unit {
        unsafe {
            for (i in 0..4) {
                p.write(offset + i, UInt8((v >> (i * 8)) & 0xFF))
            }
        }
    }

    private func readU16(p: CPointer<UInt8>, offset: Int64): UInt16 {
        unsafe {
            var v: UInt16 = 0
            for (i in 0..2) {
                v = v | (UInt16(p.read(offset + i)) << (i * 8))
            }
            return v
        }
    }

    private func writeU64(p: CPointer<UInt8>, offset: Int64, v: UInt64): Unit {
        unsafe {
            for (i in 0..8) {
                p.write(offset + i, UInt8((v >> (i * 8)) & 0xFF))
            }
        }
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
 * stderr 重定向（TUI 全屏模式屏蔽 stderr 污染屏幕）
 */
@C
foreign func open(path: CString, flags: Int32): Int32

@C
foreign func dup2(oldfd: Int32, newfd: Int32): Int32

@C
foreign func close(fd: Int32): Int32

@C
foreign func dup(fd: Int32): Int32

public class Stderr {
    private static var savedFd: Int32 = -1

    /**
     * 屏蔽 stderr（重定向到 /dev/null），返回是否成功
     */
    public static func suppress(): Bool {
        unsafe {
            if (Stderr.savedFd >= 0) {
                return true  // 已屏蔽
            }
            // 保存当前 stderr fd
            let saved = dup(2)
            if (saved < 0) {
                return false
            }
            // 打开 /dev/null
            let devnull = open(LibC.mallocCString("/dev/null"), 1 /* O_WRONLY */)
            if (devnull < 0) {
                close(saved)
                return false
            }
            dup2(devnull, 2)
            close(devnull)
            Stderr.savedFd = saved
            return true
        }
    }

    /**
     * 恢复 stderr
     */
    public static func restore(): Unit {
        unsafe {
            if (Stderr.savedFd >= 0) {
                dup2(Stderr.savedFd, 2)
                close(Stderr.savedFd)
                Stderr.savedFd = -1
            }
        }
    }
}
