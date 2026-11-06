package cjutil

import std.fs.*
import std.time.*

/**
 * 流式到达埋点（opt-in，默认关闭）
 *
 * 动机：用户反馈"思考输出看起来慢"时，有两种完全不同的原因——① 上游模型吐字慢
 * （SSE 分块间隔长、首字节前等待久）；② 本地 TUI 渲染跟不上。前者靠 `cjterm` 的
 * `CJH_TRACE_PERF`（渲染耗时）量不出来，需要一把对称的**到达侧**尺子。
 *
 * 契约：
 * - 开关 `CJH_TRACE_STREAM`（真值语义：去空白/引号、大小写不敏感，on/true/yes/y/enable）；
 *   落点 `CJH_TRACE_STREAM_FILE`，默认 `~/.cjh/cjh_stream.log`。
 * - **关闭时零开销零副作用**：入口先过 `isEnabled()`，不读时钟、不累加、不落盘。
 * - 落盘按节奏汇总：每 N 个 delta、或距上次落盘超过 2s 才写一行，不逐个 delta I/O。
 * - 统计量全是**整数微秒**与字符数，不涉浮点，跨平台格式一致。
 * - 观测边界是"交给 UI 的那一层"（provider 的 onDelta/onReasoning 回调），
 *   因此 `ttfbUs` = 请求发出到首帧内容的等待，`avgGapUs` = 吐字节奏。
 */

/** 微秒时间源（生产用单调时钟；单测注入虚拟源） */
public interface MicrosClock {
    func micros(): Int64
}

/** 生产时间源：进程内单调时钟，不受系统时间调整影响 */
public class MonoMicrosClock <: MicrosClock {
    private let start: MonoTime

    public init() {
        this.start = MonoTime.now()
    }

    public func micros(): Int64 {
        return (MonoTime.now() - this.start).toMicroseconds()
    }
}

public class StreamTrace {
    /** 是否开启（仅显式 CJH_TRACE_STREAM=<真值> 才开） */
    public static var enabled: Bool = false
    /** 每 N 个 delta 落一行汇总 */
    public static let FLUSH_EVERY: Int64 = 40
    /** 或距上次落盘超过该间隔（微秒） */
    public static let FLUSH_INTERVAL_US: Int64 = 2000000
    /** 单个间隔超过该值记一次"长静默"（模型停顿/代理攒包） */
    public static let STALL_US: Int64 = 1000000

    private static var initialized: Bool = false
    private static var filePath: String = ""
    private static var clock: MicrosClock = MonoMicrosClock()

    private static var reqCount: Int64 = 0
    private static var deltaCount: Int64 = 0
    private static var charsTotal: Int64 = 0
    private static var gapCount: Int64 = 0
    private static var gapTotalUs: Int64 = 0
    private static var gapMaxUs: Int64 = 0
    private static var gapLastUs: Int64 = 0
    private static var stalls: Int64 = 0
    private static var ttfbUs: Int64 = 0
    private static var ttfbMaxUs: Int64 = 0
    private static var lastDeltaChars: Int64 = 0
    private static var lastDeltaUs: Int64 = 0
    private static var reqStartUs: Int64 = 0
    private static var lastFlushUs: Int64 = 0
    private static var nextFlushAt: Int64 = StreamTrace.FLUSH_EVERY

    /** 是否开启（惰性读环境变量，只做一次） */
    public static func isEnabled(): Bool {
        StreamTrace.ensureInit()
        return StreamTrace.enabled
    }

    /** 落点（未开启时为空串） */
    public static func outputPath(): String {
        StreamTrace.ensureInit()
        return StreamTrace.filePath
    }

    private static func ensureInit(): Unit {
        if (StreamTrace.initialized) {
            return
        }
        StreamTrace.initialized = true
        var raw = ""
        if (let Some(v) <- EnvFfi.getenv("CJH_TRACE_STREAM")) {
            raw = v
        }
        if (!StreamTrace.isTruthy(raw)) {
            return
        }
        StreamTrace.enabled = true
        var p = EnvFfi.homeDir() + "/.cjh/cjh_stream.log"
        if (let Some(f) <- EnvFfi.getenv("CJH_TRACE_STREAM_FILE")) {
            let n = StreamTrace.normalize(f)
            if (n.size > 0) {
                p = n
            }
        }
        StreamTrace.filePath = p
        StreamTrace.ensureParentDir(p)
        StreamTrace.writeLine(p,
            "# cjh 流式到达埋点（CJH_TRACE_STREAM=1）；单位微秒，每 ${StreamTrace.FLUSH_EVERY} 个 delta 或 2s 一行", true)
        StreamTrace.lastFlushUs = StreamTrace.clock.micros()
    }

    /** 一轮请求开始：重置首字节计时（每轮 chatStream 调用一次） */
    public static func beginRequest(): Unit {
        if (!StreamTrace.isEnabled()) {
            return
        }
        StreamTrace.reqCount += 1
        StreamTrace.reqStartUs = StreamTrace.clock.micros()
        StreamTrace.lastDeltaUs = 0
    }

    /**
     * 收到一段内容增量（provider 的 onDelta / onReasoning 各算一次）。
     * @param chars 该增量的字符数（>0 才有意义）
     */
    public static func onDelta(chars: Int64): Unit {
        if (!StreamTrace.isEnabled()) {
            return
        }
        if (chars <= 0) {
            return
        }
        let now = StreamTrace.clock.micros()
        if (StreamTrace.lastDeltaUs == 0) {
            // 本轮首个增量：首字节（首帧内容）延迟
            let ttfb = now - StreamTrace.reqStartUs
            StreamTrace.ttfbUs = ttfb
            if (ttfb > StreamTrace.ttfbMaxUs) {
                StreamTrace.ttfbMaxUs = ttfb
            }
        } else {
            let gap = now - StreamTrace.lastDeltaUs
            StreamTrace.gapCount += 1
            StreamTrace.gapTotalUs += gap
            if (gap > StreamTrace.gapMaxUs) {
                StreamTrace.gapMaxUs = gap
            }
            if (gap > StreamTrace.STALL_US) {
                StreamTrace.stalls += 1
            }
            StreamTrace.gapLastUs = gap
        }
        StreamTrace.deltaCount += 1
        StreamTrace.charsTotal += chars
        StreamTrace.lastDeltaChars = chars
        StreamTrace.lastDeltaUs = now
        StreamTrace.maybeFlush()
    }

    /** 汇总一行（纯整数，供落盘与测试断言） */
    public static func stats(): String {
        let avgGap: Int64 = if (StreamTrace.gapCount == 0) { 0 } else { StreamTrace.gapTotalUs / StreamTrace.gapCount }
        return "reqs=${StreamTrace.reqCount} deltas=${StreamTrace.deltaCount} chars=${StreamTrace.charsTotal} ttfbUs=${StreamTrace.ttfbUs} ttfbMaxUs=${StreamTrace.ttfbMaxUs} avgGapUs=${avgGap} maxGapUs=${StreamTrace.gapMaxUs} lastGapUs=${StreamTrace.gapLastUs} stalls=${StreamTrace.stalls} lastDeltaChars=${StreamTrace.lastDeltaChars}"
    }

    /** 到点才落盘：计数到点或间隔到点（避免逐个 delta I/O，且不重复落同一批） */
    private static func maybeFlush(): Unit {
        let now = StreamTrace.clock.micros()
        var due = false
        if (StreamTrace.deltaCount >= StreamTrace.nextFlushAt) {
            StreamTrace.nextFlushAt = StreamTrace.deltaCount + StreamTrace.FLUSH_EVERY
            due = true
        }
        if (now - StreamTrace.lastFlushUs >= StreamTrace.FLUSH_INTERVAL_US) {
            due = true
        }
        if (!due) {
            return
        }
        StreamTrace.lastFlushUs = now
        StreamTrace.writeLine(StreamTrace.filePath, StreamTrace.stats(), false)
    }

    // ===== 环境变量真值与路径原语（cjutil 自成体系：不反向依赖 cjterm） =====

    /** 去空白与引号后统一小写（字符串下标取到的是 Byte，字面量须写 u8） */
    private static func normalize(v: String): String {
        var s = v.trimAscii().toString()
        while (s.size > 0 && (s[0] == 34u8 || s[0] == 39u8)) {
            s = s[1..]
        }
        while (s.size > 0 && (s[s.size - 1] == 34u8 || s[s.size - 1] == 39u8)) {
            s = s[0..s.size - 1]
        }
        return s.toAsciiLower()
    }

    /** 真值语义：on/true/yes/y/enable（大小写不敏感，允许包裹引号） */
    private static func isTruthy(raw: String): Bool {
        let s = StreamTrace.normalize(raw)
        return s == "on" || s == "true" || s == "yes" || s == "y" || s == "enable" || s == "1"
    }

    private static func ensureParentDir(path: String): Unit {
        var idx = -1
        var i = path.size - 1
        while (i >= 0) {
            let ch = path[i]
            if (ch == 47u8 || ch == 92u8) {
                idx = i
                break
            }
            i -= 1
        }
        if (idx <= 0) {
            return
        }
        let dir = path[0..idx]
        try {
            if (!exists(dir)) {
                Directory.create(dir, recursive: true)
            }
        } catch (e: Exception) {
            ()
        }
    }

    /** 追加/覆盖写一行（失败静默：埋点绝不能影响主流程） */
    private static func writeLine(path: String, line: String, truncate: Bool): Bool {
        let mode = if (truncate) { "w" } else { "a" }
        unsafe {
            let fp = fopen(LibC.mallocCString(path), LibC.mallocCString(mode))
            if (fp.isNull()) {
                return false
            }
            fputs(LibC.mallocCString(line + "\n"), fp)
            fclose(fp)
            return true
        }
    }

    // ===== 测试注入与观察点 =====

    /** 测试注入：直接开启并指定输出文件（绕过环境变量） */
    public static func enableForTest(path: String): Unit {
        StreamTrace.initialized = true
        StreamTrace.enabled = true
        StreamTrace.filePath = path
    }

    public static func disableForTest(): Unit {
        StreamTrace.initialized = true
        StreamTrace.enabled = false
        StreamTrace.filePath = ""
    }

    /** 测试注入时间源（虚拟时间，确定性验证首字节与间隔统计） */
    public static func setClockForTest(c: MicrosClock): Unit {
        StreamTrace.clock = c
        StreamTrace.lastFlushUs = c.micros()
    }

    public static func resetForTest(): Unit {
        StreamTrace.initialized = false
        StreamTrace.enabled = false
        StreamTrace.filePath = ""
        StreamTrace.clock = MonoMicrosClock()
        StreamTrace.reqCount = 0
        StreamTrace.deltaCount = 0
        StreamTrace.charsTotal = 0
        StreamTrace.gapCount = 0
        StreamTrace.gapTotalUs = 0
        StreamTrace.gapMaxUs = 0
        StreamTrace.gapLastUs = 0
        StreamTrace.stalls = 0
        StreamTrace.ttfbUs = 0
        StreamTrace.ttfbMaxUs = 0
        StreamTrace.lastDeltaChars = 0
        StreamTrace.lastDeltaUs = 0
        StreamTrace.reqStartUs = 0
        StreamTrace.lastFlushUs = 0
        StreamTrace.nextFlushAt = StreamTrace.FLUSH_EVERY
    }

    // 观察点只有 stats()：与 PerfTrace 同规约（仓颉里字段与方法同名会冲突）。
}

@C
foreign func fopen(path: CString, mode: CString): CPointer<UInt8>

@C
foreign func fputs(s: CString, fp: CPointer<UInt8>): Int32

@C
foreign func fclose(fp: CPointer<UInt8>): Int32
