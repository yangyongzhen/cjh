package cjllm

import std.io.*
import std.collection.*
import stdx.net.http.HttpTimeoutException
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
    // 空闲超时（readTimeout 触发）：已收数据保留，但流被切断
    public var timedOut: Bool = false

    public init(input: InputStream) {
        this.input = input
        this.buffer = Array<Byte>(8192, repeat: 0)
        this.pending = Array<Byte>()
        this.dataLines = ArrayList<String>()
    }

    /**
     * 阻塞读取并解析整个流，直到 EOF
     */
    public func run(): Unit {
        try {
            while (true) {
                let n = this.input.read(this.buffer)
                if (n <= 0) {
                    // EOF：flush 剩余
                    this.flushRemaining()
                    break
                }
                var chunk = Array<Byte>(n, repeat: 0)
                for (i in 0..n) {
                    chunk[i] = this.buffer[i]
                }
                this.feed(chunk)
            }
            this.onDone()
        } catch (e: HttpTimeoutException) {
            // 空闲超时：DeepSeek 长 completions chunk 持续到达不会触发；
            // 网络 60s 无新数据 → timeout → 保留已收数据 + 标记 timedOut
            Log.warn("[SSE] read timeout, flushing pending (size=${this.pending.size})")
            this.timedOut = true
            this.flushRemaining()
            this.onDone()
        } catch (e: Exception) {
            Log.error("[SSE] run() caught exception", e)
            this.onError(e.toString())
        }
    }

    private func feed(chunk: Array<Byte>): Unit {
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
                    this.dispatchEvent(merged, start, i)
                    start = i + 2
                    i = start
                    continue
                } else if (i > 0 && merged[i - 1] == 13u8 && i + 1 < safeEnd && merged[i + 1] == 10u8) {
                    // 事件结束（\r\n\r\n）
                    this.dispatchEvent(merged, start, i - 1)
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
    }

    private func dispatchEvent(merged: Array<Byte>, start: Int64, endExcl: Int64): Unit {
        // 解析 data 行
        var data = ""
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
            }
            i = lineEnd + 1
        }
        if (data.size > 0) {
            this.onEvent(data)
        }
    }

    private func flushRemaining(): Unit {
        // 流结束，处理剩余 pending 中的最后一个事件（可能无结尾空行）
        if (this.pending.size > 0) {
            this.dispatchEvent(this.pending, 0, this.pending.size)
            this.pending = Array<Byte>()
        }
    }
}
