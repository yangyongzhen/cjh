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

    // ==================== 场景 8：finish_reason 提前结束（无 [DONE]） ====================
    // 聚合网关透传 OpenAI 帧但省略 [DONE]、keep-alive 不关连接——
    // SseParser 必须在 finish_reason="stop" 帧后立即返回，不等 EOF/空闲超时
    // （"任务完成但 Streaming 不停 → 新消息排队"的根治用例）

    @TestCase
    public func testSseFinishReasonEndsStreamEarly(): Unit {
        let port: UInt16 = 18108
        let _ = startMockServer(port, MockResp.SseFinishReasonNoClose)
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
        @Assert(events.size, 2)                  // content 帧 + finish_reason 帧
        @Assert(elapsed < 2, true)               // finish_reason 后立即返回（不等 EOF/超时）
        // 中间帧 finish_reason=null 不结束：事件 0 必须回调（未提前 break）
        @Assert(events[0].contains("hi"), true)
        client.close()
    }

    // ==================== 场景 9：短读轮询——中断不依赖 abort/EOF ====================
    // 服务端发一帧后挂起（无 [DONE]/finish_reason/EOF/关连接）：此时 abort() 若
    // 无法打断阻塞 read（TLS 语义未验证），唯一出路是 read 自身短超时 + 轮询
    // cancelChecker。本用例证明：中断标志翻转后 ≤POLL_INTERVAL+余量 内解析结束。

    @TestCase
    public func testParserCancelWithoutAbort(): Unit {
        let port: UInt16 = 18109
        let _ = startMockServer(port, MockResp.SseStallNoClose)
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1  // 短读轮询（比 5s 更短，测试提速）
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let parser = SseParser(HttpStreamInput(client))
        let cancelAt = DateTime.now() + Duration.second * 1
        parser.cancelChecker = { => DateTime.now() > cancelAt }
        parser.idleTimeout = Duration.second * 30  // 预算远大于测试时长：只有中断能结束
        spawn {
            sleep(Duration.second * 4)  // 保底取消（若 cancelChecker 轮询失效则测试失败）
            parser.cancel()
        }
        let t0 = DateTime.now()
        parser.run()
        let elapsed = (DateTime.now() - t0).toSeconds()
        @Assert(elapsed < 3, true)  // 中断 ≤ 轮询间隔 + 余量生效（不依赖 abort/EOF/close）
        @Assert(parser.timedOut, false)  // 中断不是超时
        client.close()
    }

    // ==================== 场景 10：空闲预算耗尽 → timedOut ====================
    // 停滞超过 idleTimeout（完全无数据）→ timedOut=true（原 readTimeout 语义，
    // 由解析层预算管理，短读本身不误判超时）

    @TestCase
    public func testParserIdleTimeout(): Unit {
        let port: UInt16 = 18110
        let _ = startMockServer(port, MockResp.SseStallNoClose)
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1  // 短读轮询
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let parser = SseParser(HttpStreamInput(client))
        parser.idleTimeout = Duration.second * 1  // 预算 1s：首个短读超时后即耗尽
        let t0 = DateTime.now()
        parser.run()
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(parser.timedOut, true)   // 停滞超预算 → timedOut
        @Assert(elapsed >= 500, true)    // 至少等过第一个短读超时
        @Assert(elapsed < 3000, true)    // 预算耗尽即结束（不等 EOF/close）
        client.close()
    }

    // ==================== 场景 11：响应头阶段中断轮询 ====================
    // 服务端 accept 后不发任何字节（响应头停滞）：Ctrl+C 必须 ≤轮询间隔生效
    // （响应头阶段此前是无轮询盲区——只能等 abort 或 180s 预算）

    @TestCase
    public func testHeadReadInterrupt(): Unit {
        let port: UInt16 = 18111
        let _ = startMockServer(port, MockResp.StallBeforeHead)
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1  // 短读轮询
        client.idleTimeout = Duration.second * 30 // 预算远大于测试时长：只有中断能结束
        let cancelAt = DateTime.now() + Duration.second * 1
        client.cancelChecker = { => DateTime.now() > cancelAt }
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let t0 = DateTime.now()
        var interrupted: Bool = false
        try {
            let _ = client.readResponseHead()
        } catch (e: StreamInterruptedException) {
            interrupted = true  // 明确的中断信号（非网络错误）
        } catch (e: Exception) {
            // 其他异常也算"读被打破"（socket 语义差异），但不如中断信号精确
        }
        let elapsed = (DateTime.now() - t0).toSeconds()
        @Assert(interrupted, true)  // 必须抛 StreamInterruptedException（用户中断）
        @Assert(elapsed < 3, true)  // ≤ 轮询间隔 + 余量
        client.close()
    }

    // ==================== 场景 12：响应头阶段预算耗尽 ====================

    @TestCase
    public func testHeadReadIdleTimeout(): Unit {
        let port: UInt16 = 18112
        let _ = startMockServer(port, MockResp.StallBeforeHead)
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 1  // 短读轮询
        client.idleTimeout = Duration.second * 1 // 响应头预算 1s
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let t0 = DateTime.now()
        var threw: Bool = false
        try {
            let _ = client.readResponseHead()
        } catch (e: Exception) {
            threw = true  // 预算耗尽：抛超时（网络停滞报错）
        }
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(threw, true)
        @Assert(elapsed >= 500, true)
        @Assert(elapsed < 3000, true)
        client.close()
    }

    // ==================== 场景 13：大 chunk 不得越界（回归） ====================
    // 聚合代理单 chunk > SseParser 缓冲(8192)：旧实现 readRaw 越界写 buf[8192]
    // 抛 IndexOutOfBoundsException → 流被截断 → 内容不完整 → 模型续跑空转
    // （实测 13 次越界 + 50 轮强制结束）。大 chunk 必须分多次 readBody 无损读完

    @TestCase
    public func testBigChunkNoOverflow(): Unit {
        let port: UInt16 = 18113
        var big = StringBuilder()
        for (i in 0..9000) {
            big.append("x")  // 9KB 内容 > 8192 缓冲
        }
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"${big.toString()}\"},\"finish_reason\":null}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        let _ = startMockServer(port, MockResp.Chunked(body))  // 整帧单 chunk 发送
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (status, _) = client.readResponseHead()
        @Assert(status, 200)
        let parser = SseParser(HttpStreamInput(client))
        let got = StringBuilder()
        parser.onEvent = { d => got.append(d) }
        parser.run()
        // 内容完整无越界截断；finish_reason 帧也到达（协议提前结束）
        @Assert(got.toString().contains(big.toString()), true)
        @Assert(got.toString().contains("finish_reason"), true)
        client.close()
    }

    // ==================== 场景 14：连接复用（HTTP/1.1 keep-alive） ====================
    // 响应自然读完（drain 到 0-chunk）后同一连接可发下一个请求——省 TCP+TLS 握手

    @TestCase
    public func testConnectionReuse(): Unit {
        let port: UInt16 = 18114
        let _ = startMockServer(port, MockResp.KeepAliveServer(2))
        let client = HttpStreamClient("127.0.0.1", port, false)
        client.readTimeout = Duration.second * 2
        client.connect()
        // 请求 1：流式响应 + [DONE] 提前 break → drain 到自然结束 → 可复用
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (s1, _) = client.readResponseHead()
        @Assert(s1, 200)
        let p1 = SseParser(HttpStreamInput(client))
        p1.run()
        @Assert(client.drainToEnd(Duration.second * 2), true)  // 读完 0-chunk 尾
        @Assert(client.canReuse(), true)
        // 请求 2：同一连接（server 只 accept 一次）
        @Assert(client.resetForReuse(), true)
        client.request("POST", "/v1/chat/completions", ArrayList<(String, String)>(), "{}")
        let (s2, _) = client.readResponseHead()
        @Assert(s2, 200)
        let p2 = SseParser(HttpStreamInput(client))
        let events2 = ArrayList<String>()
        p2.onEvent = { d => events2.add(d) }
        p2.run()
        @Assert(events2.size > 0, true)
        @Assert(events2[0].contains("resp-1"), true)  // 第二个响应内容
        client.close()
    }

    // ==================== 场景 15：Provider 层连接复用 ====================
    // OpenAiProvider 连续两次 chatStream：server 只 accept 一次（证明复用生效）

    @TestCase
    public func testProviderConnectionReuse(): Unit {
        let port: UInt16 = 18115
        let _ = startMockServer(port, MockResp.KeepAliveServer(2))
        let provider = OpenAiProvider("http://127.0.0.1:${port}/v1/chat/completions", "k", "m")
        let got1 = StringBuilder()
        let r1 = provider.chatStream(ArrayList<ChatMessage>(), ArrayList<ToolSpec>(),
            { d => got1.append(d) }, { _ => }, { _ => }, { => false })
        let got2 = StringBuilder()
        let r2 = provider.chatStream(ArrayList<ChatMessage>(), ArrayList<ToolSpec>(),
            { d => got2.append(d) }, { _ => }, { _ => }, { => false })
        @Assert(r1.text.contains("resp-0"), true)
        @Assert(r2.text.contains("resp-1"), true)
        @Assert(got1.toString().contains("resp-0"), true)   // 流式增量回调正常
        @Assert(got2.toString().contains("resp-1"), true)
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
    | SseFinishReasonNoClose         // 只发 finish_reason（无 [DONE]）后挂起不关连接（聚合网关）
    | SseStallNoClose                // 发一帧后挂起（无 [DONE]/finish_reason/EOF）——只有短读轮询能结束
    | StallBeforeHead                // accept 后不发任何字节（响应头阶段停滞）
    | KeepAliveServer(Int64)         // accept 一次，循环处理 n 个请求（HTTP/1.1 keep-alive 复用验证）
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
        case SseFinishReasonNoClose =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            // 聚合网关行为：透传 OpenAI 帧但省略 [DONE]；首块 finish_reason=null，
            // 末块 finish_reason="stop"，之后挂起不关连接
            let frame = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n" +
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            let fbytes = frame.toArray()
            conn.write((toHex(Int64(fbytes.size)) + "\r\n").toArray())
            conn.write(fbytes)
            conn.write("\r\n".toArray())
            // 不发 0 长度 chunk、不关连接：挂起（模拟聚合网关 keep-alive）
            // SseParser 必须在 finish_reason 帧后提前结束（不能等 [DONE]/EOF/超时）
            sleep(Duration.second * 30)
        case SseStallNoClose =>
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            // 发一帧（finish_reason=null，不触发协议结束）后挂起：无 [DONE]、
            // 无 finish_reason、不关连接、不再发数据
            let frame = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n"
            let fbytes = frame.toArray()
            conn.write((toHex(Int64(fbytes.size)) + "\r\n").toArray())
            conn.write(fbytes)
            conn.write("\r\n".toArray())
            // 只有短读轮询（cancelChecker 中断 / 空闲预算超时）能结束解析
            sleep(Duration.second * 30)
        case StallBeforeHead =>
            // accept 后不发任何字节（无 HTTP 响应头）：响应头阶段停滞
            // 只有 readResponseHead 的短读轮询（中断/预算）能结束
            sleep(Duration.second * 30)
        case KeepAliveServer(n) =>
            // 同一连接循环处理 n 个请求：读请求头到 CRLFCRLF 后回 chunked SSE

            var handled: Int64 = 0
            while (handled < n) {
                var req = ""
                var buf = Array<Byte>(4096, repeat: 0)
                while (!req.contains("\r\n\r\n")) {
                    let r = conn.read(buf)
                    if (r <= 0) {
                        return
                    }
                    req += safeFromUtf8(buf[0..r])
                }
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"resp-${handled}\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n"
                conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
                let bytes = body.toArray()
                conn.write((toHex(Int64(bytes.size)) + "\r\n").toArray())
                conn.write(bytes)
                conn.write("\r\n".toArray())
                conn.write("0\r\n\r\n".toArray())
                handled += 1
            }
            sleep(Duration.second * 30)  // 等待客户端关闭
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
