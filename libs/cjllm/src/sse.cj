package cjllm

import std.io.*
import cjlog.*
import std.collection.*
import std.time.*
import std.net.SocketTimeoutException
import stdx.net.http.HttpTimeoutException
import stdx.encoding.json.*
import cjutil.*

/**
 * SSE（Server-Sent Events）流解析器
 *
 * 从 InputStream 逐块读取，按 SSE 协议解析事件帧：
 *   data: {...}\n\n
 * 回调每个完整事件的 data 载荷。
 */
public class SseParser {
    private let input: InputStream
    private var buffer: Array<Byte>
    private var pending: Array<Byte>  // 未处理完的字节
    private var dataLines: ArrayList<String>
    public var onEvent: (String) -> Unit = { _ => }
    public var onDone: () -> Unit = { => }
    public var onError: (String) -> Unit = { _ => }
    // 空闲超预算触发（idleTimeout 完全无数据）：已收数据保留，但流被切断
    public var timedOut: Bool = false

    /**
     * 短读轮询间隔：每次 read 最多阻塞该时长（调用方把 transport.readTimeout
     * 设为该值）。流式帧不断则不触发；静默期每 POLL_INTERVAL 轮询一次中断标志
     * 与空闲预算——**中断响应 ≤ POLL_INTERVAL，不依赖 abort() 能否打断阻塞 read**
     * （TLS close 语义未验证，不赌 socket 行为；用户实测 Ctrl+C 断不掉阻塞 read）。
     */
    public static let POLL_INTERVAL: Duration = Duration.second * 5

    // 中断轮询（调用方注入 isCancelled）：短读超时后检查，用户中断立即生效
    public var cancelChecker: () -> Bool = { => false }
    // 空闲预算：超过该时长无"新事件" → timedOut（默认 60s，CJH_IDLE_TIMEOUT_SECS）。
    // 基于事件而非 read：代理 keep-alive 空帧会让 read 一直返回数据（绕过
    // read 预算），但空帧不产生事件（onEvent 不调用）——事件预算不受空帧影响，
    // 内容不再增长 + 时间流逝 = 停滞（用户实测场景）
    public var idleTimeout: Duration = Duration.second * 60
    // 最后事件时间（onEvent 调用时更新；空帧不更新）
    private var lastEventTime: DateTime = DateTime.now()

    public init(input: InputStream) {
        this.input = input
        this.buffer = Array<Byte>(8192, repeat: 0)
        this.pending = Array<Byte>()
        this.dataLines = ArrayList<String>()
    }

    /**
     * 取消解析：流读取循环在下一轮检查后提前结束（保留已收数据）。
     * 用途：用户 Ctrl+C 中断——onEvent 回调检测到取消请求时调用。
     */
    public var cancelled: Bool = false

    public func cancel(): Unit {
        this.cancelled = true
    }

    /**
     * 阻塞读取并解析整个流，直到 EOF、取消/中断、协议结束标记或空闲超预算。
     *
     * 短读轮询模型：transport.readTimeout = POLL_INTERVAL（5s），每次 read 至多
     * 阻塞 5s；超时后先查中断（cancelChecker）再查空闲预算（idleTimeout）。
     * 这样用户 Ctrl+C / 看门狗中断在 ≤5s 内必生效——即使 abort() 无法打断
     * 阻塞中的 TLS read，read 自身也会短超时退出，轮询到中断标志。
     */
    public func run(): Unit {
        var idleStart = DateTime.now()
        try {
            while (true) {
                if (this.cancelled || this.cancelChecker()) {
                    // 取消/用户中断：保留已收数据（flush 后结束，不抛异常）
                    this.flushRemaining()
                    break
                }
                // 事件预算：内容不再增长（无新事件）+ 时间流逝 = 停滞——
                // 代理 keep-alive 空帧维持 read 活动时，read 预算被绕过，
                // 事件预算兜底结束回合（用户实测：Streaming 计数一直涨但内容不变）
                if ((DateTime.now() - this.lastEventTime).toMilliseconds() > this.idleTimeout.toMilliseconds()) {
                    Log.warn("[SSE] 事件空闲超预算（${this.idleTimeout.toMilliseconds() / 1000}s 无新内容，仅 keep-alive 帧），flush pending (size=${this.pending.size})")
                    this.timedOut = true
                    this.flushRemaining()
                    break
                }
                var n: Int64 = 0
                try {
                    n = this.input.read(this.buffer)
                } catch (e: SocketTimeoutException) {
                    // 短读超时（POLL_INTERVAL 无数据）：轮询中断标志 + 空闲预算
                    if (this.cancelled || this.cancelChecker()) {
                        this.flushRemaining()
                        break
                    }
                    if ((DateTime.now() - idleStart).toMilliseconds() > this.idleTimeout.toMilliseconds()) {
                        Log.warn("[SSE] idle 超预算（${this.idleTimeout.toMilliseconds() / 1000}s 无数据，模型停滞/流被切断），flush pending (size=${this.pending.size})")
                        this.timedOut = true
                        this.flushRemaining()
                        break
                    }
                    continue  // 空闲在预算内（模型思考/代理缓冲）：继续等
                } catch (e: HttpTimeoutException) {
                    // 兼容旧 stdx.net.http 路径（已不再使用，保留兜底）
                    if (this.cancelled || this.cancelChecker()) {
                        this.flushRemaining()
                        break
                    }
                    if ((DateTime.now() - idleStart).toMilliseconds() > this.idleTimeout.toMilliseconds()) {
                        Log.warn("[SSE] idle timeout (absolute), flushing pending (size=${this.pending.size})")
                        this.timedOut = true
                        this.flushRemaining()
                        break
                    }
                    continue
                }
                if (n <= 0) {
                    // EOF：flush 剩余
                    this.flushRemaining()
                    break
                }
                idleStart = DateTime.now()  // 有数据：重置空闲计时
                var chunk = Array<Byte>(n, repeat: 0)
                for (i in 0..n) {
                    chunk[i] = this.buffer[i]
                }
                // 协议结束标记（data: [DONE] / event: message_stop / finish_reason）
                // → 提前结束，不等 EOF：服务端/代理输出完可能不关连接（keep-alive），
                // 继续 read 会挂起直到空闲超时误报"流被切断"
                let ended = this.feed(chunk)
                if (ended) {
                    break
                }
            }
            this.onDone()
        } catch (e: Exception) {
            // 用户中断（abort 关闭连接）→ 保留已收数据正常结束，不标 timedOut
            Log.warn("[SSE] run() caught exception (may be user abort): ${e}")
            this.flushRemaining()
            this.onDone()
        }
    }

    private func feed(chunk: Array<Byte>): Bool {
        // 合并 pending + 新块
        var merged = Array<Byte>(this.pending.size + chunk.size, repeat: 0)
        for (i in 0..this.pending.size) {
            merged[i] = this.pending[i]
        }
        for (i in 0..chunk.size) {
            merged[this.pending.size + i] = chunk[i]
        }

        // UTF-8 安全切分：从末尾向前找最后一个完整 UTF-8 字符的边界
        // 半截多字节字符留在 pending，等下一个块拼接成完整序列再处理
        // 这样 dispatchEvent 收到的字节都是完整 UTF-8，内容不丢
        var safeEnd = merged.size
        if (safeEnd > 0) {
            // 从末尾向前找 UTF-8 字符起始字节（0x00-0x7F 或 0xC0-0xFF）
            var probe = safeEnd - 1
            var foundStart = false
            while (probe >= 0 && probe >= safeEnd - 4) {  // UTF-8 最多 4 字节
                let b = merged[probe]
                if (b < 0x80u8 || (b >= 0xC0u8 && b <= 0xFDu8)) {
                    // 找到字符起始字节，计算预期长度
                    var expectedLen = 1
                    if ((b & 0xE0u8) == 0xC0u8) {
                        expectedLen = 2
                    } else if ((b & 0xF0u8) == 0xE0u8) {
                        expectedLen = 3
                    } else if ((b & 0xF8u8) == 0xF0u8) {
                        expectedLen = 4
                    }
                    let charEnd = probe + expectedLen
                    if (charEnd <= safeEnd) {
                        // 完整字符：safeEnd 就是 merged.size，无需调整
                        foundStart = true
                    } else {
                        // 半截字符：从 probe 开始的字节留到下个块
                        safeEnd = probe
                        foundStart = true
                    }
                    break
                }
                probe -= 1
            }
            // 如果向前扫了 4 字节还没找到起始字节（全是 10xxxxxx 续字节），
            // 说明 merged 末尾是非法序列，全部留到 pending 让下个块拼接判断
            if (!foundStart && safeEnd > 0) {
                safeEnd = if (safeEnd >= 4) { safeEnd - 4 } else { 0 }
            }
        }

        // 在 [0, safeEnd) 范围内按 \n\n 或 \r\n\r\n 切分事件
        var start = 0
        var i = 0
        while (i < safeEnd) {
            if (merged[i] == 10u8) {  // \n
                if (i + 1 < safeEnd && merged[i + 1] == 10u8) {
                    // 事件结束（\n\n）
                    if (this.dispatchEvent(merged, start, i)) {
                        return true
                    }
                    start = i + 2
                    i = start
                    continue
                } else if (i > 0 && merged[i - 1] == 13u8 && i + 1 < safeEnd && merged[i + 1] == 10u8) {
                    // 事件结束（\r\n\r\n）
                    if (this.dispatchEvent(merged, start, i - 1)) {
                        return true
                    }
                    start = i + 2
                    i = start
                    continue
                }
            }
            i += 1
        }
        // 剩余字节存入 pending（含 safeEnd 之后未处理的半截 UTF-8 字节）
        var rest = Array<Byte>(merged.size - start, repeat: 0)
        for (j in start..merged.size) {
            rest[j - start] = merged[j]
        }
        this.pending = rest
        return false
    }

    private func dispatchEvent(merged: Array<Byte>, start: Int64, endExcl: Int64): Bool {
        // 解析 data / event 行
        var data = ""
        var event = ""
        var i = start
        while (i < endExcl) {
            // 取一行
            var lineEnd = i
            while (lineEnd < endExcl && merged[lineEnd] != 10u8) {
                lineEnd += 1
            }
            var lineBytes = Array<Byte>(lineEnd - i, repeat: 0)
            for (j in i..lineEnd) {
                lineBytes[j - i] = merged[j]
            }
            var line = safeFromUtf8(lineBytes)
            // 去除尾部 \r
            if (line.size > 0 && line[line.size - 1] == 13u8) {
                line = line[0..line.size - 1]
            }
            if (line.startsWith("data:")) {
                var payload = line[5..line.size]
                if (payload.startsWith(" ")) {
                    payload = payload[1..payload.size]
                }
                if (data.size > 0) {
                    data = data + "\n"
                }
                data = data + payload
            } else if (line.startsWith("event:")) {
                event = line[6..line.size].trimAscii()
            }
            i = lineEnd + 1
        }
        if (data.size > 0) {
            this.onEvent(data)
            this.lastEventTime = DateTime.now()  // 有真实事件：重置事件预算
        }
        // 协议结束标记：OpenAI 系 data: [DONE]；Anthropic 系 event: message_stop；
        // OpenAI 兼容系 choices[0].finish_reason 非 null（stop/length/tool_calls）
        // → 通知 run() 提前结束，不等 EOF（服务端/代理可能 keep-alive 不关连接，
        // 甚至不发 [DONE]——只透传 finish_reason 的聚合网关实测会挂死 read）
        return data == "[DONE]" || event == "message_stop" || this.hasFinishReason(data)
    }

    /**
     * 检测 OpenAI 兼容流式最后一块：choices[0].finish_reason 为非 null 字符串。
     * finish_reason 是生成完成的标准信号（stop/length/tool_calls），
     * 比 [DONE] 更底层——部分聚合代理透传 finish_reason 但不透传 [DONE]。
     * 中间块 finish_reason 为 null → 不判定结束（仅 JSON 字符串非空才结束）。
     */
    private func hasFinishReason(data: String): Bool {
        // 快速路径：不含该字段直接返回（Anthropic/非 JSON 帧零开销）
        if (!data.contains("\"finish_reason\"")) {
            return false
        }
        try {
            let j = JsonValue.fromStr(data)
            match (j.kind()) {
                case JsonKind.JsObject =>
                    let obj = j.asObject()
                    if (let Some(choices) <- obj.get("choices")) {
                        match (choices.kind()) {
                            case JsonKind.JsArray =>
                                let arr = choices.asArray()
                                if (arr.size() > 0) {
                                    if (let Some(c0) <- arr.get(0)) {
                                        match (c0.kind()) {
                                            case JsonKind.JsObject =>
                                                let c = c0.asObject()
                                                if (let Some(fr) <- c.get("finish_reason")) {
                                                    match (fr.kind()) {
                                                        case JsonKind.JsString => return fr.asString().getValue().size > 0
                                                        case _ => return false
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            // JSON 解析失败：不判定结束（交由后续 [DONE]/EOF/超时兜底）
        }
        return false
    }

    private func flushRemaining(): Unit {
        // 流结束，处理剩余 pending 中的最后一个事件（可能无结尾空行）
        if (this.pending.size > 0) {
            this.dispatchEvent(this.pending, 0, this.pending.size)
            this.pending = Array<Byte>()
        }
    }
}
