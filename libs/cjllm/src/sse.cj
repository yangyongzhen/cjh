package cjllm

import std.io.*
import std.collection.*

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
        } catch (e: Exception) {
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

        // 按 \n\n 或 \r\n\r\n 切分事件
        var start = 0
        var i = 0
        while (i < merged.size) {
            if (merged[i] == 10u8) {  // \n
                if (i + 1 < merged.size && merged[i + 1] == 10u8) {
                    // 事件结束（\n\n）
                    this.dispatchEvent(merged, start, i)
                    start = i + 2
                    i = start
                    continue
                } else if (i > 0 && merged[i - 1] == 13u8 && i + 1 < merged.size && merged[i + 1] == 10u8) {
                    // 事件结束（\r\n\r\n）
                    this.dispatchEvent(merged, start, i - 1)
                    start = i + 2
                    i = start
                    continue
                }
            }
            i += 1
        }
        // 剩余字节存入 pending
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
            var line = String.fromUtf8(lineBytes)
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
