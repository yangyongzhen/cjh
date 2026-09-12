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
        // 仅可打印字符带 text；Enter/Tab 保留（粘贴候选判定依赖 text.size == 1），
        // 其余控制字节（0x0F=Ctrl+O、0x1A=Ctrl+Z 等）text 置空——否则会经
        // InputBox/Editor 可打印分支（只判 !isEsc && !isEnter && !isBackspace）
        // 漏进输入框：真机 Windows Ctrl+O、POSIX raw 模式同一路径（v1.3.28）
        this.text = if (ch >= 32 && ch != 127) {
            Rune(ch).toString()
        } else if (ch == 13 || ch == 10 || ch == 9) {
            Rune(ch).toString()
        } else {
            ""
        }
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
        // 若是转义序列则 text 为空（非输入字符）；否则为输入字符。
        // isLoneControlText 兜底：Windows Ctrl+数字等经 uChar 带出的控制字符
        // （term_windows.cj 的 ch != 0 分支）不得当可打印 text（v1.3.28）
        this.escapeSeq = if (seq.startsWith(TermEsc.ESC)) { seq } else { "" }
        this.text = if (seq.startsWith(TermEsc.ESC) || isLoneControlText(seq)) { "" } else { seq }
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
 * 裸流粘贴单次 drain 循环的硬迭代预算（v1.3.26）：
 * drain 现在把 readKey() 返回 None（后端消费了一条记录但不上报）也当"已消费"
 * 继续读——真机 Windows 控制台一次粘贴会混入大量 bKeyDown=false 的抬键记录
 * （hasInput 取自记录总数、readKey 只认按下，二者可同时成立），必须在同一
 * readKey() 里全部跳过，否则每次只吃 1~3 条、粘贴逐字爬行（414 字符实测 6.6s）。
 * 取值 4096 的理由：
 *  - 覆盖量级：Windows 控制台输入缓冲上限约 64KB，单条 INPUT_RECORD 约 16~20
 *    字节 → 一次粘贴的记录总数（含抬键）约数千条；4096 足以吃干一整帧。
 *  - 终止兜底：即使后端 hasInput() 恒真却反复返 None 而**不消费**记录（病态/
 *    异常后端），计数器每轮必增，循环最迟在 4096 轮后退出 → 绝不死循环。
 */
private let MAX_DRAIN_RECORDS: Int64 = 4096

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
 * 粘贴补发 Enter 守护（v1.3.23，Windows 分块投递实测修复）：
 * conhost 把一次粘贴拆成多"波"写入输入缓冲，剪贴板末尾换行常单独成一波
 * （波间 5~60ms，超出上面的 4/15ms 窗口）——该波只含 1 个候选字符，
 * 判不出粘贴签名，旧实现原样返回裸 Enter，InputBox 立即提交（用户并未按回车）。
 *
 * 判据改为"上下文"而非"单键"：处于粘贴流（GUIARD_MS 窗口内）时紧随的
 * 裸 Enter 是终端为粘贴补发的换行 → 吞掉，绝不提交。
 * 窗口取 200ms：人手从 Ctrl+V 移到 Enter 通常 ≥300ms，故不长期吞真实 Enter；
 * 即便极端手速命中，最坏结果是需再按一次 Enter（不丢内容、不误发）。
 */
private let PASTE_ENTER_GUARD_MS: Int64 = 200

/**
 * 认定"正在粘贴流"的成串输入密度阈值（非换行候选字符数）：
 * 人类打字受键程/输入法编码限制，不可能在 4/15ms 窗口内凑齐 8 个字符，
 * 故该密度只对机器成串投递（粘贴）成立。
 * 用途：波界恰好落在换行前时（前半段无换行、换行单独成波），单靠"已发出
 * 粘贴事件"标记会漏掉该波，需靠密度提前置位守护。
 */
private let PASTE_STREAM_MIN_CHARS: Int64 = 8

/**
 * 粘贴流"到达速率"判据（v1.3.24）：窗口内非换行候选到达数下限，以及换行占比
 * 要求（换行数 × DIV 必须小于字符数）。
 *
 * 动机（v1.3.23 实测证伪"波间 5~60ms"模型）：Windows Terminal 按帧分块投递
 * 粘贴，波间间隙可远大于 4/15ms 探测窗、每波只 1~3 个字符——"密集聚合"与
 * "积压计数"都会整段漏判，尾部换行仍被当作真实 Enter 提交。
 * 速率判据不依赖任何单次间隙：人类打字 ≤10 字符/秒达不到 12 字符/300ms；
 * 输入法逐字提交是"字+回车"交替（换行占比 ≈1:1，被 NL_DIV 排除）；粘贴则
 * 一帧可投数十字符且换行稀疏 → 明确命中。
 */
private let PASTE_STREAM_RATE_WINDOW_MS: Int64 = 300
private let PASTE_STREAM_RATE_MIN: Int64 = 12
private let PASTE_STREAM_RATE_NL_DIV: Int64 = 3

/**
 * 终端控制器：委托 TerminalBackend 实现平台差异，对外 API 与旧版一致
 */
public class Term {
    private let backend: TerminalBackend
    private let clock: Clock
    private var rawOn: Bool = false
    // burst 聚合的延迟重排队：合并判定为"非粘贴"（无换行）时，已吞读的
    // 字符必须按序还给后续 readKey，不得丢弃（对齐 atomcode per-key 重放）
    private var replay: ArrayList<KeyEvent> = ArrayList<KeyEvent>(0)
    // 粘贴流守护截止时刻（v1.3.23）：now < 截止 时，紧随其后的裸 Enter 判为
    // 终端给粘贴补发的换行（吞掉），不作为用户提交。None = 当前无守护。
    private var pasteStreamUntil: ?DateTime = None
    // 粘贴流到达速率窗口（v1.3.24）：近 RATE_WINDOW_MS 内的候选到达记录
    // (到达时刻, 是否换行)。超出窗口即丢弃，保持数组短小。
    private var candidateStamps: ArrayList<(DateTime, Bool)> = ArrayList<(DateTime, Bool)>(0)

    public init() {
        this.backend = createTerminalBackend()
        this.clock = SystemClock()
    }

    /**
     * 测试注入：替换 backend + 复位 burst 聚合状态。
     * 生产构建走默认 init；此重载仅供单元测试用 mock backend
     * 模拟 Windows 离散按键流（真实 conhost 无法在 CI 里驱动）。
     */
    public init(injected: TerminalBackend) {
        this.backend = injected
        this.clock = SystemClock()
    }

    /**
     * 测试注入：backend + 虚拟时钟。粘贴守护/到达速率都是时间窗口判定，
     * 真机节奏无法在 CI 里重现，故时间源可注入（见 clock.cj）。
     */
    public init(injected: TerminalBackend, clock: Clock) {
        this.backend = injected
        this.clock = clock
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
        if (KeyTrace.isEnabled()) {
            var path = "burst"
            if (pending >= BULK_PASTE_MIN) {
                path = "bulk"
            }
            KeyTrace.mark("TERM pending=${pending} path=${path} replay=${this.replay.size}")
        }
        if (pending >= BULK_PASTE_MIN) {
            return this.readRawStreamPaste()
        }
        // 常规读键；非候选（命令键/无输入）原样返回
        if (let Some(k) <- this.readGuardedRawKey()) {
            if (!this.isPasteCandidate(k)) {
                return Some(k)
            }
            return this.tryAggregateBurst(k)
        }
        return None
    }

    /**
     * 裸流读键（含粘贴补发 Enter 守护，v1.3.23）：
     * 处于粘贴流窗口内的裸 Enter 是终端为分块投递的粘贴补发的换行，
     * 直接吞掉并在同一帧继续读下一个键（绝不作为用户提交返回）。
     */
    private func readGuardedRawKey(): Option<KeyEvent> {
        var scanned: Int64 = 0
        while (scanned < 8) {
            scanned += 1
            if (!this.backend.hasInput()) {
                return None
            }
            if (let Some(k) <- this.backend.readKey()) {
                if (this.isGuardedPasteEnter(k)) {
                    if (KeyTrace.isEnabled()) {
                        KeyTrace.mark("TERM GUARD-DROP enter ch=${k.ch}")
                    }
                    continue  // 吞掉：粘贴补发换行，非用户提交
                }
                if (KeyTrace.isEnabled() && k.isEnter) {
                    // 关键行：未被守护拦住的裸 Enter 会直达 InputBox 提交
                    KeyTrace.mark("TERM GUARD-MISS enter ch=${k.ch} textLen=${k.text.size} -> APP")
                }
                return Some(k)
            }
            return None
        }
        return None
    }

    /**
     * 记录候选字符到达并判定是否处于"粘贴流"（v1.3.24 速率判据）：
     * 窗口内非换行候选 ≥ RATE_MIN，且换行数 × NL_DIV < 字符数 → 判定为粘贴，
     * 持续刷新 Enter 守护窗口（粘贴补发的尾部/行间换行必须被吞掉）。
     *
     * 只看"到达速率 + 换行占比"，不看单次间隙——这是对 Windows Terminal
     * 分帧投递（波间可达数十毫秒）唯一稳健的判据。
     */
    private func notePasteCandidate(k: KeyEvent): Unit {
        let now = this.clock.now()
        this.candidateStamps.add((now, k.isEnter))
        var recent = ArrayList<(DateTime, Bool)>(0)
        var chars: Int64 = 0
        var nls: Int64 = 0
        for (item in this.candidateStamps) {
            let (t, isNl) = item
            if ((now - t).toMilliseconds() <= PASTE_STREAM_RATE_WINDOW_MS) {
                recent.add(item)
                if (isNl) {
                    nls += 1
                } else {
                    chars += 1
                }
            }
        }
        this.candidateStamps = recent
        if (chars >= PASTE_STREAM_RATE_MIN && nls * PASTE_STREAM_RATE_NL_DIV < chars) {
            this.markPasteStream()
            if (KeyTrace.isEnabled()) {
                KeyTrace.mark("TERM rate-armed chars=${chars} nl=${nls}")
            }
        }
    }

    /** 标记进入粘贴流窗口（此后 PASTE_ENTER_GUARD_MS 内的裸 Enter 被吞掉） */
    private func markPasteStream(): Unit {
        this.pasteStreamUntil = Some(this.clock.now() + Duration.millisecond * PASTE_ENTER_GUARD_MS)
        if (KeyTrace.isEnabled()) {
            KeyTrace.mark("TERM mark-paste-stream window=${PASTE_ENTER_GUARD_MS}ms")
        }
    }

    /**
     * 粘贴补发 Enter 判定：处于粘贴流窗口内、且是"无修饰裸 Enter"——
     * 终端给粘贴补发的换行（用户提交 Enter 在窗口外，见 PASTE_ENTER_GUARD_MS）
     */
    private func isGuardedPasteEnter(k: KeyEvent): Bool {
        if (!k.isEnter || k.text.size != 1 || k.isPaste) {
            return false
        }
        if (let Some(until) <- this.pasteStreamUntil) {
            return this.clock.now() < until
        }
        return false
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
        // 速率判据（v1.3.24）：先记录到达，判定是否已处于粘贴流 → 刷新守护窗口。
        // 放在聚合之前：即使本次只读到 1 个字符（分帧投递），也能命中粘贴流。
        this.notePasteCandidate(firstKey)
        var chars = ArrayList<String>(4)
        var trailing = ArrayList<KeyEvent>(0)
        chars.add(this.candidateChar(firstKey))
        var confirmed: Bool = false
        while (chars.size < BULK_PASTE_MAX) {
            let timeoutMs: Int64 = if (confirmed) { BURST_ACTIVE_MS } else { BURST_PENDING_MS }
            if (!this.backend.waitInput(timeoutMs)) {
                if (KeyTrace.isEnabled()) {
                    // 投递节奏关键证据：等多久、等到没有
                    KeyTrace.mark("TERM burst wait=${timeoutMs}ms timeout chars=${chars.size}")
                }
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
        // 成串输入密度达标 → 认定处于粘贴流（守护紧随其后的补发 Enter）。
        // 覆盖"波界恰好落在换行前、前半段无换行"的分块投递场景
        var nonNewline: Int64 = 0
        for (c in chars) {
            if (c != "\r" && c != "\n") {
                nonNewline += 1
            }
        }
        if (nonNewline >= PASTE_STREAM_MIN_CHARS) {
            this.markPasteStream()
        }
        let pasteSig = this.isPasteBurst(chars)
        if (KeyTrace.isEnabled()) {
            var sig = 0
            if (pasteSig) {
                sig = 1
            }
            KeyTrace.mark("TERM burst chars=${chars.size} nonNL=${nonNewline} sig=${sig}")
        }
        if (pasteSig) {
            var sb = StringBuilder()
            for (c in chars) {
                sb.append(c)
            }
            // 打断 burst 的命令键已入 trailing：同样还回重放队
            for (t in trailing) {
                this.replay.add(t)
            }
            this.markPasteStream()  // 已发出粘贴事件：守护补发 Enter
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
        if (KeyTrace.isEnabled()) {
            KeyTrace.mark("TERM bulk start")
        }
        var sb = StringBuilder()
        var count: Int64 = 0
        // records：已消费的记录数（含抬键）。与 count（码点数）分开计数——
        // 抬键不产出字符，只推进 records，硬预算据此保证循环必然终止。
        var records: Int64 = 0
        while (count < BULK_PASTE_MAX && records < MAX_DRAIN_RECORDS) {
            // hasInput 非阻塞守卫：粘贴读完即停，绝不阻塞等下一个键
            if (!this.backend.hasInput()) {
                break
            }
            records += 1
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
                        this.markPasteStream()  // 已发出粘贴事件：守护补发 Enter
                        return Some(KeyEvent(sb.toString()))
                    }
                    return Some(k)
                }
                sb.append(k.text)
                count += k.text.toRuneArray().size
            }
            // readKey() 返回 None = 后端**已消费**一条记录但不上报（真机
            // Windows 控制台 bKeyDown=false 的抬键记录：hasInput 按记录总数
            // 计数、readKey 只认按下）。它不是"输入读完"，必须当作已消费的
            // 一条记录继续 drain——否则首遇抬键即 break 且 count==0，每次
            // readKey() 只吃 1~3 条，粘贴在 TUI 里逐字爬行（414 字符实测
            // 6.6s，TERM pending 标记 2939 条）。终止由 records 预算兜底。
        }
        if (count > 0) {
            this.markPasteStream()  // 已发出粘贴事件：守护补发 Enter
            return Some(KeyEvent(sb.toString()))
        }
        // 积压全是控制序列：退回常规读取（上面 while 已逐键读完则 None）
        return this.readGuardedRawKey()
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
