package cjterm

/**
 * Windows 终端后端（Windows 10 1809+ / Windows Terminal / ConPTY）：
 * VT 输出 + Win32 Console API 输入
 *
 * 设计：
 *   - 输出（渲染）：SetConsoleMode 开启 ENABLE_VIRTUAL_TERMINAL_PROCESSING，
 *     现有 ANSI/VT 转义序列直接工作（差分渲染层零改动）
 *   - 输入（原始模式 + 按键）：SetConsoleMode 清 ENABLE_LINE_INPUT/ECHO/
 *     PROCESSED_INPUT（等价 POSIX raw），ReadConsoleInputW 读 KEY_EVENT_RECORD
 *     映射为与 POSIX 完全一致的 KeyEvent 语义
 *   - 尺寸：GetConsoleScreenBufferInfo → srWindow
 *   - UTF-8：GetConsoleOutputCP() == 65001（配合 chcp 65001）
 *   - stderr 屏蔽：重定向到 NUL 设备（等价 POSIX /dev/null）
 *
 * 依赖仅 kernel32.dll（Windows 系统自带，等价 POSIX 的 libc），
 * 保持"单二进制零依赖"卖点。@When[os == "Windows"]：Linux/macOS 构建
 * 不编译本文件（Windows 下链接 kernel32 符号，其他平台无此库）。
 *
 * 结构体布局（MSDN，x64）：
 *   CONSOLE_SCREEN_BUFFER_INFO：COORD dwSize(4) + COORD dwCursorPosition(4)
 *     + WORD wAttributes(2) + SMALL_RECT srWindow(8) + COORD dwMaximumWindowSize(4) = 22 字节
 *   COORD：SHORT X(2) + SHORT Y(2) = 4
 *   SMALL_RECT：SHORT Left/Top/Right/Bottom(8) = 8
 *   INPUT_RECORD：WORD EventType(2) + WORD pad(2) + 联合体(16) = 20 字节
 *   KEY_EVENT_RECORD：BOOL bKeyDown(4) + WORD wRepeatCount(2)
 *     + WORD wVirtualKeyCode(2) + WORD wVirtualScanCode(2)
 *     + WCHAR uChar(2) + DWORD dwControlKeyState(4) = 16 字节
 */

// ===== 句柄 =====
private let STD_INPUT_HANDLE: Int32 = -10
private let STD_OUTPUT_HANDLE: Int32 = -11
private let STD_ERROR_HANDLE: Int32 = -12
// INVALID_HANDLE_VALUE = -1

// ===== 控制台模式标志 =====
private let ENABLE_PROCESSED_INPUT: UInt32 = 0x1
private let ENABLE_LINE_INPUT: UInt32 = 0x2
private let ENABLE_ECHO_INPUT: UInt32 = 0x4
private let ENABLE_WINDOW_INPUT: UInt32 = 0x8
// 输出 VT 模式（Windows 10 1809+）
private let ENABLE_VIRTUAL_TERMINAL_PROCESSING: UInt32 = 0x4
// raw 模式需清除的标志（对齐 POSIX 清 ICANON|ECHO|ISIG|IXON）
private let RAW_CLEAR_INPUT: UInt32 = ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT

// ===== 输入事件类型 =====
private let KEY_EVENT: UInt16 = 0x1
private let MOUSE_EVENT: UInt16 = 0x2
private let WINDOW_BUFFER_SIZE_EVENT: UInt16 = 0x4
private let MENU_EVENT: UInt16 = 0x8
private let FOCUS_EVENT: UInt16 = 0x10

// ===== 虚拟键码 =====
private let VK_BACK: UInt16 = 0x08
private let VK_TAB: UInt16 = 0x09
private let VK_RETURN: UInt16 = 0x0D
private let VK_ESCAPE: UInt16 = 0x1B
private let VK_PRIOR: UInt16 = 0x21  // PageUp
private let VK_NEXT: UInt16 = 0x22   // PageDown
private let VK_END: UInt16 = 0x23
private let VK_HOME: UInt16 = 0x24
private let VK_LEFT: UInt16 = 0x25
private let VK_UP: UInt16 = 0x26
private let VK_RIGHT: UInt16 = 0x27
private let VK_DOWN: UInt16 = 0x28
private let VK_DELETE: UInt16 = 0x2E

// ===== dwControlKeyState =====
private let LEFT_ALT_PRESSED: UInt32 = 0x2
private let RIGHT_ALT_PRESSED: UInt32 = 0x4
private let LEFT_CTRL_PRESSED: UInt32 = 0x8
private let RIGHT_CTRL_PRESSED: UInt32 = 0x10
private let SHIFT_PRESSED: UInt32 = 0x10  // 与 RIGHT_CTRL 同值（Win32 历史怪癖）

// ===== CreateFileW 参数 =====
private let GENERIC_WRITE: UInt32 = 0x40000000
private let FILE_SHARE_WRITE: UInt32 = 0x2
private let OPEN_EXISTING: UInt32 = 3

// ===== WaitForSingleObject =====
private let WAIT_OBJECT_0: UInt32 = 0
private let WAIT_TIMEOUT: UInt32 = 0x102

// ===== Win32 API（kernel32.dll，Windows 系统自带）=====
@When[os == "Windows"]
@C
foreign func GetStdHandle(nStdHandle: Int32): CPointer<UInt8>

@When[os == "Windows"]
@C
foreign func GetConsoleMode(hConsole: CPointer<UInt8>, lpMode: CPointer<UInt8>): Bool

@When[os == "Windows"]
@C
foreign func SetConsoleMode(hConsole: CPointer<UInt8>, dwMode: UInt32): Bool

@When[os == "Windows"]
@C
foreign func GetNumberOfConsoleInputEvents(hConsole: CPointer<UInt8>, lpCount: CPointer<UInt8>): Bool

@When[os == "Windows"]
@C
foreign func WaitForSingleObject(hHandle: CPointer<UInt8>, dwMilliseconds: UInt32): UInt32

@When[os == "Windows"]
@C
foreign func ReadConsoleInputW(hConsole: CPointer<UInt8>, lpBuffer: CPointer<UInt8>, nLength: UInt32, lpNumberOfEventsRead: CPointer<UInt8>): Bool

@When[os == "Windows"]
@C
foreign func GetConsoleScreenBufferInfo(hConsole: CPointer<UInt8>, lpInfo: CPointer<UInt8>): Bool

@When[os == "Windows"]
@C
foreign func GetConsoleOutputCP(): UInt32

@When[os == "Windows"]
@C
foreign func SetStdHandle(nStdHandle: Int32, hHandle: CPointer<UInt8>): Bool

@When[os == "Windows"]
@C
foreign func CreateFileW(lpFileName: CPointer<UInt16>, dwDesiredAccess: UInt32, dwShareMode: UInt32, lpSecurityAttributes: CPointer<UInt8>, dwCreationDisposition: UInt32, dwFlagsAndAttributes: UInt32, hTemplateFile: CPointer<UInt8>): CPointer<UInt8>

@When[os == "Windows"]
@C
foreign func CloseHandle(hObject: CPointer<UInt8>): Bool

/**
 * Windows 终端后端：VT 输出 + Win32 输入
 */
@When[os == "Windows"]
public class WindowsTerminalBackend <: TerminalBackend {
    private let inHandle: CPointer<UInt8>
    private let outHandle: CPointer<UInt8>
    private var savedInMode: UInt32 = 0
    private var rawOn: Bool = false
    private var savedErrHandle: CPointer<UInt8> = CPointer<UInt8>()
    private var errRedirected: Bool = false

    public init() {
        unsafe {
            this.inHandle = GetStdHandle(STD_INPUT_HANDLE)
            this.outHandle = GetStdHandle(STD_OUTPUT_HANDLE)
        }
    }

    // ===== 原始模式 =====

    public func enableRaw(): Bool {
        if (this.rawOn) {
            return true
        }
        unsafe {
            // 输入：清行缓冲/回显/进程处理（等价 POSIX raw）
            if (let modeBuf <- LibC.malloc<UInt8>(count: 4)) {
                if (GetConsoleMode(this.inHandle, modeBuf) == false) {
                    LibC.free(modeBuf)
                    return false
                }
                this.savedInMode = this.readU32(modeBuf, 0)
                if (SetConsoleMode(this.inHandle, this.savedInMode & !RAW_CLEAR_INPUT) == false) {
                    LibC.free(modeBuf)
                    return false
                }
                LibC.free(modeBuf)
            } else {
                return false
            }
            // 输出：开启 VT 处理（Windows 10 1809+；旧 conhost 失败则返回 false
            // 由上层明确报错，不静默降级）
            if (let outModeBuf <- LibC.malloc<UInt8>(count: 4)) {
                if (GetConsoleMode(this.outHandle, outModeBuf)) {
                    let outMode = this.readU32(outModeBuf, 0)
                    SetConsoleMode(this.outHandle, outMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)
                }
                LibC.free(outModeBuf)
            }
            this.rawOn = true
            return true
        }
    }

    public func disableRaw(): Unit {
        if (!this.rawOn) {
            return
        }
        unsafe {
            SetConsoleMode(this.inHandle, this.savedInMode)
        }
        this.rawOn = false
    }

    // ===== 输入探测 =====

    public func hasInput(): Bool {
        unsafe {
            if (let countBuf <- LibC.malloc<UInt8>(count: 4)) {
                if (GetNumberOfConsoleInputEvents(this.inHandle, countBuf) == false) {
                    LibC.free(countBuf)
                    return false
                }
                let count = this.readU32(countBuf, 0)
                LibC.free(countBuf)
                return count > 0
            }
            return false
        }
    }

    /**
     * 带超时等待输入：控制台输入句柄在输入缓冲非空时 signal（等价 POSIX select）
     */
    public func waitInput(timeoutMs: Int64): Bool {
        unsafe {
            let t = if (timeoutMs < 0) { UInt32(0xFFFFFFFF) } else { UInt32(timeoutMs) }
            let r = WaitForSingleObject(this.inHandle, t)
            return r == WAIT_OBJECT_0
        }
    }

    // ===== 按键读取 =====

    /**
     * 读一个输入事件并映射为 KeyEvent（语义与 POSIX 完全一致：
     * 可打印字符 → text；方向键/功能键 → 转义序列等价；Ctrl 组合 → 控制字符）
     */
    public func readKey(): Option<KeyEvent> {
        if (!this.hasInput()) {
            return None
        }
        unsafe {
            // INPUT_RECORD 20 字节：EventType(2) + pad(2) + 联合体(16)
            if (let rec <- LibC.malloc<UInt8>(count: 20)) {
                if (let readBuf <- LibC.malloc<UInt8>(count: 4)) {
                    if (ReadConsoleInputW(this.inHandle, rec, 1, readBuf) == false || this.readU32(readBuf, 0) == 0) {
                        LibC.free(readBuf)
                        LibC.free(rec)
                        return None
                    }
                    LibC.free(readBuf)
                } else {
                    LibC.free(rec)
                    return None
                }
                // EventType = offset 0（小端 UInt16）
                let eventType = this.readU16(rec, 0)
                // 非按键事件（鼠标/窗口尺寸/菜单/焦点）：跳过（TUI 用 VT 鼠标转义，
                // 不消费窗口事件——resize 由 GetConsoleScreenBufferInfo 感知）
                if (eventType != KEY_EVENT) {
                    LibC.free(rec)
                    return None
                }
                // KEY_EVENT_RECORD 布局（联合体 offset 4 起）：
                //   bKeyDown(4) + wRepeatCount(2) + wVirtualKeyCode(2)
                //   + wVirtualScanCode(2) + uChar(2) + dwControlKeyState(4)
                let keyDown = this.readU32(rec, 4) != 0
                let vk = this.readU16(rec, 10)
                let ch = this.readU16(rec, 14)          // uChar（UTF-16 单元）
                let ctrlState = this.readU32(rec, 16)
                LibC.free(rec)
                if (!keyDown) {
                    return None  // 只处理按下事件（重复按键由 wRepeatCount 分发）
                }
                let ctrl = (ctrlState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0
                let alt = (ctrlState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0
                // Ctrl 组合 → 控制字符（对齐 POSIX raw 模式 ISIG 关闭后的字节语义）
                if (ctrl) {
                    if (vk == 0x43 /* VK_C */) { return Some(KeyEvent(Int32(3))) }    // Ctrl+C
                    if (vk == 0x55 /* VK_U */) { return Some(KeyEvent(Int32(21))) }   // Ctrl+U
                    if (vk == 0x44 /* VK_D */) { return Some(KeyEvent(Int32(4))) }    // Ctrl+D
                    if (vk == 0x5A /* VK_Z */) { return Some(KeyEvent(Int32(26))) }   // Ctrl+Z
                    // 其他 Ctrl+字母：1..26（对齐 POSIX 控制字符）
                    if (vk >= 0x41 && vk <= 0x5A) { return Some(KeyEvent(Int32(vk) - 64)) }
                }
                // Alt 组合：ESC + 字符（对齐 POSIX Alt+x = ESC x）
                if (alt && ch != 0) {
                    let text = this.utf16ToUtf8(ch)
                    return Some(KeyEvent(27, TermEsc.ESC + text))
                }
                // 可打印字符事件（优先：保证字母/数字输入不受 vk 解析影响——
                // vk 偏移待 rec dump 确认，此前 VK 优先曾导致所有键被当方向键）
                if (ch != 0) {
                    let text = this.utf16ToUtf8(ch)
                    // 对齐 POSIX：ch 取 UTF-8 首字节，text 为完整字符
                    var first: Int32 = 0
                    if (text.size > 0) { first = Int32(text.toArray()[0]) }
                    return Some(KeyEvent(first, text))
                }
                // 虚拟键（无字符）：映射为与 POSIX 转义序列等价的 KeyEvent
                return this.vkToKeyEvent(vk)
            }
            return None
        }
    }

    /**
     * 虚拟键 → KeyEvent（转义序列语义与 POSIX 一致）。
     * 用 if-else 而非 match：交叉编译下 match 对 UInt16 常量比较
     * 出现异常（实测 rec vk=38/40 正确但结果全为 LEFT）——if-else
     * 显式比较排除编译器路径差异。
     */
    private func vkToKeyEvent(vk: UInt16): Option<KeyEvent> {
        var seq: String = ""
        var consume: Bool = true
        if (vk == VK_LEFT) { seq = TermEsc.LEFT }
        else if (vk == VK_RIGHT) { seq = TermEsc.RIGHT }
        else if (vk == VK_UP) { seq = TermEsc.UP }
        else if (vk == VK_DOWN) { seq = TermEsc.DOWN }
        else if (vk == VK_PRIOR) { seq = TermEsc.PGUP }
        else if (vk == VK_NEXT) { seq = TermEsc.PGDN }
        else if (vk == VK_HOME) { seq = TermEsc.ESC + "[H" }
        else if (vk == VK_END) { seq = TermEsc.ESC + "[F" }
        else if (vk == VK_DELETE) { seq = TermEsc.ESC + "[3~" }
        else if (vk == VK_BACK) { return Some(KeyEvent(127)) }
        else if (vk == VK_TAB) { return Some(KeyEvent(9)) }
        else if (vk == VK_RETURN) { return Some(KeyEvent(13)) }
        else if (vk == VK_ESCAPE) { return Some(KeyEvent(27)) }
        else { consume = false }
        if (consume) {
            return Some(KeyEvent(27, seq))
        }
        return None
    }

    /**
     * UTF-16 单元 → UTF-8 字符串（处理代理对：高代理 0xD800-0xDBFF 需后续低代理）
     * 注：代理对需跨事件缓冲读取，P1 单单元（BMP 字符含中文）足够；
     * 补充面（emoji）P2 打磨。此处遇高代理返回替换符避免乱码。
     */
    private func utf16ToUtf8(codeUnit: UInt16): String {
        if (codeUnit >= 0xD800 && codeUnit <= 0xDFFF) {
            return "\u{FFFD}"  // 代理对：P1 不拼接，返回替换符
        }
        // UInt16 → 码点 → Rune → String
        return Rune(Int32(codeUnit)).toString()
    }

    // ===== 尺寸 =====

    public func size(): (Int64, Int64) {
        unsafe {
            // CONSOLE_SCREEN_BUFFER_INFO 22 字节
            if (let info <- LibC.malloc<UInt8>(count: 22)) {
                if (GetConsoleScreenBufferInfo(this.outHandle, info)) {
                    // srWindow 在 offset 10：Left(2) Top(2) Right(2) Bottom(2)
                    let left = this.readI16(info, 10)
                    let top = this.readI16(info, 12)
                    let right = this.readI16(info, 14)
                    let bottom = this.readI16(info, 16)
                    LibC.free(info)
                    let rows = Int64(bottom - top + 1)
                    let cols = Int64(right - left + 1)
                    if (rows > 0 && cols > 0) {
                        return (rows, cols)
                    }
                } else {
                    LibC.free(info)
                }
            }
            return envSizeFallback()
        }
    }

    // ===== UTF-8 检测 =====

    /**
     * 终端是否 UTF-8：代码页 65001（配合 chcp 65001）
     */
    public func isUtf8(): Bool {
        unsafe {
            return GetConsoleOutputCP() == 65001
        }
    }

    // ===== stderr 屏蔽（重定向 NUL，等价 POSIX /dev/null）=====

    public func suppressStderr(): Bool {
        unsafe {
            if (this.errRedirected) {
                return true
            }
            // 打开 NUL 设备（Windows 等价 /dev/null）
            let nul = LibC.malloc<UInt16>(count: 4)
            if (nul.isNull()) {
                return false
            }
            nul.write(0, UInt16(78))   // N
            nul.write(1, UInt16(85))   // U
            nul.write(2, UInt16(76))   // L
            nul.write(3, UInt16(0))    // \0
            let hNul = CreateFileW(CPointer(nul), GENERIC_WRITE, FILE_SHARE_WRITE,
                CPointer<UInt8>(), OPEN_EXISTING, 0, CPointer<UInt8>())
            LibC.free(nul)
            if (hNul.isNull()) {
                return false
            }
            this.savedErrHandle = GetStdHandle(STD_ERROR_HANDLE)
            if (SetStdHandle(STD_ERROR_HANDLE, hNul) == false) {
                CloseHandle(hNul)
                return false
            }
            this.errRedirected = true
            return true
        }
    }

    public func restoreStderr(): Unit {
        unsafe {
            if (this.errRedirected) {
                SetStdHandle(STD_ERROR_HANDLE, this.savedErrHandle)
                this.errRedirected = false
            }
        }
    }

    // ===== 内存读写辅助（小端）=====
    private func readU16(p: CPointer<UInt8>, offset: Int64): UInt16 {
        unsafe {
            var v: UInt16 = 0
            for (i in 0..2) {
                v = v | (UInt16(p.read(offset + i)) << (i * 8))
            }
            return v
        }
    }

    private func readI16(p: CPointer<UInt8>, offset: Int64): Int16 {
        unsafe {
            var v: UInt16 = 0
            for (i in 0..2) {
                v = v | (UInt16(p.read(offset + i)) << (i * 8))
            }
            return Int16(v)  // 符号位由 Int16 解释
        }
    }

    private func readU32(p: CPointer<UInt8>, offset: Int64): UInt32 {
        unsafe {
            var v: UInt32 = 0
            for (i in 0..4) {
                v = v | (UInt32(p.read(offset + i)) << (i * 8))
            }
            return v
        }
    }
}
