package cjterm

import std.collection.*
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
 * 裸流粘贴合并阈值（v1.3.19）：
 * - MIN：输入缓冲积压达到此量即判定为粘贴（单键 < 24 字节，多字节 UTF-8
 *   字符 1 个 ≤ 4 字节，4 字节序列 < 24）
 * - MAX：单次合并上限码点数（超过部分留待后续 readKey 继续吞读，
 *   避免一次吞读阻塞输入循环过久）
 */
private let BULK_PASTE_MIN: Int64 = 48
private let BULK_PASTE_MAX: Int64 = 2000

/**
 * burst 聚合两级窗口（v1.3.21，对齐 atomcode input/reader.rs）：
 * - PENDING：首个候选字符后的首次探测窗口。正常打字有毫秒级人类间隔，
 *   短窗口即过期 → 单键近零延迟（此前每键全跑 ACTIVE 窗口会引入输入延迟）；
 *   非零（而非严格 poll(0)）给分块到达的第一块稍作喘息，避免真粘贴被误判单键
 * - ACTIVE：第 2 个候选字符确认 burst 后的桥接窗口，覆盖 conhost/WT 分块
 *   粘贴记录间 5-12ms 的间隙（Windows 实测口径）
 */
private let BURST_PENDING_MS: Int64 = 4
private let BURST_ACTIVE_MS: Int64 = 15

/**
 * 终端控制器：委托 TerminalBackend 实现平台差异，对外 API 与旧版一致
 */
public class Term {
    private let backend: TerminalBackend
    private var rawOn: Bool = false
    // burst 聚合的延迟重排队：合并判定为"非粘贴"（无换行）时，已吞读的
    // 字符必须按序还给后续 readKey，不得丢弃（对齐 atomcode per-key 重放）
    private var replay: ArrayList<KeyEvent> = ArrayList<KeyEvent>(0)

    public init() {
        this.backend = createTerminalBackend()
    }

    /**
     * 测试注入：替换 backend + 复位 burst 聚合状态。
     * 生产构建走默认 init；此重载仅供单元测试用 mock backend
     * 模拟 Windows 离散按键流（真实 conhost 无法在 CI 里驱动）。
     */
    public init(injected: TerminalBackend) {
        this.backend = injected
    }

    public func enableRaw(): Bool {
        if (this.rawOn) {
            return true
        }
        if (this.backend.enableRaw()) {
            this.rawOn = true
            // 启用 bracketed paste（ESC[?2004h）：终端用 ESC[200~...ESC[201~
            // 包裹粘贴，避免多行粘贴的换行被逐键解析成 Enter 自动提交。
            // 此前不启用因 readBracketedPaste 1.5s 超时吞键——已修复
            // （连续无数据判定结束 + 上限后继续消费闭合标记）
            print(TermEsc.ESC + "[?2004h", flush: true)
            return true
        }
        return false
    }

    public func disableRaw(): Unit {
        // 关闭 bracketed paste（ESC[?2004l）
        print(TermEsc.ESC + "[?2004l", flush: true)
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
     * 读取一个按键事件（阻塞）。无输入返回 None。
     *
     * 裸流粘贴合并（v1.3.19，v1.3.20 修复）：Windows 控制台不支持 bracketed
     * paste，粘贴以离散按键事件涌入——靠 backend 输入缓冲积压量识别：
     * 积压 ≥ 阈值时连续吞读可打印字符（有上限），合并为单个 isPaste 事件。
     *
     * 合并循环内的事件分类（对齐 atomcode input/reader.rs paste_candidate_char
     * 与 bracketed paste 语义——粘贴内容的换行绝不能触发提交）：
     *  - 可打印字符 → 并入粘贴文本
     *  - **Enter（\r，无修饰）→ 视为粘贴内容里的换行并入**（conhost 粘贴的
     *    换行就是裸 Enter 事件；若停合并丢弃，剩余缓冲逐键消费时下一个 \r
     *    会变成真实 Enter 触发提交——v1.3.20 修复的根因）
     *  - 其他控制键（↑↓←→、ESC、Backspace、Ctrl 组合）→ 命令而非粘贴内容，
     *    停止合并并原样返回该键（不丢事件），后续 readKey 继续正常处理
     */
    public func readKey(): Option<KeyEvent> {
        // bracketed paste 后端（POSIX）：backend 自行解析 ESC[200~...ESC[201~，
        // Term 层不得拦截（吞字节会破坏包裹标记）
        if (this.backend.supportsBracketedPaste()) {
            return this.backend.readKey()
        }
        // 重放队（burst 聚合判定为"非粘贴"后按序还回的按键）：严格 FIFO
        // 先于 backend 消费（顺序语义：重放键早于后续 backend 输入到达；
        // 且重放键已分类完毕，不得重新进入 burst 检测）
        if (let Some(k) <- this.replay.get(Int64(0))) {
            this.replay.remove(at: 0)
            return Some(k)
        }
        return this.readRawStreamKey()
    }

    /**
     * 裸流后端（Windows 控制台）单键读取，含两级粘贴检测（v1.3.19 积压合并 +
     * v1.3.21 burst 窗口聚合，对齐 atomcode input/reader.rs）：
     *
     * 1. 积压 ≥ BULK_PASTE_MIN（长粘贴）：一次性吞读合并（原有路径）
     * 2. 单键为粘贴候选字符（可打印/裸 Enter/裸 Tab）：两级窗口聚合
     *    - PENDING（4ms）探测第 2 个候选字符：正常打字有人类间隔即超时，
     *      单键近零延迟返回
     *    - 第 2 个候选确认后切 ACTIVE（15ms）桥接 conhost/WT 分块记录间隙
     *    - 聚合结果满足"粘贴签名"（≥2 字符 + 含换行 + 含非空白 + 防 IME
     *      逐字提交风暴）→ 合并为单个 isPaste 事件（多行换行并入文本，
     *      绝不逐键触发提交）；否则按原键序重放（不丢事件）
     *
     * 两级窗口只作用于裸 Enter/裸 Tab/可打印字符：方向键、Esc、Ctrl 组合、
     * 退格、鼠标等"命令键"直接返回，不受聚合延迟影响。
     */
    private func readRawStreamKey(): Option<KeyEvent> {
        // 输入积压探测（Windows=控制台待读事件数；单键至多 1-2 事件），
        // 超阈值 = 长粘贴，直接吞读合并
        let pending = this.backend.readPendingBytes()
        if (pending >= BULK_PASTE_MIN) {
            return this.readRawStreamPaste()
        }
        // 常规读键；非候选（命令键/无输入）原样返回
        if (!this.backend.hasInput()) {
            return None
        }
        if (let Some(k) <- this.backend.readKey()) {
            if (!this.isPasteCandidate(k)) {
                return Some(k)
            }
            return this.tryAggregateBurst(k)
        }
        return None
    }

    /**
     * 粘贴候选判定（对齐 atomcode paste_candidate_char）：
     * 可打印字符 / 裸 Enter（\r，粘贴内容的换行）/ 裸 Tab → 候选；
     * 方向键、Esc、Ctrl 组合、退格、鼠标等命令键 → 非候选（用户命令，
     * 不并入粘贴，也不引入聚合延迟）
     */
    private func isPasteCandidate(k: KeyEvent): Bool {
        return (k.text.size > 0 && !k.isEsc && !k.isEnter
            && !k.isBackspace && !k.isArrowUp && !k.isArrowDown
            && !k.isArrowLeft && !k.isArrowRight && !k.isMouse && !k.isPaste)
            || (k.isEnter && k.text.size == 1)
            || (k.isTab && k.text.size == 1)
    }

    /**
     * 两级窗口 burst 聚合：首候选字符已读入（firstKey），继续探测后续
     * 候选字符直到窗口超时 / 遇到命令键 / 达到上限。
     */
    private func tryAggregateBurst(firstKey: KeyEvent): Option<KeyEvent> {
        var chars = ArrayList<String>(4)
        var trailing = ArrayList<KeyEvent>(0)
        chars.add(this.candidateChar(firstKey))
        var confirmed: Bool = false
        while (chars.size < BULK_PASTE_MAX) {
            let timeoutMs: Int64 = if (confirmed) { BURST_ACTIVE_MS } else { BURST_PENDING_MS }
            if (!this.backend.waitInput(timeoutMs)) {
                break
            }
            if (!this.backend.hasInput()) {
                break
            }
            let nextOpt = this.backend.readKey()
            if (let Some(n) <- nextOpt) {
                if (n.isPaste) {
                    // 粘贴内混入的 bracketed paste 事件：整段并入
                    chars.add(n.text)
                    confirmed = true
                    continue
                }
                if (this.isPasteCandidate(n)) {
                    chars.add(this.candidateChar(n))
                    confirmed = true
                } else {
                    // 命令键打断 burst：入重放队（不丢事件），停止聚合
                    trailing.add(n)
                    break
                }
            } else {
                break
            }
        }
        if (this.isPasteBurst(chars)) {
            var sb = StringBuilder()
            for (c in chars) {
                sb.append(c)
            }
            // 打断 burst 的命令键已入 trailing：同样还回重放队
            for (t in trailing) {
                this.replay.add(t)
            }
            return Some(KeyEvent(sb.toString()))
        }
        // 非粘贴签名（如快速单行打字）：首键立即原样返回（保留原始
        // KeyEvent），后续已读字符按序入重放队（对齐 atomcode per-key 重放，
        // 不丢事件）
        chars.remove(at: 0)  // chars[0] 即 firstKey，已直接返回
        for (c in chars) {
            this.replay.add(this.reconstructKey(c))
        }
        for (t in trailing) {
            this.replay.add(t)
        }
        return Some(firstKey)
    }

    /**
     * 候选字符的文本表示：裸 Enter → "\r"（InputBox.addPasteLine 归一化
     * CRLF→LF 后并入多行文本）；Tab → "\t"；可打印字符 → 原 text
     */
    private func candidateChar(k: KeyEvent): String {
        if (k.isEnter) {
            return "\r"
        }
        if (k.isTab) {
            return "\t"
        }
        return k.text
    }

    /**
     * 重放重建：聚合字符 → 最小按键事件（无修饰，对齐 atomcode 重放语义）
     */
    private func reconstructKey(c: String): KeyEvent {
        if (c == "\r") {
            return KeyEvent(13)
        }
        if (c == "\t") {
            return KeyEvent(9)
        }
        var first: Int32 = 0
        if (c.size > 0) {
            first = Int32(c.toArray()[0])
        }
        return KeyEvent(first, c)
    }

    /**
     * 粘贴签名判定（对齐 atomcode is_paste_burst 四条件）：
     *  1. ≥2 字符（单键是正常打字）
     *  2. 含换行（"这是多行内容"的无歧义信号；无换行 burst 走逐键路径）
     *  3. 含至少一个非空白字符（排除 tty 队列残留的连续 Enter/Tab）
     *  4. ≥3 行时每行平均 >1 非换行字符（排除 Windows IME 逐字提交风暴
     *     "字↵字↵字" 被误判粘贴）
     */
    private func isPasteBurst(chars: ArrayList<String>): Bool {
        if (chars.size < 2) {
            return false
        }
        var hasEnter: Bool = false
        var hasText: Bool = false
        var newlineCount: Int64 = 0
        for (c in chars) {
            if (c == "\r" || c == "\n") {
                hasEnter = true
                newlineCount += 1
            } else if (this.hasNonBlankRune(c)) {
                hasText = true
            }
        }
        if (!hasEnter || !hasText) {
            return false
        }
        let lineCount = newlineCount + 1
        let nonNewline = Int64(chars.size) - newlineCount
        if (lineCount >= 3 && nonNewline <= lineCount) {
            return false  // 平均每行 ≤1 字符：IME 逐字提交，非粘贴
        }
        return true
    }

    /**
     * 字符串是否含至少一个非空白码点（粘贴签名条件 3）。
     * 不用 trim()：trim 仅去首尾空白，中间空白仍留（"a " → "a"），
     * 但"全空白"字符串判空语义与 is_paste_burst 的 is_whitespace 一致即可。
     */
    private func hasNonBlankRune(s: String): Bool {
        for (r in s.toRuneArray()) {
            let v = Int64(UInt32(r))
            // 空白码点（对齐 atomcode char::is_whitespace 的常见控制/空格集）
            if (v != 32 && v != 9 && v != 10 && v != 13 && v != 12 && v != 11) {
                return true
            }
        }
        return false
    }

    /**
     * 裸流粘贴合并（Windows 控制台回退路径）。
     * 抽出为独立方法便于测试注入（TestTerminalBackend 模拟离散按键流）。
     */
    public func readRawStreamPaste(): Option<KeyEvent> {
        var sb = StringBuilder()
        var count: Int64 = 0
        while (count < BULK_PASTE_MAX) {
            // hasInput 非阻塞守卫：粘贴读完即停，绝不阻塞等下一个键
            if (!this.backend.hasInput()) {
                break
            }
            if (let Some(k) <- this.backend.readKey()) {
                // 粘贴内可能混入的 bracketed paste 事件（部分终端）：整段并入
                if (k.isPaste) {
                    sb.append(k.text)
                    count += k.text.toRuneArray().size
                    continue
                }
                // Enter（\r）：粘贴内容里的换行并入文本（对齐 atomcode
                // paste_candidate_char：无修饰 Enter = '\n' 粘贴内容）。
                // 若停合并丢弃，剩余缓冲逐键消费时下一个 \r 变成真实
                // Enter 触发提交（"粘贴带换行长文本直接发送"根因）。
                if (k.isEnter && k.text.size == 1) {
                    sb.append("\r")
                    count += 1
                    continue
                }
                // 其他控制键（↑↓←→、ESC、Backspace、Ctrl 组合）= 命令，
                // 停止合并；已收部分作为粘贴事件先行返回，该命令键入重放队
                // （不丢事件，下次 readKey 原样还回）。
                if (k.text.size == 0 || k.isBackspace || k.isEsc
                    || k.isArrowUp || k.isArrowDown || k.isArrowLeft || k.isArrowRight) {
                    if (count > 0) {
                        this.replay.add(k)
                        return Some(KeyEvent(sb.toString()))
                    }
                    return Some(k)
                }
                sb.append(k.text)
                count += k.text.toRuneArray().size
            } else {
                break
            }
        }
        if (count > 0) {
            return Some(KeyEvent(sb.toString()))
        }
        // 积压全是控制序列：退回常规读取（上面 while 已逐键读完则 None）
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
