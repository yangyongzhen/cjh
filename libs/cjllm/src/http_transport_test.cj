package cjllm

import std.net.*
import std.time.*
import std.collection.*
import cjutil.*

/**
 * HttpStreamClient 稳定性测试
 *
 * mock server（本地 TcpServerSocket，无 TLS 变体）验证：
 *  1. content-length 完整读取 + 状态/头解析
 *  2. chunked 解码（SSE 风格分块）
 *  3. 超长流不超时（per-read 语义：帧不断则永不超时——根治长任务误切）
 *  4. per-read 超时打断（停滞 N 秒无数据抛 SocketTimeoutException——根治停滞）
 *  5. abort 打断（读中关闭连接）
 *  6. 连接关闭 EOF（服务端中断）
 */
@Test
public class HttpTransportTest {
    // ==================== 场景 1：content-length 完整读取 ====================

    @TestCase
    public func testContentLengthStream(): Unit {
        let port: UInt16 = 18101
        let body = "hello world, this is a streaming response body with enough length to split into chunks"
        let _ = startMockServer(port, MockResp.ContentLength(body, 5))
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, hdrs) = client.readResponseHead()
        @Assert(status, 200)
        @Assert(hdrs.get("Content-Type").getOrThrow(), "text/plain")
        let got = readAll(client)
        @Assert(got, body)
        client.close()
    }

    // ==================== 场景 2：chunked 解码 ====================

    @TestCase
    public func testChunkedStream(): Unit {
        let port: UInt16 = 18102
        let body = "data: {\"content\":\"你好，世界\"}\n\ndata: [DONE]\n\n"
        let _ = startMockServer(port, MockResp.Chunked(body))
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, hdrs) = client.readResponseHead()
        @Assert(status, 200)
        let got = readAll(client)
        @Assert(got, body)
        client.close()
    }

    // ==================== 场景 3：超长流不超时（per-read 核心） ====================

    @TestCase
    public func testLongStreamNoTimeout(): Unit {
        let port: UInt16 = 18103
        // 服务端持续 3s 发帧（每 50ms 一帧）；客户端 readTimeout 仅 1s
        // 若 readTimeout 是整体绝对超时 → 必然误切；per-read 语义 → 帧不断永不超时
        let _ = startMockServer(port, MockResp.LongStream(3000, 40))
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let t0 = DateTime.now()
        let got = readAll(client)  // 总时长 3s > readTimeout 1s，必须不抛超时
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(got.size > 100, true)  // 收到大量数据
        @Assert(elapsed >= 2900, true)  // 确实流了 ~3s
        @Assert(elapsed < 5000, true)  // 且未被超时误切
        client.close()
    }

    // ==================== 场景 4：per-read 超时打断（停滞根治） ====================

    @TestCase
    public func testReadTimeoutInterrupt(): Unit {
        let port: UInt16 = 18104
        let _ = startMockServer(port, MockResp.StallAfterHead(2000))  // 发头 + 少量数据后停发
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let input = HttpStreamInput(client)
        let buf = Array<Byte>(1024, repeat: 0)
        let t0 = DateTime.now()
        var threw: Bool = false
        try {
            let n = input.read(buf)
            // 可能先读到"少量数据"，下一次 read 才超时
            if (n <= 0) {
                @Assert(true, false)  // 不应 EOF（服务端没关）
            }
            let t1 = DateTime.now()
            try {
                input.read(buf)
            } catch (e: SocketTimeoutException) {
                threw = true
                @Assert((DateTime.now() - t0).toSeconds() >= 1, true)  // 超时后 ~1s 抛
            }
        } catch (e: SocketTimeoutException) {
            threw = true
            @Assert((DateTime.now() - t0).toSeconds() >= 1, true)
        }
        @Assert(threw, true)  // 停滞 1s 必须抛超时（per-read 打断）
        client.close()
    }

    // ==================== 场景 5：abort 打断 ====================

    @TestCase
    public func testAbortInterrupt(): Unit {
        let port: UInt16 = 18105
        let _ = startMockServer(port, MockResp.StallAfterHead(0))  // 只发头，不发 body
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 10
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let input = HttpStreamInput(client)
        let buf = Array<Byte>(1024, repeat: 0)
        spawn {
            sleep(Duration.millisecond * 500)
            client.abort()  // 读中关闭连接 → read 结束（抛异常或 EOF 返回 0）
        }
        var ended: Bool = false
        try {
            let r = input.read(buf)
            // abort 后 read 结束：EOF（返回 0）也视为中断生效（close 打断 read）
            if (r <= 0) {
                ended = true
            }
        } catch (e: Exception) {
            ended = true
        }
        @Assert(ended, true)  // abort 打断 read（抛异常或 EOF）
    }

    // ==================== 场景 6：连接关闭 EOF ====================

    @TestCase
    public func testConnectionCloseEof(): Unit {
        let port: UInt16 = 18106
        let body = "partial body then server closes"
        let _ = startMockServer(port, MockResp.CloseEarly(body, 20))  // 发 20 字节后关连接
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let got = readAll(client)
        @Assert(got, body[0..20])  // 20 字节后服务器关闭：剩余数据 + EOF 正常收尾
        client.close()
    }

    // ==================== 场景 7：协议结束标记（[DONE]）提前结束 ====================
    // 服务端发 SSE 帧含 [DONE] 后挂起不关连接（代理 keep-alive 行为）——
    // SseParser 必须在 [DONE] 后立即返回，不等 EOF/空闲超时

    @TestCase
    public func testSseDoneEndsStreamEarly(): Unit {
        let port: UInt16 = 18107
        let _ = startMockServer(port, MockResp.SseDoneNoClose)
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2  // 若未修复：等 EOF 挂起 → 2s 超时
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let parser = SseParser(HttpStreamInput(client))
        let events = ArrayList<String>()
        parser.onEvent = { d => events.add(d) }
        let t0 = DateTime.now()
        parser.run()
        let elapsed = (DateTime.now() - t0).toSeconds()
        @Assert(events.size, 2)          // content 帧 + [DONE] 帧
        @Assert(events[1], "[DONE]")     // DONE 帧已回调
        @Assert(elapsed < 2, true)       // DONE 后立即返回（不等 EOF/超时）
        client.close()
    }

    // ==================== 辅助 ====================

    private func readAll(client: HttpStreamClient): String {
        let input = HttpStreamInput(client)
        let buf = Array<Byte>(4096, repeat: 0)
        var all = Array<Byte>()
        while (true) {
            let n = input.read(buf)
            if (n <= 0) {
                break
            }
            var merged = Array<Byte>(all.size + n, repeat: 0)
            for (i in 0..all.size) {
                merged[i] = all[i]
            }
            for (i in 0..n) {
                merged[all.size + i] = buf[i]
            }
            all = merged
        }
        return safeFromUtf8(all)
    }
}

// ==================== mock server ====================

public enum MockResp {
    | ContentLength(String, Int64)  // body, 分块大小
    | Chunked(String)               // body（分块发送）
    | LongStream(Int64, Int64)      // 总时长 ms, 帧间隔 ms
    | StallAfterHead(Int64)         // 发头后停发（可先发少量数据）
    | CloseEarly(String, Int64)     // body, 发前 N 字节后关连接
    | SseDoneNoClose                 // 发 SSE 帧含 [DONE] 后挂起不关连接（模拟代理 keep-alive）
}

/**
 * 启动 mock server：主线程 bind（监听就绪后返回），spawn 线程 accept + 发响应。
 * 避免 spawn 调度延迟导致 client connect 被拒（Connection refused 竞态）。
 */
public func startMockServer(port: UInt16, resp: MockResp): TcpServerSocket {
    let server = TcpServerSocket(bindAt: port)
    server.bind()
    spawn {
        let conn = server.accept()
        try {
            handleMockResp(conn, resp)
        } catch (e: Exception) {
            // 客户端提前关闭等异常忽略
        }
        try {
            conn.close()
            server.close()
        } catch (e: Exception) {
            // 忽略
        }
    }
    return server
}

public func handleMockResp(conn: StreamingSocket, resp: MockResp): Unit {
    match (resp) {
        case ContentLength(body, chunkSize) =>
            conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.size}\r\n\r\n").toArray())
            writeInChunks(conn, body, chunkSize, Duration.millisecond * 5)
        case Chunked(body) =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            // 整帧一块发送（真实 SSE：每事件一个 chunk）；UTF-8 中文完整验证
            let bytes = body.toArray()
            conn.write((toHex(Int64(bytes.size)) + "\r\n").toArray())
            conn.write(bytes)
            conn.write("\r\n".toArray())
            conn.write("0\r\n\r\n".toArray())
        case LongStream(totalMs, frameMs) =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            let t0 = DateTime.now()
            while ((DateTime.now() - t0).toMilliseconds() < totalMs) {
                let payload = "frame-data-${(DateTime.now() - t0).toMilliseconds()}-0123456789\n"
                let pbytes = payload.toArray()
                conn.write((toHex(Int64(pbytes.size)) + "\r\n").toArray())
                conn.write(pbytes)
                conn.write("\r\n".toArray())
                sleep(Duration.millisecond * frameMs)
            }
            conn.write("0\r\n\r\n".toArray())
        case StallAfterHead(warmBytes) =>
            conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100000\r\n\r\n").toArray())
            if (warmBytes > 0) {
                var i: Int64 = 0
                while (i < warmBytes) {
                    let n = if (100 < warmBytes - i) { 100 } else { warmBytes - i }
                    conn.write(Array<Byte>(n, repeat: 65u8))
                    i += n
                    sleep(Duration.millisecond * 10)
                }
                // 之后停发
                sleep(Duration.second * 30)
            } else {
                // 直接停发 30s（client readTimeout 10s 内 abort 打断）
                sleep(Duration.second * 30)
            }
        case CloseEarly(body, sendBytes) =>
            conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.size}\r\n\r\n").toArray())
            let bytes = body.toArray()
            let n = if (sendBytes < Int64(bytes.size)) { sendBytes } else { Int64(bytes.size) }
            conn.write(bytes[0..n])
            conn.close()  // 发部分后关连接
        case SseDoneNoClose =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            let frame = "data: {\"content\":\"hi\"}\n\ndata: [DONE]\n\n"
            let fbytes = frame.toArray()
            conn.write((toHex(Int64(fbytes.size)) + "\r\n").toArray())
            conn.write(fbytes)
            conn.write("\r\n".toArray())
            // 不发 0 长度 chunk、不关连接：挂起（模拟代理 keep-alive）
            // SseParser 必须在 [DONE] 帧后提前结束，不等 EOF/超时
            sleep(Duration.second * 30)
    }
}

public func writeInChunks(conn: StreamingSocket, body: String, chunkSize: Int64, gap: Duration): Unit {
    let bytes = body.toArray()
    var i: Int64 = 0
    while (i < Int64(bytes.size)) {
        let n = if (chunkSize < Int64(bytes.size) - i) { chunkSize } else { Int64(bytes.size) - i }
        conn.write(bytes[i..(i + n)])
        i += n
        sleep(gap)
    }
}

public func toHex(n: Int64): String {
    if (n == 0) {
        return "0"
    }
    // 注意：仓颉 String[Int64] 下标返回 Byte，Byte.toString() 是十进制数字串
    // （如 '4' → "52"）——必须用 toRuneArray() 取字符
    let digits = "0123456789abcdef".toRuneArray()
    var v = n
    var chars = ArrayList<String>()
    while (v > 0) {
        chars.add(digits[(v % 16)].toString())
        v = v / 16
    }
    var sb = StringBuilder()
    for (i in 0..chars.size) {
        sb.append(chars[chars.size - 1 - i])
    }
    return sb.toString()
}
