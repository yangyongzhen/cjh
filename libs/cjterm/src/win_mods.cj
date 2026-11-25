package cjterm

/**
 * Win32 控制键状态（KEY_EVENT_RECORD.dwControlKeyState）位掩码与判定。
 *
 * 为什么要独立成文件：判定逻辑必须是**平台无关的纯函数**，否则 Linux 侧的
 * 测试门禁完全覆盖不到（记录→KeyEvent 的映射在 @When[os == "Windows"] 的
 * term_windows.cj 里，Linux 构建不编译）。
 *
 * 位掩码按 Win32 规范（wincon.h）：
 *   RIGHT_ALT_PRESSED  0x0001    LEFT_ALT_PRESSED   0x0002
 *   RIGHT_CTRL_PRESSED 0x0004    LEFT_CTRL_PRESSED  0x0008
 *   SHIFT_PRESSED      0x0010
 *
 * 曾经的错误（v1.3.25 真机日志定性，§3.29）：把 RIGHT_ALT 写成 0x4、
 * RIGHT_CTRL 写成 0x10（那是 SHIFT 位），于是 ctrl 掩码 = 0x8|0x10 把
 * **Shift 当成了 Ctrl** → 粘贴的大写字母被解码成控制码（M→13=CR、J→10=LF），
 * 文本既乱码又会凭空触发提交。
 */

/** 右 Alt 按下 */
public let WIN_RIGHT_ALT_PRESSED: UInt32 = 0x1

/** 左 Alt 按下 */
public let WIN_LEFT_ALT_PRESSED: UInt32 = 0x2

/** 右 Ctrl 按下 */
public let WIN_RIGHT_CTRL_PRESSED: UInt32 = 0x4

/** 左 Ctrl 按下 */
public let WIN_LEFT_CTRL_PRESSED: UInt32 = 0x8

/** Shift 按下（与左右 Ctrl 都不是同一位） */
public let WIN_SHIFT_PRESSED: UInt32 = 0x10

/** 是否按住 Ctrl（**只认左右 Ctrl**，Shift 不算） */
public func winCtrlPressed(state: UInt32): Bool {
    return (state & (WIN_LEFT_CTRL_PRESSED | WIN_RIGHT_CTRL_PRESSED)) != 0
}

/** 是否按住 Alt（**只认左右 Alt**） */
public func winAltPressed(state: UInt32): Bool {
    return (state & (WIN_LEFT_ALT_PRESSED | WIN_RIGHT_ALT_PRESSED)) != 0
}

/** 是否按住 Shift */
public func winShiftPressed(state: UInt32): Bool {
    return (state & WIN_SHIFT_PRESSED) != 0
}

/** Win32 VK_RETURN（主键盘/小键盘回车共用） */
public let WIN_VK_RETURN: UInt16 = 0x0D

/**
 * 是否为 Ctrl+Enter。
 *
 * 为什么要单独有 Ctrl+Enter：Windows Terminal 与 conhost 都把 Alt+Enter
 * 绑定为“切换全屏”，按键在终端层被消费，进程收到的 KeyEvent 流里根本
 * 没有这一下——cjh 的“忙时 Alt+Enter 中断并立即发送”在 Windows 上永远
 * 触发不了。Ctrl+Enter 未被 Windows Terminal 默认绑定（默认仅
 * alt+enter / f11 切全屏），系统控制台原始输入也能拿到 CTRL+RETURN，
 * 因此作为 Windows 上的等价按键，映射成与 POSIX Alt+Enter 相同的
 * ESC+CR 序列，复用 TUI 既有分支。
 */
public func winIsCtrlEnter(state: UInt32, vk: UInt16): Bool {
    return winCtrlPressed(state) && vk == WIN_VK_RETURN
}
