package cjterm

/**
 * POSIX 终端后端（Linux/macOS）：termios 原始模式 + ioctl 尺寸 + select 输入
 *
 * 从 term.cj 原样迁移（行为不变），仅类名改 PosixTerminalBackend 并实现
 * TerminalBackend 接口。readKey 的转义序列解析（CSI/SS3/X10 鼠标/SGR 鼠标/
 * bracketed paste/UTF-8 多字节）是多年踩坑积累，**禁止改动**。
 *
 * @When[os != "Windows"]：Windows 构建不编译本文件（Windows 下链接
 * tcgetattr 等符号会失败）。
 */

import std.time.*

// ===== termios FFI（直接调 libc，无外部 .so 依赖）=====
// Linux termios 结构体布局（x86_64，60 字节）：
//   tcflag_t c_iflag;   // offset 0, 4 bytes
//   tcflag_t c_oflag;   // offset 4
//   tcflag_t c_cflag;   // offset 8
//   tcflag_t c_lflag;   // offset 12
//   cc_t     c_line;    // offset 16
//   cc_t     c_cc[32];  // offset 17..48
//   speed_t  c_ispeed;  // offset 48 (padding)
//   speed_t  c_ospeed;  // offset 52
//   // padding to 60
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
private let STDERR: Int32 = 2

// ioctl TIOCGWINSZ = 0x5413
private let TIOCGWINSZ: UInt64 = 0x5413

// 缓冲区常量
private let TERMIOS_SIZE: Int64 = 60
private let TIMEVAL_SIZE: Int64 = 16

/**
 * POSIX 终端后端：termios 原始模式 + 按键读取 + 尺寸 + stderr 屏蔽
 */
@When[os != "Windows"]
public class PosixTerminalBackend <: TerminalBackend {
    private var orig: Array<UInt8>

    public init() {
        this.orig = Array<UInt8>(TERMIOS_SIZE, repeat: 0)
    }

    public func enableRaw(): Bool {
        unsafe {
            // 读当前属性
            if (let buf <- LibC.malloc<UInt8>(count: TERMIOS_SIZE)) {
                let r = tcgetattr(STDIN, buf)
                if (r != 0) {
                    LibC.free(buf)
                    return false
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
                return true
            }
            return false
        }
    }

    public func disableRaw(): Unit {
        unsafe {
            if (let buf <- LibC.malloc<UInt8>(count: TERMIOS_SIZE)) {
                // 恢复原始值
                for (i in 0..TERMIOS_SIZE) {
                    buf.write(i, this.orig[i])
                }
                tcsetattr(STDIN, TCSAFLUSH, buf)
                LibC.free(buf)
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
                                        // 普通 CSI（方向键/功能键）：读到终结字母（0x40..0x7E）。
                                        // 注意：next 可能已是终结字母（如 ESC[A 的 A）——
                                        // 此时必须立即收尾，不能再进循环多读：
                                        // 连按 ↑（缓冲 ESC[A ESC[A...）时若多读会吞掉
                                        // 下一个序列的 ESC[（'['=0x5B 也在终结范围），
                                        // 序列错位 → 残留字母被当字符输入（实测
                                        // esc="ESC[A ESC[" + 输入框出现 AAAA/BBBB）
                                        var guard: Int64 = 0
                                        while (guard < 64) {
                                            if (next >= 0x40 && next <= 0x7E) {
                                                break  // next 即终结字母（方向键等）
                                            }
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
                    // bracketed paste 开始标记 ESC[200~：整段读取直到 ESC[201~，
                    // 作为单次粘贴事件（内容含换行/转义也不逐键解析）
                    if (seq == TermEsc.ESC + "[200~") {
                        let pasteText = this.readBracketedPaste()
                        LibC.free(buf)
                        return Some(KeyEvent(pasteText))
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
     * 读取 bracketed paste 内容：从 ESC[200~ 后持续读取，直到 ESC[201~ 结束标记。
     *
     * 防御（实测：终端未发闭合标记时会把后续按键吞进粘贴体，方向键变 DDDD 字符）：
     * - 总超时 1.5s + 内容上限 64KB：防未闭合时无限吞后续输入
     * - 返回前剥离 ESC 控制序列：粘贴体只保留纯文本
     */
    private func readBracketedPaste(): String {
        var sb = StringBuilder()
        let term = TermEsc.ESC + "[201~"
        let start = DateTime.now()
        while (true) {
            if (!this.waitInput(200)) {
                break  // 无更多输入：粘贴结束（或未闭合）
            }
            // 总超时：未闭合时防止吞掉后续按键输入
            if ((DateTime.now() - start).toMilliseconds() > 1500) {
                break
            }
            unsafe {
                if (let b <- LibC.malloc<UInt8>(count: 1)) {
                    let n = read(STDIN, b, 1)
                    if (n <= 0) {
                        LibC.free(b)
                        break
                    }
                    sb.append(Rune(Int32(b.read(0))).toString())
                    LibC.free(b)
                }
            }
            // 内容上限：极端大粘贴体强制截断
            if (sb.toString().size > 65536) {
                break
            }
            // 尾部匹配结束标记（可能跨多次 read，用 endsWith 检测）
            let s = sb.toString()
            if (s.endsWith(term)) {
                let cut = s.size - term.size
                if (cut <= 0) {
                    return ""
                }
                return stripEscapeSequences(s[0..cut])
            }
        }
        // 未闭合：去掉可能的尾部残缺结束标记字节，返回剩余（剥离控制序列）
        let s = sb.toString()
        if (s.endsWith(term)) {
            return stripEscapeSequences(s[0..s.size - term.size])
        }
        return stripEscapeSequences(s)
    }

    /**
     * 剥离 ESC 控制序列：粘贴体只保留纯文本（防方向键序列 ESC[D 被吞后
     * 渲染成 D/C 字母、或颜色序列污染字段值）
     */
    private static func stripEscapeSequences(s: String): String {
        var sb = StringBuilder()
        let runes = s.toRuneArray()
        var i: Int64 = 0
        while (i < runes.size) {
            if (UInt32(runes[i]) == 27) {  // ESC：跳过整个序列
                // ESC [ ... 字母（CSI）或 ESC 单字符
                i += 1
                if (i < runes.size && UInt32(runes[i]) == 91) {  // '['
                    i += 1
                    while (i < runes.size) {
                        let v = UInt32(runes[i])
                        i += 1
                        if (v >= 64 && v <= 126) {  // 终结字母
                            break
                        }
                    }
                } else if (i < runes.size) {
                    i += 1  // ESC + 单字符（如 ESC O）
                }
            } else {
                sb.append(String(runes[i]))
                i += 1
            }
        }
        return sb.toString()
    }

    public func size(): (Int64, Int64) {
        unsafe {
            if (let buf <- LibC.malloc<UInt8>(count: 8)) {
                // 清零 buf（避免读到上次调用的残留）
                for (i in 0..8) {
                    buf.write(i, UInt8(0))
                }
                // 依次尝试 STDIN / STDOUT / STDERR
                let fds = [STDIN, STDOUT, STDERR]
                for (fd in fds) {
                    let r = ioctl(fd, TIOCGWINSZ, buf)
                    if (r == 0) {
                        let rows = Int64(this.readU16(buf, 0))
                        let cols = Int64(this.readU16(buf, 2))
                        if (rows > 0 && cols > 0) {
                            LibC.free(buf)
                            return (rows, cols)
                        }
                    }
                }
                LibC.free(buf)
            }
            // ioctl 全部失败：环境变量 COLUMNS/LINES 兜底
            return envSizeFallback()
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

    // ===== stderr 屏蔽（TUI 全屏模式屏蔽 stderr 污染屏幕）=====
    private static var savedFd: Int32 = -1

    public func suppressStderr(): Bool {
        unsafe {
            if (PosixTerminalBackend.savedFd >= 0) {
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
            PosixTerminalBackend.savedFd = saved
            return true
        }
    }

    public func restoreStderr(): Unit {
        unsafe {
            if (PosixTerminalBackend.savedFd >= 0) {
                dup2(PosixTerminalBackend.savedFd, 2)
                close(PosixTerminalBackend.savedFd)
                PosixTerminalBackend.savedFd = -1
            }
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

// ===== stderr 重定向 FFI（POSIX：open/dup2 到 /dev/null）=====
@C
foreign func open(path: CString, flags: Int32): Int32

@C
foreign func dup2(oldfd: Int32, newfd: Int32): Int32

@C
foreign func close(fd: Int32): Int32

@C
foreign func dup(fd: Int32): Int32
