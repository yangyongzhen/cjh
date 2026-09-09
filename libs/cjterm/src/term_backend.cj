package cjterm

import std.convert.Parsable

/**
 * 终端后端抽象：跨平台终端层（V1.4）
 *
 * 设计：输出侧（ANSI/VT 转义 + 差分渲染）本就跨平台（Windows 10 1809+
 * 控制台与 Windows Terminal 原生支持 VT 序列）；平台差异集中在输入侧
 * （原始模式/按键读取/尺寸查询/stderr 屏蔽）。本接口剥离平台相关实现，
 * Term 类对外 API 不变，TUI 上层零改动。
 *
 * 平台实现：
 *   - PosixTerminalBackend（term_posix.cj）：termios/ioctl/select，Linux/macOS
 *   - WindowsTerminalBackend（term_windows.cj）：Win32 Console API（VT 输出 + 事件输入）
 *
 * 条件编译：仓颉内置 os 条件（编译期自动注入目标平台，无需 --cfg），
 * 编译期选定实现，零运行时探测开销。
 */

/**
 * 终端后端接口：与 Term 现有功能一一对应
 */
public interface TerminalBackend {
    /**
     * 进入原始模式（关闭行缓冲/回显/信号键，逐键读取）。
     * 返回是否成功；重复调用应幂等（上层 Term 已做 rawOn 去重）。
     */
    func enableRaw(): Bool

    /**
     * 退出原始模式，恢复终端原始设置
     */
    func disableRaw(): Unit

    /**
     * 非阻塞探测是否有输入
     */
    func hasInput(): Bool

    /**
     * 输入缓冲区积压量（POSIX: FIONREAD 待读字节；Windows: 待读事件数）。
     * 供 Term 层做"裸流粘贴"回退：大批量输入事件一次性到达（缓冲积压
     * 远超单键）是粘贴的特征——Windows 控制台不支持 bracketed paste，
     * 粘贴以离散按键流入，靠积压量识别后合并为单次粘贴事件。
     */
    func readPendingBytes(): Int64

    /**
     * 后端是否原生支持 bracketed paste（终端以 ESC[200~...ESC[201~
     * 包裹粘贴，backend 解析为单个 isPaste 事件）。
     * 支持的后端（POSIX）由 backend 自行解析，Term 层不得做裸流合并
     * （会抢先吞掉包裹标记）；不支持的后端（Windows 控制台）由 Term
     * 层按积压量合并离散按键。
     */
    func supportsBracketedPaste(): Bool

    /**
     * 带超时等待输入；期间有输入返回 true，超时返回 false
     */
    func waitInput(timeoutMs: Int64): Bool

    /**
     * 读取一个按键事件（平台无关 KeyEvent 语义）
     */
    func readKey(): Option<KeyEvent>

    /**
     * 终端尺寸（行, 列）
     */
    func size(): (Int64, Int64)

    /**
     * 终端是否支持 UTF-8（非 UTF-8 下 UI 降级 ASCII）
     */
    func isUtf8(): Bool

    /**
     * 屏蔽 stderr（TUI 全屏防污染），返回是否成功
     */
    func suppressStderr(): Bool

    /**
     * 恢复 stderr
     */
    func restoreStderr(): Unit
}

/**
 * 尺寸 env 兜底（COLUMNS/LINES），平台无关，供各后端 size() 使用
 */
internal func envSizeFallback(): (Int64, Int64) {
    var cols: Int64 = 80
    var rows: Int64 = 24
    try { cols = Int64.parse(TermEnv.getenv("COLUMNS") ?? "") } catch (e: Exception) { () }
    try { rows = Int64.parse(TermEnv.getenv("LINES") ?? "") } catch (e: Exception) { () }
    if (cols < 1) { cols = 80 }
    if (rows < 1) { rows = 24 }
    return (rows, cols)
}

/**
 * 创建平台对应的终端后端（编译期条件编译，二选一）
 */
@When[os == "Windows"]
public func createTerminalBackend(): TerminalBackend {
    return WindowsTerminalBackend()
}

@When[os != "Windows"]
public func createTerminalBackend(): TerminalBackend {
    return PosixTerminalBackend()
}
