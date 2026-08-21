package cjterm

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
    public let isArrowUp: Bool
    public let isArrowDown: Bool
    public let isArrowLeft: Bool
    public let isArrowRight: Bool
    public let isPageUp: Bool
    public let isPageDown: Bool
    public let isCtrlU: Bool
    public let isCtrlD: Bool
    public let escapeSeq: String   // 完整转义序列（如 ESC[A）；普通键为空

    public init(ch: Int32) {
        this.ch = ch
        this.isEsc = (ch == 27)
        this.isEnter = (ch == 13 || ch == 10)
        this.isCtrlC = (ch == 3)
        this.isBackspace = (ch == 127 || ch == 8)
        this.isArrowUp = false
        this.isArrowDown = false
        this.isArrowLeft = false
        this.isArrowRight = false
        this.isPageUp = false
        this.isPageDown = false
        this.isCtrlU = (ch == 21)
        this.isCtrlD = (ch == 4)
        this.escapeSeq = ""
    }

    public init(ch: Int32, escapeSeq: String) {
        this.ch = ch
        this.isEsc = (ch == 27)
        this.isEnter = false
        this.isCtrlC = false
        this.isBackspace = false
        this.isArrowUp = (escapeSeq == TermEsc.UP)
        this.isArrowDown = (escapeSeq == TermEsc.DOWN)
        this.isArrowRight = (escapeSeq == TermEsc.RIGHT)
        this.isArrowLeft = (escapeSeq == TermEsc.LEFT)
        this.isPageUp = (escapeSeq == TermEsc.PGUP)
        this.isPageDown = (escapeSeq == TermEsc.PGDN)
        this.isCtrlU = false
        this.isCtrlD = false
        this.escapeSeq = escapeSeq
    }
}

/**
 * 终端控制器：原始模式管理 + 按键读取 + 尺寸（纯 libc FFI）
 */
public class Term {
    private var rawOn: Bool = false
    private var orig: Array<UInt8>

    public init() {
        this.orig = Array<UInt8>(TERMIOS_SIZE, repeat: 0)
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
                // ESC 开头：尝试读完整转义序列（方向键/功能键）
                if (ch == 27) {
                    var seq = Rune(27).toString()
                    // 最多读 4 个后续字节（CSI 序列通常 ESC [ <n> <char>）
                    for (i in 0..4) {
                        if (this.hasInput()) {
                            if (let b2 <- LibC.malloc<UInt8>(count: 1)) {
                                let n2 = read(STDIN, b2, 1)
                                if (n2 > 0) {
                                    let b = Int32(b2.read(0))
                                    seq += Rune(b).toString()
                                }
                                LibC.free(b2)
                            }
                        } else {
                            break
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
        unsafe {
            if (let buf <- LibC.malloc<UInt8>(count: 8)) {
                // winsize { ws_row: UInt16, ws_col: UInt16, ws_xpixel, ws_ypixel }
                let r = ioctl(STDOUT, TIOCGWINSZ, buf)
                if (r == 0) {
                    let rows = Int64(this.readU16(buf, 0))
                    let cols = Int64(this.readU16(buf, 2))
                    LibC.free(buf)
                    if (rows > 0 && cols > 0) {
                        return (rows, cols)
                    }
                    return (24, 80)
                }
                LibC.free(buf)
            }
            return (24, 80)
        }
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

class TermEnv {
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
    public static let UP: String = ESC + "[A"
    public static let DOWN: String = ESC + "[B"
    public static let RIGHT: String = ESC + "[C"
    public static let LEFT: String = ESC + "[D"
    public static let PGUP: String = ESC + "[5~"
    public static let PGDN: String = ESC + "[6~"
}
