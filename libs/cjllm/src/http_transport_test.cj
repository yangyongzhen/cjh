package cjllm

import std.net.*
import std.time.*
import std.collection.*

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
        spawn {
            runMockServer(port, MockResp.ContentLength(body, 5))
        }
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
        spawn {
            runMockServer(port, MockResp.Chunked(body))
        }
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
        spawn {
            runMockServer(port, MockResp.LongStream(3000, 40))
        }
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
        spawn {
            runMockServer(port, MockResp.StallAfterHead(2000))  // 发头 + 少量数据后停发
        }
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
        spawn {
            runMockServer(port, MockResp.StallAfterHead(0))  // 只发头，不发 body
        }
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 10
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let input = HttpStreamInput(client)
        let buf = Array<Byte>(1024, repeat: 0)
        spawn {
            sleep(Duration.milliSecond * 500)
            client.abort()  // 读中关闭连接 → read 应抛异常
        }
        var threw: Bool = false
        try {
            input.read(buf)
            @Assert(true, false)  // abort 后 read 不应正常返回数据
        } catch (e: Exception) {
            threw = true
        }
        @Assert(threw, true)
    }

    // ==================== 场景 6：连接关闭 EOF ====================

    @TestCase
    public func testConnectionCloseEof(): Unit {
        let port: UInt16 = 18106
        let body = "partial body then server closes"
        spawn {
            runMockServer(port, MockResp.CloseEarly(body, 20))  // 发 20 字节后关连接
        }
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let got = readAll(client)
        @Assert(got, body)  // 剩余数据完整读完 + EOF 正常结束
        client.close()
    }

    // ==================== 辅助 ====================

    private func readAll(client: HttpStreamClient): String {
        let input = HttpStreamInput(client)
        let buf = Array<Byte>(4096, repeat: 0)
        var sb = StringBuilder()
        while (true) {
            let n = input.read(buf)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                sb.append(Rune(Int32(buf[i])).toString())
            }
        }
        return sb.toString()
    }
}

// ==================== mock server ====================

public enum MockResp {
    | ContentLength(String, Int64)  // body, 分块大小
    | Chunked(String)               // body（分块发送）
    | LongStream(Int64, Int64)      // 总时长 ms, 帧间隔 ms
    | StallAfterHead(Int64)         // 发头后停发（可先发少量数据）
    | CloseEarly(String, Int64)     // body, 发前 N 字节后关连接
}

public func runMockServer(port: UInt16, resp: MockResp): Unit {
    let server = TcpServerSocket(bindAt: port)
    server.bind()
    let conn = server.accept()
    match (resp) {
        case ContentLength(body, chunkSize) =>
            conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.size}\r\n\r\n").toArray())
            writeInChunks(conn, body, chunkSize, Duration.milliSecond * 5)
        case Chunked(body) =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            var i: Int64 = 0
            let bytes = body.toArray()
            while (i < Int64(bytes.size)) {
                let n = if (4 < Int64(bytes.size) - i) { 4 } else { Int64(bytes.size) - i }
                conn.write((toHex(n) + "\r\n").toArray())
                conn.write(bytes[i..(i + n)])
                conn.write("\r\n".toArray())
                i += n
            }
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
                sleep(Duration.milliSecond * frameMs)
            }
            conn.write("0\r\n\r\n".toArray())
        case StallAfterHead(warmBytes) =>
            conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100000\r\n\r\n").toArray())
            if (warmBytes > 0) {
                var i: Int64 = 0
                while (i < warmBytes) {
                    let n = if (100 < warmBytes - i) { 100 } else { warmBytes - i }
                    conn.write(Array<Byte>(n, repeat: Byte(65)))
                    i += n
                    sleep(Duration.milliSecond * 10)
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
    }
    conn.close()
    server.close()
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
    let digits = "0123456789abcdef"
    var sb = StringBuilder()
    var v = n
    while (v > 0) {
        sb.append(digits[(v % 16)].toString())
        v = v / 16
    }
    return sb.toString().reversed()
}
