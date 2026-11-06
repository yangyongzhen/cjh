package cjh.tools

import std.collection.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import std.time.*
import cjutil.*
import cjlog.*
import cjterm.*
import stdx.encoding.json.*
import std.convert.*
import cjllm.ToolSpec

/**
 * 后台任务（B-1）：把长命令从「同步阻塞」改成「起进程即返回，靠 poll 收割」。
 *
 * 与 BashSession 的分工（设计文档 §5.2）：
 * - BashSession 持有唯一一个持久 shell（单 stdin，必须一把锁串行喂入）——交互式短命令走它；
 * - 后台任务**不复用**会话进程：单 stdin 无法并发，故每个后台任务起独立进程。
 *   代价是不共享会话的 cwd/env，由工具描述与返回文本显式告知模型（不让它撞墙）。
 *
 * 输出模型：读线程把管道字节**全量落盘**到日志文件，poll 按字节游标读增量。
 * 之所以用文件而不是内存 ring：poll 的偏移是绝对字节数，落盘后既不丢数据也不需
 * 在内存里维护「ring 基准 ↔ 绝对偏移」的换算（少一层出错面）。
 *
 * UTF-8：切点一律回退到完整字符边界，再优先切在行尾（见 bgDeliverCut）；
 * 超长行（无换行）才会按字节预算切，避免进度条类输出把 poll 饿死。
 */

/** 后台任务状态机 */
public enum BgTaskState {
    BgRunning | BgSucceeded | BgFailed | BgKilled | BgTimedOut

    /** 线上一词（工具返回 / Web 帧 / 测试断言共用；仓颉 enum 无 == 运算符） */
    public func wire(): String {
        match (this) {
            case BgRunning => "running"
            case BgSucceeded => "succeeded"
            case BgFailed => "failed"
            case BgKilled => "killed"
            case BgTimedOut => "timeout"
        }
    }

    /** 终态：true 表示不会再有输出，poll 可交付半行残尾 */
    public func isTerminal(): Bool {
        match (this) {
            case BgRunning => false
            case _ => true
        }
    }
}

/** 结束了任务的原因（决定终态是 killed 还是 timeout） */
public enum BgKillReason {
    BgKillNone | BgKillByUser | BgKillTimeout
}

/**
 * 任务状态事件（工具层 → 上层 UI 的唯一通道）
 *
 * 为什么不直接拼 JSON：任务层属于 cjh.tools，不该知道 Web 帧长什么样，
 * 也不该依赖 JSON 库。这里只给"事实"（哪个任务、什么状态、多久、这批新增多少字节），
 * 由 Web 层（`BgTaskEvent`）或 TUI 面板各自决定怎么呈现。
 *
 * 触发时机（设计文档 §6.4）：启动成功、状态转终态、取消生效。
 */
public class BgTaskEventInfo {
    public let taskId: String
    public let kind: String
    public let label: String
    public let state: BgTaskState
    public let exitCode: Int64
    public let elapsedMs: Int64
    public let newOutputChars: Int64

    public init(taskId: String, kind: String, label: String, state: BgTaskState,
        exitCode: Int64, elapsedMs: Int64, newOutputChars: Int64) {
        this.taskId = taskId
        this.kind = kind
        this.label = label
        this.state = state
        this.exitCode = exitCode
        this.elapsedMs = elapsedMs
        this.newOutputChars = newOutputChars
    }
}

/**
 * 回退到完整 UTF-8 字符边界：返回 ≤ n 的最大切点，使 buf[0..ret) 不含半截多字节字符。
 *
 * 非终态交付时尾部的半截字符必须留到下一批（否则 poll 输出中文乱码，
 * 与 BashSession §3.15 同一类坑）。回退最多 3 字节；找不到起始字节时原样返回 n
 * （非法字节交给 safeFromUtf8 兜底）。
 */
public func utf8BoundaryCut(buf: Array<Byte>, n: Int64): Int64 {
    if (n <= 0) {
        return 0
    }
    var i = n
    var backtrack: Int64 = 0
    while (i > 0 && backtrack < 4) {
        let b = buf[i - 1]
        if ((b & 0xC0u8) != 0x80u8) {
            // 起始字节：按首字节判断该字符总长
            var need: Int64 = 1
            if ((b & 0x80u8) == 0u8) {
                need = 1
            } else if ((b & 0xE0u8) == 0xC0u8) {
                need = 2
            } else if ((b & 0xF0u8) == 0xE0u8) {
                need = 3
            } else if ((b & 0xF8u8) == 0xF0u8) {
                need = 4
            }
            if (i - 1 + need <= n) {
                return n
            }
            return i - 1
        }
        i -= 1
        backtrack += 1
    }
    return n
}

/**
 * 本次可交付的字节切点。
 *
 * @param n        本次从日志读到的字节数
 * @param terminal 任务已终态（收尾：半行残尾也要交出去）
 * @param full     读到的是否已占满预算（超长行兜底判据）
 *
 * 规则：UTF-8 边界 → 终态则全交；否则优先交到最后一个完整行；
 * 无完整行且预算已满才硬切（否则等下一批，保证行完整）。
 */
public func bgDeliverCut(buf: Array<Byte>, n: Int64, terminal: Bool, full: Bool): Int64 {
    if (n <= 0) {
        return 0
    }
    let safeEnd = utf8BoundaryCut(buf, n)
    if (safeEnd <= 0) {
        return 0
    }
    if (terminal) {
        return safeEnd
    }
    var lastNewline: Int64 = -1
    for (i in 0..safeEnd) {
        if (buf[i] == 10u8) {
            lastNewline = i
        }
    }
    if (lastNewline >= 0) {
        return lastNewline + 1
    }
    if (full) {
        return safeEnd
    }
    return 0
}

/**
 * 后台任务配置（四个键，来自 settings.json 的 background 段）
 *
 * - maxSlots      max_background_tasks      并发后台任务上限（满则直接拒绝，不排队）
 * - timeoutMs     background_task_timeout_ms 单个任务墙钟上限，到点自动杀
 * - outputMaxKb   background_output_max_kb   日志落盘上限（超出停写但继续抽管道，防子进程写阻塞）
 * - pollMaxBytes  background_poll_max_chars  单次 poll 交付的字节上限
 */
public class BgTaskConfig {
    public let maxSlots: Int64
    public let timeoutMs: Int64
    public let outputMaxKb: Int64
    public let pollMaxBytes: Int64

    public init() {
        this.maxSlots = 8
        this.timeoutMs = 1800000
        this.outputMaxKb = 256
        this.pollMaxBytes = 6000
    }

    public init(maxSlots: Int64, timeoutMs: Int64, outputMaxKb: Int64, pollMaxBytes: Int64) {
        this.maxSlots = if (maxSlots > 0) { maxSlots } else { 8 }
        this.timeoutMs = if (timeoutMs > 0) { timeoutMs } else { 1800000 }
        this.outputMaxKb = if (outputMaxKb > 0) { outputMaxKb } else { 256 }
        this.pollMaxBytes = if (pollMaxBytes > 0) { pollMaxBytes } else { 6000 }
    }

    /** 落盘上限（字节） */
    public func outputMaxBytes(): Int64 {
        return this.outputMaxKb * 1024
    }
}

/**
 * 耗时格式化（工具返回与任务列表共用）：12.3s / 1m23s / 1h02m
 */
public func formatElapsedMs(ms: Int64): String {
    if (ms < 0) {
        return "0.0s"
    }
    if (ms < 60000) {
        let tenths = (ms + 50) / 100
        return "${tenths / 10}.${tenths % 10}s"
    }
    let totalSecs = ms / 1000
    if (totalSecs < 3600) {
        return "${totalSecs / 60}m${totalSecs % 60}s"
    }
    // 分钟补零到两位：注释里承诺的格式是 1h02m（不是 1h2m），
    // 否则 1h2m / 1h12m 宽度不一致，任务列表里会跳
    let hours = totalSecs / 3600
    let mins = (totalSecs % 3600) / 60
    let minsText = if (mins < 10) { "0${mins}" } else { "${mins}" }
    return "${hours}h${minsText}m"
}

/**
 * 平台相关：POSIX 下用 setsid 把任务起在独立进程组里，
 * 超时/取消时 `kill -9 -<pgid>` 能一次带走命令派生的后代进程
 * （Linux 实测：setsid 后 pgid == pid）。Windows 直接起本体。
 */
// 输出**直接重定向到日志文件**（FromFile），stdin 丢弃：父进程不再持有管道，
// 也就不需要读线程把管道抽干落盘。这不是风格选择——旧实现 `spawn { readerLoop }`
// 是阻塞 read，占的是仓颉共享线程池的线程；2 核机器连起几个 bash_start，
// 阻塞读线程就把池子吃满，TUI 主循环与 agent 调度一起饿死，表现为整个界面
// 卡死 100 多秒（2026-11-06 实测：gdb 主线程栈停在
// BackgroundTask.readerLoop → ProcessInputStream.read → read(pipe)，
// 管道另一端正是 `sleep 120`）。重定向后零常驻线程，进程终态由 harvest() 轮询发现。
@When[os != "Windows"]
func launchBgProcess(shellPath: String, wrapped: String, logFile: File): SubProcess {
    return launch("setsid", [shellPath, "-c", wrapped],
        stdIn: Discard, stdOut: FromFile(logFile), stdErr: FromFile(logFile))
}

@When[os == "Windows"]
func launchBgProcess(shellPath: String, wrapped: String, logFile: File): SubProcess {
    return launch(shellPath, ["-c", wrapped],
        stdIn: Discard, stdOut: FromFile(logFile), stdErr: FromFile(logFile))
}

/** 平台相关：杀掉整个进程组（含命令派生出的后代），失败静默 */
@When[os != "Windows"]
func killProcessGroup(pid: Int64): Unit {
    if (pid <= 0) {
        return
    }
    try {
        let _ = executeWithOutput("/bin/bash", ["-c", "kill -9 -${pid} 2>/dev/null; exit 0"])
    } catch (e: Exception) {
        ()
    }
}

/**
 * Windows 无进程组语义：本体由 `terminateProc` 的 `p.terminate(force: true)` 兜底，
 * 仅「连带后代」这层缺省（形参无名，避免 Windows 目标编译出 unused variable 告警）
 */
@When[os == "Windows"]
func killProcessGroup(_: Int64): Unit {
    ()
}

/**
 * 单个后台任务：进程 + 输出日志 + 状态机。
 *
 * 并发模型：
 * - 读线程独占 `wait()`——它是唯一的回收点（重复 wait 同一子进程会出错，
 *   也避免僵尸泄漏，见 bash_session §3.10 事故）；
 * - 看门狗线程只负责到点置 killReason 并 terminate，不 wait；
 * - poll 与状态查询都在短临界区内取快照，绝不在持锁时做 IO。
 */
public class BackgroundTask {
    public let id: String
    public let kind: String
    public let label: String
    public let command: String
    public let cwd: String
    public let logPath: String
    /** 退出码旁路文件：shell 结束时把 $? 写进来（判死与取码的唯一来源） */
    public let rcPath: String
    public let timeoutMs: Int64
    public let startedAt: DateTime
    private let outputMaxBytes: Int64

    private let lock: Mutex = Mutex()
    private var stateValue: BgTaskState = BgRunning
    private var exitValue: Int64 = -1
    private var endedAtValue: Option<DateTime> = None
    private var deliveredValue: Int64 = 0
    private var killReasonValue: BgKillReason = BgKillNone
    // 下达 kill/超时信号的时刻：旁路退出码文件等不到时，靠它做兜底收场的宽限判断
    private var killAtValue: Option<DateTime> = None
    private var procValue: Option<SubProcess> = None
    // 终态回调：由注册表注入（向 UI 层推送事件）；无人监听时为 None
    public var onFinish: ?(BgTaskState, Int64) -> Unit = None

    public init(id: String, kind: String, label: String, command: String, cwd: String,
        logPath: String, rcPath: String, timeoutMs: Int64, outputMaxBytes: Int64) {
        this.id = id
        this.kind = kind
        this.label = label
        this.command = command
        this.cwd = cwd
        this.logPath = logPath
        this.rcPath = rcPath
        this.timeoutMs = timeoutMs
        this.outputMaxBytes = outputMaxBytes
        this.startedAt = DateTime.now()
    }

    public func state(): BgTaskState {
        this.lock.lock()
        try {
            return this.stateValue
        } finally {
            this.lock.unlock()
        }
    }

    public func exitCode(): Int64 {
        this.lock.lock()
        try {
            return this.exitValue
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 已落盘字节数（绝对偏移）。
     *
     * 子进程把输出直接重定向写日志文件（见 launchBgProcess），父进程不再有写
     * 句柄可累加，故按文件实际大小取值；超过 outputMaxBytes 后按上限截断
     * （投递语义不变：超限部分不交给模型）。
     */
    public func written(): Int64 {
        var size: Int64 = 0
        try {
            size = FileInfo(this.logPath).size
        } catch (e: Exception) {
            size = 0
        }
        if (this.outputMaxBytes > 0 && size > this.outputMaxBytes) {
            return this.outputMaxBytes
        }
        return size
    }

    /** 已交付给模型的字节数（绝对偏移） */
    public func delivered(): Int64 {
        this.lock.lock()
        try {
            return this.deliveredValue
        } finally {
            this.lock.unlock()
        }
    }

    /** 是否因超出落盘上限被截断（写句柄已不在父进程，按日志实际大小判断） */
    public func isTruncated(): Bool {
        return this.outputMaxBytes > 0 && this.written() >= this.outputMaxBytes
    }

    public func pid(): Int64 {
        this.lock.lock()
        let p = this.procValue
        this.lock.unlock()
        match (p) {
            case Some(sp) => return sp.pid
            case None => return 0
        }
    }

    /** 已运行（或运行了多久）毫秒数 */
    public func elapsedMs(): Int64 {
        this.lock.lock()
        let ended = this.endedAtValue
        this.lock.unlock()
        match (ended) {
            case Some(e) => return (e - this.startedAt).toMilliseconds()
            case None => return (DateTime.now() - this.startedAt).toMilliseconds()
        }
    }

    /** 行内摘要：`bg-1 [kind] label (12.3s, running)` */
    public func describe(): String {
        let st = this.state()
        let elapsed = formatElapsedMs(this.elapsedMs())
        if (st.isTerminal()) {
            return "${this.id} [${this.kind}] ${this.label} (${elapsed}, ${st.wire()}, exit ${this.exitCode()})"
        }
        return "${this.id} [${this.kind}] ${this.label} (${elapsed}, running)"
    }

    /**
     * 挂上已启动的进程：只登记句柄，不起任何常驻线程。
     *
     * 输出已由子进程直接重定向落盘（见 launchBgProcess），不必抽管道；
     * 终态与超时由 harvest() 在轮询点上发现。
     */
    internal func attach(proc: SubProcess): Unit {
        this.lock.lock()
        try {
            this.procValue = Some(proc)
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 非阻塞收割：进程已退出就定终态，超时就杀进程组。
     *
     * 以前这件事交给两个常驻 spawn 线程（readerLoop 阻塞读管道 + watchdogLoop
     * 每 100ms 醒来）。后台任务本来就是"起进程即返回、靠 poll 收割"的设计，
     * 运行期间不需要线程陪着等；而阻塞线程占的是仓颉共享线程池，2 核机器上
     * 连起几个 bash_start 就把池子吃满，TUI 主循环与 agent 调度一起饿死，
     * 表现为整屏卡死 100 多秒（2026-11-06 实测：gdb 主线程栈停在
     * BackgroundTask.readerLoop → ProcessInputStream.read → read(pipe 另一端是
     * `sleep 120`)）。现由调用方（启动抢跑窗口 / poll / 面板每秒节拍）顺手调，
     * 零常驻线程。
     *
     * @return 本次是否改变了任务状态（调用方据此决定是否重推面板）
     */
    internal func harvest(): Bool {
        if (this.state().isTerminal()) {
            return false
        }
        // 超时：原 watchdogLoop 的职责，挪到轮询点
        if (this.timeoutMs > 0 && this.elapsedMs() >= this.timeoutMs) {
            this.lock.lock()
            let already = match (this.killReasonValue) {
                case BgKillNone => false
                case _ => true
            }
            if (!already) {
                this.killReasonValue = BgKillTimeout
                this.killAtValue = Some(DateTime.now())
            }
            this.lock.unlock()
            if (!already) {
                Log.warn("[bg] ${this.id} 超时 ${this.timeoutMs}ms，强制结束")
                this.terminateProc()
            }
            // 不能在这里 return：已经发过超时信号后，被 SIGKILL 的 shell 写不出
            // 退出码文件，终态得由下面的 kill 兜底收场来定，否则永远停在 running
        }
        this.lock.lock()
        let target = this.procValue
        this.lock.unlock()
        match (target) {
            case Some(p) =>
                // 判死只认旁路退出码文件（见 buildBgWrapper 的注释）：isAlive() 对
                // 已退出但未回收的僵尸仍返回 true，wait(timeout) 第二次调用会忽略
                // 超时直接阻塞——两个都不能用来轮询，只会把"看一眼"变成"等到底"。
                match (this.readExitCodeFile()) {
                    case Some(code) =>
                        this.finish(code)
                        // 进程此时必已退出，wait 立即返回，回收僵尸不阻塞
                        try {
                            let _ = p.wait()
                        } catch (e: Exception) {
                            ()
                        }
                        return true
                    case None => ()
                }
            case None => ()
        }
        // 已发出 kill/超时信号，但旁路文件不会再有（被 SIGKILL 的 shell 写不了 $?）：
        // 超过宽限仍未收到就按"已取消"收场，不能让任务永远停在 running
        return this.finishKilledLongAgo()
    }

    /** 读旁路退出码文件；不存在、还没写完或内容不是整数时返回 None */
    private func readExitCodeFile(): Option<Int64> {
        var size: Int64 = 0
        try {
            size = FileInfo(this.rcPath).size
        } catch (e: Exception) {
            return None
        }
        // shell 写的是 "0\n" 这种几十字节的内容，超长说明不是退出码
        if (size <= 0 || size > 32) {
            return None
        }
        try {
            let raw = readLogRange(this.rcPath, 0, size)
            var value: Int64 = 0
            var neg = false
            var seen = false
            for (b in raw) {
                if (b == 45u8 && !seen) {
                    neg = true
                } else if (b >= 48u8 && b <= 57u8) {
                    value = value * 10 + Int64(b - 48u8)
                    seen = true
                }
            }
            if (!seen) {
                return None
            }
            return Some(if (neg) { -value } else { value })
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * kill / 超时后的兜底收场：
     *
     * 被 SIGKILL 的 shell 来不及写退出码，等不到旁路文件。发信号后超过宽限仍未
     * 收到，就按下达的 killReason 定终态（killed / timeout），避免任务卡在 running
     * 里永远占着槽位。
     */
    private func finishKilledLongAgo(): Bool {
        this.lock.lock()
        let reason = this.killReasonValue
        let killedAt = this.killAtValue
        this.lock.unlock()
        if (match (reason) { case BgKillNone => true; case _ => false }) {
            return false
        }
        match (killedAt) {
            case Some(t) =>
                if ((DateTime.now() - t).toMilliseconds() < 2000) {
                    return false
                }
                this.finish(this.exitCode())
                return true
            case None => return false
        }
    }

    /** 定终态 */
    private func finish(code: Int64): Unit {
        this.lock.lock()
        var reason = BgKillNone
        var wasTerminal = false
        var newState = BgRunning
        try {
            wasTerminal = this.stateValue.isTerminal()
            this.exitValue = code
            this.endedAtValue = Some(DateTime.now())
            reason = this.killReasonValue
            match (reason) {
                case BgKillByUser => this.stateValue = BgKilled
                case BgKillTimeout => this.stateValue = BgTimedOut
                case BgKillNone =>
                    this.stateValue = if (code == 0) { BgSucceeded } else { BgFailed }
            }
            newState = this.stateValue
        } finally {
            this.lock.unlock()
        }
        // 只在"首次转终态"时通知：重复 finish 不重复推事件（客户端不闪两次）
        if (!wasTerminal) {
            match (this.onFinish) {
                case Some(cb) =>
                    try {
                        cb(newState, code)
                    } catch (e: Exception) {
                        Log.warn("[bg] ${this.id} 终态回调失败: ${e}")
                    }
                case None => ()
            }
        }
    }

    /** 标记原因并杀进程（组）：kill 路径与超时收割共用 */
    internal func requestKill(reason: BgKillReason): Unit {
        this.lock.lock()
        try {
            if (this.stateValue.isTerminal()) {
                return
            }
            if (match (this.killReasonValue) { case BgKillNone => true; case _ => false }) {
                this.killReasonValue = reason
                this.killAtValue = Some(DateTime.now())
            }
        } finally {
            this.lock.unlock()
        }
        this.terminateProc()
    }

    private func terminateProc(): Unit {
        this.lock.lock()
        let target = this.procValue
        this.lock.unlock()
        match (target) {
            case Some(p) =>
                // 先杀进程组（带走后继进程），再杀本体；两者都静默——进程可能已自然退出
                killProcessGroup(p.pid)
                try {
                    p.terminate(force: true)
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
    }

    /**
     * 从上次交付的偏移处取增量输出（UTF-8 与行完整由 bgDeliverCut 保证）。
     *
     * @return (文本, 本次新增字节数)
     */
    public func takeOutput(maxBytes: Int64): (String, Int64) {
        this.lock.lock()
        var start: Int64 = 0
        var st = BgRunning
        try {
            start = this.deliveredValue
            st = this.stateValue
        } finally {
            this.lock.unlock()
        }
        // 总量以日志文件实际大小为准：子进程直接重定向写入，父进程没有累加器
        let total = this.written()
        if (total <= start) {
            return ("", 0)
        }
        var budget = total - start
        if (maxBytes > 0 && budget > maxBytes) {
            budget = maxBytes
        }
        var bytes: Array<Byte>
        try {
            bytes = readLogRange(this.logPath, start, budget)
        } catch (e: Exception) {
            Log.warn("[bg] ${this.id} 读日志失败: ${e}")
            return ("", 0)
        }
        let n = bytes.size
        let full = n >= budget
        let cut = bgDeliverCut(bytes, n, st.isTerminal(), full)
        if (cut <= 0) {
            return ("", 0)
        }
        this.lock.lock()
        try {
            this.deliveredValue = start + cut
        } finally {
            this.lock.unlock()
        }
        var slice = Array<Byte>(cut, repeat: 0)
        for (i in 0..cut) {
            slice[i] = bytes[i]
        }
        return (safeFromUtf8(slice), cut)
    }
}

/** 读日志文件的 [offset, offset+count) 区间 */
func readLogRange(path: String, offset: Int64, count: Int64): Array<Byte> {
    let f = File(path, OpenMode.Read)
    var acc = ArrayList<Byte>()
    try {
        f.seek(SeekPosition.Begin(offset))
        var remaining = count
        while (remaining > 0) {
            let chunkSize = if (remaining > 65536) { 65536 } else { remaining }
            let chunk = Array<Byte>(chunkSize, repeat: 0)
            let n = f.read(chunk)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                acc.add(chunk[i])
            }
            remaining -= n
        }
    } finally {
        try {
            f.close()
        } catch (e: Exception) {
            ()
        }
    }
    var out = Array<Byte>(acc.size, repeat: 0)
    for (i in 0..acc.size) {
        out[i] = acc[i]
    }
    return out
}

/**
 * 单引号安全转义（保留路径里的空格与特殊字符）。
 *
 * 注意不能逐字节 append 进 StringBuilder——`append(Byte)` 按十进制整数输出
 * （项目老坑 §3.x），这里整段 String 拼接。
 */
public func shSingleQuote(s: String): String {
    let escaped = s.replace("'", "'\\''")
    return "'" + escaped + "'"
}

/**
 * 组装后台任务的 shell 包装。
 *
 * 两个关键点：
 * 1. 收尾 `}` 独占一行——heredoc / 多行命令才能在 `bash -c` 里正确收尾
 *    （会话 heredoc 踩过的同一个坑，见 AGENTS「heredoc 也不需要分流」）；
 * 2. `} < /dev/null` 把 stdin 接到 /dev/null——后台任务没有 stdin 通道，
 *    读 stdin 的命令（cat/read/交互脚本）不接 /dev/null 会永久挂住（实测 cat 立刻结束）。
 */
/**
 * 后台任务的 shell 包装：输出直写日志，**退出码由 shell 自己写旁路文件**
 *
 * 退出码为什么不由父进程 wait 取：父进程侧没有可靠的"非阻塞判死"手段——
 * 实测 isAlive() 在子进程退出后仍返回 true（僵尸未回收），而 wait(timeout)
 * 第一次超时抛异常后、第二次会忽略超时直接阻塞到进程结束（把轮询变成阻塞，
 * 任务一多又把主循环拖死，这正是本次要修的病根）。故让 shell 退出时把 $?
 * 落到 `rcPath`，父进程只 stat 那个小文件：零阻塞、零线程、跨平台一致。
 *
 * 三个坑必须钉住：
 * 1. 命令体包在 `( ... )` 子 shell 里：命令自带 `exit` 时只结束子 shell，
 *    末尾的 `echo $? > rc` 才写得到（否则父进程永远等不到终态）；
 * 2. 收尾 `}` 独占一行——heredoc 才收得住（会话 heredoc 踩过同一个坑）；
 * 3. `} < /dev/null 2>&1`——后台任务没有 stdin，读 stdin 的命令不接 /dev/null 会永久挂住。
 */
public func buildBgWrapper(command: String, cwd: String, shellPath: String, isBash: Bool,
    rcPath: String): String {
    var sb = StringBuilder()
    if (isBash) {
        sb.append(shellPathFix(shellPath, true))
    }
    sb.append("(\n")
    if (cwd.size > 0) {
        sb.append("cd ${shSingleQuote(cwd)} || exit 97; ")
    }
    sb.append("{ ")
    sb.append(command)
    sb.append("\n} < /dev/null 2>&1\n)\necho $? > ${shSingleQuote(rcPath)}")
    return sb.toString()
}

/** 启动结果 */
public class BgStart {
    public let ok: Bool
    public let taskId: String
    /** 任务列表摘要（失败时为空） */
    public let text: String
    public init(ok: Bool, taskId: String, text: String) {
        this.ok = ok
        this.taskId = taskId
        this.text = text
    }
}

/** 轮询结果 */
public class BgPoll {
    public let ok: Bool
    public let taskId: String
    public let state: BgTaskState
    public let exitCode: Int64
    /** 本次新增输出（已解码、行完整） */
    public let output: String
    public let newBytes: Int64
    public let text: String
    public init(ok: Bool, taskId: String, state: BgTaskState, exitCode: Int64,
        output: String, newBytes: Int64, text: String) {
        this.ok = ok
        this.taskId = taskId
        this.state = state
        this.exitCode = exitCode
        this.output = output
        this.newBytes = newBytes
        this.text = text
    }
}

/** 取消结果 */
public class BgKill {
    public let ok: Bool
    public let taskId: String
    public let text: String
    public init(ok: Bool, taskId: String, text: String) {
        this.ok = ok
        this.taskId = taskId
        this.text = text
    }
}

/**
 * 后台任务表：槽位、启动、轮询、取消。
 *
 * 槽位语义（用户拍板 Q2）：满了**直接拒绝并提示**当前在跑什么、该怎么腾，
 * 不排队——排队会让模型以为任务已开始却永远等不到输出。
 *
 * 一个进程里每个入口（TUI / Web / one-shot）建一个实例，三件套工具共享同一实例；
 * 测试直接 new 一个独立实例即天然隔离。
 */
public class BackgroundTaskRegistry {
    private let cfg: BgTaskConfig
    private let logDir: String
    private let lock: Mutex = Mutex()
    private var tasks: ArrayList<BackgroundTask> = ArrayList<BackgroundTask>()
    private var seq: Int64 = 0
    // 完成的任务最多保留这么多条（供 poll 回看终态后仍可查询，又不无限增长）
    private let keepFinished: Int64 = 32
    // 状态事件监听：Web 面板订阅后转成 bg_task 帧；None = 无人订阅，emit 直接跳过
    public var onEvent: ?(BgTaskEventInfo) -> Unit = None

    public init(cfg: BgTaskConfig) {
        this.cfg = cfg
        this.logDir = tmpDir() + "/cjh_bg"
    }

    public init(cfg: BgTaskConfig, logDir: String) {
        this.cfg = cfg
        this.logDir = logDir
    }

    public func config(): BgTaskConfig {
        return this.cfg
    }

    /**
     * 推送任务状态事件（工具层 → UI 层）
     *
     * 回调异常一律吞掉并记日志：事件是给面板看的旁路，绝不能因为面板写失败
     * 打断任务状态机或读线程（同 WsSendGuard 的教训——写通道失败不该掀翻主流程）。
     */
    private func emitEvent(task: BackgroundTask, state: BgTaskState, exitCode: Int64,
        newChars: Int64): Unit {
        let sink = this.onEvent
        match (sink) {
            case Some(cb) =>
                try {
                    cb(BgTaskEventInfo(task.id, task.kind, task.label, state, exitCode,
                        task.elapsedMs(), newChars))
                } catch (e: Exception) {
                    Log.warn("[bg] ${task.id} 状态事件投递失败: ${e}")
                }
            case None => ()
        }
    }

    public func logDirectory(): String {
        return this.logDir
    }

    public func allTasks(): ArrayList<BackgroundTask> {
        this.lock.lock()
        try {
            var out = ArrayList<BackgroundTask>()
            for (t in this.tasks) {
                out.add(t)
            }
            return out
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 收割所有任务的状态：进程已退出的定终态、到点的按超时杀掉。
     *
     * 后台任务不再有常驻监视线程（见 BackgroundTask.harvest 的注释），所以
     * 由 UI 的每秒节拍调这个入口。少了它，进程结束后状态会一直停在 running，
     * 面板上已结束的任务永不淡出、槽位也永不释放。
     */
    public func harvestAll(): Unit {
        for (t in this.allTasks()) {
            let _ = t.harvest()
        }
    }

    public func runningTasks(): ArrayList<BackgroundTask> {
        var out = ArrayList<BackgroundTask>()
        for (t in this.allTasks()) {
            if (!t.state().isTerminal()) {
                out.add(t)
            }
        }
        return out
    }

    public func find(id: String): Option<BackgroundTask> {
        this.lock.lock()
        try {
            for (t in this.tasks) {
                if (t.id == id) {
                    return Some(t)
                }
            }
            return None
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 启动后台任务。
     *
     * @param timeoutMs 单任务墙钟上限（0=用配置默认）。dev server 这类常驻命令
     *                  需要 bash_start 传 timeout_secs 显式放宽，否则到点被看门狗杀掉。
     * @param eagerMs   抢跑窗口：起进程后最多等这么久看它是否立刻结束。
     *                  短命令（echo/真值查询）因此能一次调用就拿到输出，
     *                  长命令则到此为止立即返回，绝不阻塞 agent 循环。
     */
    public func start(command: String, label: String, cwd: String,
        shellPath: String, isBash: Bool, timeoutMs: Int64, eagerMs: Int64): BgStart {
        // 槽位判定与 ID 分配同一临界区：并发 start 不会超发
        this.lock.lock()
        var running: ArrayList<BackgroundTask> = ArrayList<BackgroundTask>()
        var id = ""
        try {
            for (t in this.tasks) {
                if (!t.state().isTerminal()) {
                    running.add(t)
                }
            }
            if (running.size >= this.cfg.maxSlots) {
                return BgStart(false, "", slotFullText(running, this.cfg.maxSlots))
            }
            this.seq += 1
            id = "bg-${this.seq}"
        } finally {
            this.lock.unlock()
        }
        if (!ensureDirExists(this.logDir)) {
            return BgStart(false, "", "无法创建后台任务日志目录 ${this.logDir}（检查磁盘权限/空间）")
        }
        let activeLabel = if (label.size > 0) { label } else { firstLineOf(command) }
        let logPath = "${this.logDir}/${id}.log"
        let rcPath = "${this.logDir}/${id}.rc"
        let effectiveTimeout = if (timeoutMs > 0) { timeoutMs } else { this.cfg.timeoutMs }
        let task = BackgroundTask(id, "bash", activeLabel, command, cwd, logPath, rcPath,
            effectiveTimeout, this.cfg.outputMaxBytes())
        let wrapped = buildBgWrapper(command, cwd, shellPath, isBash, rcPath)
        // 日志文件同时是子进程的 stdout/stderr 目标与 poll 的读取源。
        // 父进程只在 launch 期间持有句柄：dup 给子进程后立刻关闭——不占句柄，
        // 也不需要读线程（详见 launchBgProcess 的注释）。
        let logHandle = try {
            File(logPath, OpenMode.Append)
        } catch (e: Exception) {
            return BgStart(false, "", "无法打开后台任务日志 ${logPath}（检查磁盘权限/空间）：${e}")
        }
        var proc: SubProcess
        try {
            proc = launchBgProcess(shellPath, wrapped, logHandle)
        } catch (e: Exception) {
            return BgStart(false, "", "启动后台任务失败（进程未能创建）：${e}")
        } finally {
            try {
                logHandle.close()
            } catch (e: Exception) {
                ()
            }
        }
        // 先登记再 attach：登记晚了 poll 可能查不到（attach 现在只记录句柄，不再起线程）
        task.onFinish = { st: BgTaskState, code: Int64 =>
            this.emitEvent(task, st, code, 0)
        }
        this.lock.lock()
        try {
            this.tasks.add(task)
            this.pruneFinished()
        } finally {
            this.lock.unlock()
        }
        // running 事件先于读线程启动发出：客户端先看到"起了一个任务"，再接收终态
        this.emitEvent(task, BgRunning, -1, 0)
        task.attach(proc)
        // 抢跑窗口：短命令当场收尾，长命令到此立即返回
        var waited: Int64 = 0
        while (waited < eagerMs && !task.state().isTerminal()) {
            try {
                sleep(Duration.millisecond * 20)
            } catch (e: Exception) {
                break
            }
            waited += 20
            // 抢跑窗口内自己收割：短命令当场定终态，不必等下一次 poll
            let _ = task.harvest()
        }
        var early = ""
        var earlyBytes: Int64 = 0
        if (task.state().isTerminal() || task.written() > 0) {
            let (txt, n) = task.takeOutput(this.cfg.pollMaxBytes)
            early = txt
            earlyBytes = n
        }
        return BgStart(true, id, startText(task, early, earlyBytes))
    }

    /**
     * 收割增量输出。终态任务可反复 poll，直到无新增为止。
     */
    public func poll(id: String, maxBytes: Int64): BgPoll {
        match (this.find(id)) {
            case None =>
                return BgPoll(false, id, BgRunning, -1, "",
                    0, "未找到后台任务 ${id}。用 bash_poll 前请确认 ID；没有正在运行的任务说明它可能从未启动成功。")
            case Some(t) =>
                // 先收割一次：进程可能早已退出，没人 poll 时终态就靠这类轮询点发现
                let _ = t.harvest()
                let budget = if (maxBytes > 0) { maxBytes } else { this.cfg.pollMaxBytes }
                let (txt, n) = t.takeOutput(budget)
                return BgPoll(true, id, t.state(), t.exitCode(), txt, n,
                    pollText(t, txt, n))
        }
    }

    /**
     * 取消任务：先杀进程组再杀本体，最多等 3s 收割到终态后返回。
     */
    public func kill(id: String): BgKill {
        match (this.find(id)) {
            case None =>
                return BgKill(false, id, "未找到后台任务 ${id}")
            case Some(t) =>
                if (t.state().isTerminal()) {
                    return BgKill(true, id,
                        "${id} 已经结束（${t.state().wire()}，exit ${t.exitCode()}），无需取消。可 bash_poll 收取剩余输出。")
                }
                t.requestKill(BgKillByUser)
                var waited: Int64 = 0
                while (waited < 3000 && !t.state().isTerminal()) {
                    try {
                        sleep(Duration.millisecond * 50)
                    } catch (e: Exception) {
                        break
                    }
                    waited += 50
                    // 进程已被杀，靠收割把 wait 到的退出码转成终态
                    let _ = t.harvest()
                }
                let st = t.state()
                if (st.isTerminal()) {
                    return BgKill(true, id, "${id} 已取消并回收（${st.wire()}）。")
                }
                return BgKill(true, id,
                    "${id} 已发出取消信号，但进程尚未完全退出——稍后 bash_poll 确认终态。")
        }
    }

    /**
     * 结束全部运行中任务（会话收尾/进程退出时调用，避免遗留孤儿进程）。
     *
     * @return 本次被取消的任务数
     */
    public func killAll(): Int64 {
        var n: Int64 = 0
        for (t in this.allTasks()) {
            if (!t.state().isTerminal()) {
                t.requestKill(BgKillByUser)
                n += 1
            }
        }
        if (n == 0) {
            return 0
        }
        var waited: Int64 = 0
        while (waited < 2000) {
            var alive = false
            for (t in this.allTasks()) {
                let _ = t.harvest()
                if (!t.state().isTerminal()) {
                    alive = true
                }
            }
            if (!alive) {
                break
            }
            try {
                sleep(Duration.millisecond * 50)
            } catch (e: Exception) {
                break
            }
            waited += 50
        }
        return n
    }

    /** 只保留最近 keepFinished 条终态任务，运行中的永不清理 */
    private func pruneFinished(): Unit {
        var finished = ArrayList<BackgroundTask>()
        for (t in this.tasks) {
            if (t.state().isTerminal()) {
                finished.add(t)
            }
        }
        if (finished.size <= this.keepFinished) {
            return
        }
        let dropCount = finished.size - this.keepFinished
        var dropIds = ArrayList<String>()
        for (i in 0..dropCount) {
            dropIds.add(finished[i].id)
        }
        var kept = ArrayList<BackgroundTask>()
        for (t in this.tasks) {
            var dropped = false
            for (d in dropIds) {
                if (d == t.id) {
                    dropped = true
                }
            }
            if (!dropped) {
                kept.add(t)
            }
        }
        this.tasks = kept
    }
}

/** 目录不存在则创建（Directory.create 不幂等，必须先判断） */
func ensureDirExists(path: String): Bool {
    try {
        if (exists(path)) {
            return true
        }
        Directory.create(path, recursive: true)
        return true
    } catch (e: Exception) {
        return false
    }
}

/**
 * 进程内当前后台任务注册表（Web 面板订阅事件用）
 *
 * 用全局访问器而不是层层传参：任务表本来就是进程级全局的（槽位与 ID 全局唯一），
 * 而建表（entries.cj）与建 Web 服务分属两层。TUI / CLI 不订阅时恒为 None，零开销。
 */
private var currentBgRegistry: ?BackgroundTaskRegistry = None

public func setCurrentBackgroundRegistry(reg: BackgroundTaskRegistry): Unit {
    currentBgRegistry = Some(reg)
}

public func currentBackgroundRegistry(): Option<BackgroundTaskRegistry> {
    return currentBgRegistry
}

/** 命令首行（label 未给时充当任务名，避免面板只有 ID） */
func firstLineOf(command: String): String {
    let text = command.trimAscii()
    // 字符串迭代给 Byte：换行按数值比较（10u8），切片整段取 String
    var idx: Int64 = 0
    var found = false
    for (b in text) {
        if (b == 10u8) {
            found = true
            break
        }
        idx += 1
    }
    let line = if (found) { text[0..idx] } else { text }
    if (line.size > 60) {
        return truncateUtf8(line, 60) + "..."
    }
    return line
}

/** 槽位满提示：说清「现在是几个/上限几个」「在跑什么」「怎么腾」 */
func slotFullText(running: ArrayList<BackgroundTask>, maxSlots: Int64): String {
    var sb = StringBuilder()
    sb.append("后台任务槽位已满（${running.size}/${maxSlots}），本次启动被拒绝。\n")
    sb.append("运行中的任务：\n")
    for (t in running) {
        sb.append("  - ${t.describe()}\n")
    }
    sb.append("腾出槽位的两条路：\n")
    sb.append("  1. bash_poll 收割已跑完的任务（终态后自动释放槽位）\n")
    sb.append("  2. bash_kill 取消暂时不用的任务\n")
    sb.append("（本实现不排队：拒绝比『假装已启动但永远等不到』更容易诊断）")
    return sb.toString()
}

/** 启动返回文本 */
func startText(task: BackgroundTask, early: String, earlyBytes: Int64): String {
    var sb = StringBuilder()
    let st = task.state()
    if (st.isTerminal()) {
        sb.append("后台任务 ${task.id} 已在启动窗口内结束（${st.wire()}，exit ${task.exitCode()}，耗时 ${formatElapsedMs(task.elapsedMs())}）。\n")
    } else {
        sb.append("后台任务 ${task.id} 已启动：${task.label}\n")
        sb.append("  pid：${task.pid()}\n")
    }
    sb.append("  timeout：${formatElapsedMs(task.timeoutMs)}\n")
    if (task.cwd.size > 0) {
        sb.append("  cwd：${task.cwd}\n")
    }
    sb.append("  日志：${task.logPath}\n")
    if (early.size > 0) {
        sb.append("\n已产生的输出（${earlyBytes} 字节）：\n")
        sb.append(early)
        if (!early.endsWith("\n")) {
            sb.append("\n")
        }
    }
    if (!st.isTerminal()) {
        sb.append("\n注意：后台任务跑在独立进程里，**不共享 bash 会话的 cwd/环境变量**")
        sb.append("（会话 shell 只有一个 stdin，无法并发喂命令）。")
        sb.append("需要会话状态时请用同步 bash 工具。\n")
        sb.append("下一步：bash_poll(task_id=\"${task.id}\") 收割输出；不需要了用 bash_kill 取消。")
    }
    return sb.toString()
}

/** 轮询返回文本 */
func pollText(task: BackgroundTask, output: String, newBytes: Int64): String {
    var sb = StringBuilder()
    let st = task.state()
    sb.append("${task.id} [${task.kind}] ${task.label}｜${st.wire()}")
    if (st.isTerminal()) {
        sb.append("（exit ${task.exitCode()}）")
    }
    sb.append("｜已运行 ${formatElapsedMs(task.elapsedMs())}\n")
    if (output.size > 0) {
        sb.append("--- 新增输出（${newBytes} 字节）---\n")
        sb.append(output)
        if (!output.endsWith("\n")) {
            sb.append("\n")
        }
    } else {
        if (st.isTerminal()) {
            sb.append("--- 无新增输出（任务已结束，可能早已收完）---\n")
        } else {
            sb.append("--- 暂无新增输出（任务仍在运行，稍后再 poll）---\n")
        }
    }
    if (task.isTruncated()) {
        sb.append("注意：输出超过落盘上限（${task.written()} 字节后停写），后续内容已丢弃。\n")
    }
    sb.append("进度：已落盘 ${task.written()} 字节 / 已交付 ${task.delivered()} 字节")
    if (!st.isTerminal()) {
        sb.append("；任务未结束，可继续 bash_poll")
    }
    return sb.toString()
}

/** JsonValue → Int64（兼容 JsInt 与数字字符串；取不到返回 0） */
func bgIntArg(args: JsonObject, key: String): Int64 {
    if (!args.containsKey(key)) {
        return 0
    }
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsString =>
                    try {
                        return Int64.parse(v.asString().getValue())
                    } catch (e: Exception) {
                        return 0
                    }
                case _ => return 0
            }
        case None => return 0
    }
}

/** 取可选字符串参数（缺省或非字符串都返回空串） */
func bgStrArg(args: JsonObject, key: String): String {
    if (!args.containsKey(key)) {
        return ""
    }
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/**
 * bash_start：把命令丢到后台，**立即返回**任务 ID。
 *
 * 与 `bash` 的取舍写进工具描述（模型看得见才会用对）：
 * 后台任务跑在独立进程里 → 能并发、不阻塞；代价是不共享会话 cwd/env。
 */
public class BashStartTool <: CjhTool {
    private let registry: BackgroundTaskRegistry
    // 抢跑窗口：短命令一次调用就拿到结果；长命令到此立即返回
    private let eagerMs: Int64 = 200

    public init(registry: BackgroundTaskRegistry) {
        this.registry = registry
    }

    public func isReadOnly(): Bool {
        return false  // 起进程有副作用：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        let provider = ShellProvider()
        let slots = this.registry.config().maxSlots
        var props = HashMap<String, JsonValue>()
        props.add("command", JsonSchema.str("要执行的 shell 命令（支持多行与 heredoc）"))
        props.add("label", JsonSchema.str("任务名（可选）。不给则取命令首行，用于任务列表与提示"))
        props.add("cwd", JsonSchema.str("工作目录（可选）。默认取 cjh 进程自身 cwd——**不继承 bash 会话里 cd 过的目录**"))
        props.add("timeout_secs", JsonSchema.str("墙钟上限秒数（可选）。0/缺省=用配置值；dev server 这类常驻命令请显式放宽或设很大"))
        let schema = JsonSchema.object(props, ArrayList<String>(["command"]))
        return ToolSpec("bash_start",
            "Start a shell command in the background and return immediately with a task id. " +
            "Use it instead of `bash` for anything that may outlive one call: builds, full test suites, " +
            "dev servers, log tails, data migrations.\n" +
            "Trade-off you must know: a background task runs in its OWN process, so it does NOT share the " +
            "bash session's cwd or environment — an earlier `cd` via `bash` is invisible here; pass `cwd` " +
            "explicitly when the location matters. Anything needing session state should stay on `bash`.\n" +
            "Output goes to a log file: fetch it with bash_poll(task_id), cancel with bash_kill(task_id). " +
            "Commands that finish within a ~200ms window return their output directly in this result. " +
            "stdin is /dev/null, so a command reading stdin sees EOF instead of hanging.\n" +
            "At most ${slots} tasks may run concurrently (settings background.max_background_tasks). " +
            "When the slots are full the start is REJECTED — not queued: poll or kill a running task first.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("command")) {
            return ToolResult("缺少参数: command", true)
        }
        let command = bgStrArg(args, "command")
        if (command.trimAscii().size == 0) {
            return ToolResult("command 不能为空", true)
        }
        let label = bgStrArg(args, "label")
        let cwd = bgStrArg(args, "cwd")
        let timeoutSecs = bgIntArg(args, "timeout_secs")
        let timeoutMs: Int64 = if (timeoutSecs > 0) { timeoutSecs * 1000 } else { 0 }
        let provider = ShellProvider()
        if (!provider.isBash) {
            return ToolResult(
                "⚠ 当前系统未检测到 bash（shell 模式为 PowerShell），后台任务依赖 POSIX shell 语义，" +
                "暂不可用。请改用同步 bash 工具执行。", true)
        }
        let r = this.registry.start(command, label, cwd, provider.shellPath,
            provider.isBash, timeoutMs, this.eagerMs)
        return ToolResult(r.text, !r.ok)
    }
}

/**
 * bash_poll：按字节游标交付增量输出，并报告终态与退出码。
 */
public class BashPollTool <: CjhTool {
    private let registry: BackgroundTaskRegistry

    public init(registry: BackgroundTaskRegistry) {
        this.registry = registry
    }

    public func isReadOnly(): Bool {
        return false  // 推进交付游标：不能与其他写工具并行
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("task_id", JsonSchema.str("bash_start 返回的任务 ID，如 bg-1"))
        props.add("max_chars", JsonSchema.str("本次最多交付的字节数（可选，默认取配置 background.poll_max_chars）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["task_id"]))
        return ToolSpec("bash_poll",
            "Collect INCREMENTAL output from a background task created by bash_start. " +
            "Only bytes produced since the previous poll are returned (a byte cursor is kept per task), " +
            "so calling it repeatedly never repeats output. " +
            "The header reports state (running/succeeded/failed/killed/timeout) and the exit code once ended. " +
            "Keep polling while it says the task is still running; a terminal state with no new output means " +
            "the task is fully collected. The task's slot is released when it reaches a terminal state.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("task_id")) {
            return ToolResult("缺少参数: task_id", true)
        }
        let taskId = bgStrArg(args, "task_id").trimAscii()
        if (taskId.size == 0) {
            return ToolResult("task_id 不能为空", true)
        }
        let maxBytes = bgIntArg(args, "max_chars")
        let r = this.registry.poll(taskId, maxBytes)
        return ToolResult(r.text, !r.ok)
    }
}

/**
 * bash_kill：取消任务（整组进程）+ 等回收。
 */
public class BashKillTool <: CjhTool {
    private let registry: BackgroundTaskRegistry

    public init(registry: BackgroundTaskRegistry) {
        this.registry = registry
    }

    public func isReadOnly(): Bool {
        return false
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("task_id", JsonSchema.str("要取消的任务 ID，如 bg-1"))
        let schema = JsonSchema.object(props, ArrayList<String>(["task_id"]))
        return ToolSpec("bash_kill",
            "Cancel a background task started by bash_start. Kills the whole process group " +
            "(the command's children included) and waits up to 3s for it to be reaped, then reports the " +
            "final state. Output produced before the kill stays readable via bash_poll. " +
            "Calling it on an already-finished task is not an error — it just reports that state. " +
            "Use it to free a slot when the slots are full, or to stop a dev server you no longer need.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("task_id")) {
            return ToolResult("缺少参数: task_id", true)
        }
        let taskId = bgStrArg(args, "task_id").trimAscii()
        if (taskId.size == 0) {
            return ToolResult("task_id 不能为空", true)
        }
        let r = this.registry.kill(taskId)
        return ToolResult(r.text, !r.ok)
    }
}
