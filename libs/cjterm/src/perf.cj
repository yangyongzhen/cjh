package cjterm

/**
 * 渲染性能埋点（opt-in，默认关闭；版本号沿用 v1.3.26 不升）
 *
 * 动机：展开思考块时每帧都要重折"进行中"那一轮（单轮上限 8192 rune），是 TUI
 * 渲染路径的主要热点。要不要继续做结构性优化（头段冻结 + 尾段增量折行）应当由
 * **实测数据**决定，而不是凭感觉改——所以先给一把可信的尺子。
 *
 * 契约：
 * - 开关 `CJH_TRACE_PERF`（真值语义复用 KeyTrace：去空白/引号、大小写不敏感，
 *   on/true/yes/y/enable 为真）；落点 `CJH_TRACE_PERF_FILE`，默认 `~/.cjh/cjh_perf.log`。
 * - **关闭时零开销零副作用**：所有入口先过 `isEnabled()`，不读时钟、不分配、不落盘，
 *   调用点因此不需要自备 `if`（内部早退）。
 * - 落盘按节奏汇总：每 60 次渲染、或距上次落盘超过 2s 才写一行，不逐帧 I/O。
 * - 时间单位为**微秒**（与 KeyTrace.stampUs 同源、纯整数统计），避免浮点格式化差异。
 * - 无需 app 侧接线：首次调用惰性读环境变量（与 KeyTrace 一致）。
 */

/** 微秒时间源（与 clock.cj 的 Clock 同思路：生产用系统时钟，单测注入虚拟源） */
public interface MicrosSource {
    func micros(): Int64
}

/** 生产时间源：进程启动以来的微秒数（复用 KeyTrace 的单调时钟） */
public class SystemMicros <: MicrosSource {
    public init() {}

    public func micros(): Int64 {
        return KeyTrace.stampUs()
    }
}

public class PerfTrace {
    /** 是否开启（仅显式 CJH_TRACE_PERF=<真值> 才开） */
    public static var enabled: Bool = false
    /** 每渲染 N 次落一行汇总 */
    public static let FLUSH_EVERY: Int64 = 60
    /** 或距上次落盘超过该间隔（微秒） */
    public static let FLUSH_INTERVAL_US: Int64 = 2000000

    private static var initialized: Bool = false
    private static var filePath: String = ""
    private static var source: MicrosSource = SystemMicros()
    private static var renderCount: Int64 = 0
    private static var foldCount: Int64 = 0
    private static var foldTotalUs: Int64 = 0
    private static var foldMaxUs: Int64 = 0
    private static var lastFoldUs: Int64 = 0
    private static var lastLines: Int64 = 0
    private static var lastActiveRunes: Int64 = 0
    private static var lastFlushUs: Int64 = 0
    private static var nextFlushAt: Int64 = PerfTrace.FLUSH_EVERY

    /** 是否开启（惰性读环境变量，只做一次） */
    public static func isEnabled(): Bool {
        PerfTrace.ensureInit()
        return PerfTrace.enabled
    }

    /** 落点（未开启时为空串） */
    public static func outputPath(): String {
        PerfTrace.ensureInit()
        return PerfTrace.filePath
    }

    private static func ensureInit(): Unit {
        if (PerfTrace.initialized) {
            return
        }
        PerfTrace.initialized = true
        var raw = ""
        if (let Some(v) <- TermEnv.getenv("CJH_TRACE_PERF")) {
            raw = v
        }
        if (!KeyTrace.isTruthy(raw)) {
            return
        }
        PerfTrace.enabled = true
        var p = KeyTrace.defaultPathNamed(KeyTrace.homeDir(), "cjh_perf.log")
        if (let Some(f) <- TermEnv.getenv("CJH_TRACE_PERF_FILE")) {
            p = KeyTrace.normalizeValue(f)
        }
        PerfTrace.filePath = p
        KeyTrace.ensureParentDir(p)
        KeyTrace.writeLine(p, "# cjh 渲染性能埋点（CJH_TRACE_PERF=1）；单位微秒，每 ${PerfTrace.FLUSH_EVERY} 次渲染或 2s 一行", true)
        PerfTrace.lastFlushUs = PerfTrace.source.micros()
    }

    /** 渲染计数（每帧一次；关闭时立即返回） */
    public static func onRender(): Unit {
        if (!PerfTrace.isEnabled()) {
            return
        }
        PerfTrace.renderCount += 1
        PerfTrace.maybeFlush()
    }

    /** 折行计时开始：返回时间戳；关闭时**不读时钟**、返回 0 */
    public static func beginFold(): Int64 {
        if (!PerfTrace.isEnabled()) {
            return 0
        }
        return PerfTrace.source.micros()
    }

    /** 折行计时结束：累计耗时、行数与活跃轮长度 */
    public static func foldDone(startUs: Int64, lines: Int64, activeRunes: Int64): Unit {
        if (!PerfTrace.isEnabled()) {
            return
        }
        let cost = PerfTrace.source.micros() - startUs
        PerfTrace.foldCount += 1
        PerfTrace.foldTotalUs += cost
        if (cost > PerfTrace.foldMaxUs) {
            PerfTrace.foldMaxUs = cost
        }
        PerfTrace.lastFoldUs = cost
        PerfTrace.lastLines = lines
        PerfTrace.lastActiveRunes = activeRunes
        PerfTrace.maybeFlush()
    }

    /** 汇总一行（纯整数，供落盘与测试断言） */
    public static func stats(): String {
        let avg: Int64 = if (PerfTrace.foldCount == 0) { 0 } else { PerfTrace.foldTotalUs / PerfTrace.foldCount }
        return "renders=${PerfTrace.renderCount} folds=${PerfTrace.foldCount} avgFoldUs=${avg} maxFoldUs=${PerfTrace.foldMaxUs} lastFoldUs=${PerfTrace.lastFoldUs} lastLines=${PerfTrace.lastLines} lastActiveRunes=${PerfTrace.lastActiveRunes}"
    }

    /** 到点才落盘：计数到点或间隔到点（避免逐帧 I/O，且不重复落同一批） */
    private static func maybeFlush(): Unit {
        let now = PerfTrace.source.micros()
        var due = false
        if (PerfTrace.renderCount >= PerfTrace.nextFlushAt) {
            PerfTrace.nextFlushAt = PerfTrace.renderCount + PerfTrace.FLUSH_EVERY
            due = true
        }
        if (now - PerfTrace.lastFlushUs >= PerfTrace.FLUSH_INTERVAL_US) {
            due = true
        }
        if (!due) {
            return
        }
        PerfTrace.lastFlushUs = now
        KeyTrace.writeLine(PerfTrace.filePath, PerfTrace.stats(), false)
    }

    // ===== 测试注入与观察点 =====

    /** 测试注入：直接开启并指定输出文件（绕过环境变量；不落盘，由用例自己驱动） */
    public static func enableForTest(path: String): Unit {
        PerfTrace.initialized = true
        PerfTrace.enabled = true
        PerfTrace.filePath = path
    }

    public static func disableForTest(): Unit {
        PerfTrace.initialized = true
        PerfTrace.enabled = false
        PerfTrace.filePath = ""
    }

    /** 测试注入时间源（虚拟时间，确定性验证耗时统计与落盘节奏） */
    public static func setSourceForTest(s: MicrosSource): Unit {
        PerfTrace.source = s
        PerfTrace.lastFlushUs = s.micros()
    }

    public static func resetForTest(): Unit {
        PerfTrace.initialized = false
        PerfTrace.enabled = false
        PerfTrace.filePath = ""
        PerfTrace.source = SystemMicros()
        PerfTrace.renderCount = 0
        PerfTrace.foldCount = 0
        PerfTrace.foldTotalUs = 0
        PerfTrace.foldMaxUs = 0
        PerfTrace.lastFoldUs = 0
        PerfTrace.lastLines = 0
        PerfTrace.lastActiveRunes = 0
        PerfTrace.lastFlushUs = 0
        PerfTrace.nextFlushAt = PerfTrace.FLUSH_EVERY
    }

    // 观察点只有 stats()：仓颉里字段与方法同名会冲突（redefinition），而"汇总串"
    // 本就是这份埋点对外的唯一契约——单测断言 stats() 即可，不再单开一组 getter。
}
