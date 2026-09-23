package cjutil

/**
 * httpClientFetch / httpClientRequest 单元测试
 *
 * 覆盖 stdx readTimer WARN 规避契约（见 http_client.cj 文件头 / 踩坑记录 §3.17）：
 *  1. 主路径：2xx → status=200 + body 原样返回（UTF-8 中文不坏码）+ 客户端 close
 *  2. 错误路径：非 2xx 早退（不排空响应体）→ status 原样 + body 空 + 客户端必须 close
 *  3. 边界：响应头停滞 → TimeoutException，且在"包装超时"到点（远早于 readTimeout+10s）
 *  4. 错误路径：连接被拒 → status=0，不抛异常
 *  5. 边界：extraHeaders 给出的 Accept 覆盖默认头（不重复设置）
 */

import std.net.*
import std.sync.*
import std.time.*
import std.collection.*

// ==================== mock server 探针 ====================

/** 记录 mock server 观察到的事实（跨线程读，Mutex 守护） */
class MockProbe {
    private let m = Mutex()
    private var eofSeen = false
    private var reqHeaders = ""

    func markEof(): Unit {
        m.lock()
        try {
            eofSeen = true
        } finally {
            m.unlock()
        }
    }

    func setHeaders(h: String): Unit {
        m.lock()
        try {
            reqHeaders = h
        } finally {
            m.unlock()
        }
    }

    func eof(): Bool {
        m.lock()
        try {
            return eofSeen
        } finally {
            m.unlock()
        }
    }

    func headers(): String {
        m.lock()
        try {
            return reqHeaders
        } finally {
            m.unlock()
        }
    }
}

/**
 * 启动 mock server：主线程 bind（监听就绪后返回），spawn 线程 accept + 应答
 *
 * mode：
 *   - "ok"    200 + bodyText
 *   - "500"   500 + bodyText（响应体不排空的早退场景）
 *   - "stall" 读到头后不发任何字节（响应头停滞）
 */
func startFetchMock(port: UInt16, mode: String, bodyText: String, probe: MockProbe): TcpServerSocket {
    let server = TcpServerSocket(bindAt: port)
    server.bind()
    spawn {
        try {
            let conn = server.accept()
            probe.setHeaders(readReqHeaders(conn))
            if (mode == "stall") {
                waitEof(conn, probe)
            } else {
                let bodyBytes = bodyText.toArray()
                let statusLine = if (mode == "500") {
                    "HTTP/1.1 500 Internal Server Error"
                } else {
                    "HTTP/1.1 200 OK"
                }
                conn.write(("${statusLine}\r\nContent-Type: application/json\r\nContent-Length: ${bodyBytes.size}\r\n\r\n").toArray())
                conn.write(bodyBytes)
                waitEof(conn, probe)
            }
        } catch (e: Exception) {
            // 客户端提前关闭等异常忽略
        }
        try {
            server.close()
        } catch (e: Exception) {
            // 忽略
        }
    }
    return server
}

/** 读到请求头结束（\r\n\r\n）；逐块整段解码，禁止逐字节 append(Byte)（会输出十进制） */
func readReqHeaders(conn: StreamingSocket): String {
    let sb = StringBuilder()
    let buf = Array<Byte>(1024, repeat: UInt8(0))
    var done = false
    while (!done) {
        let n = conn.read(buf)
        if (n <= 0) { break }
        let chunk = Array<Byte>(n, repeat: UInt8(0))
        for (i in 0..n) {
            chunk[i] = buf[i]
        }
        let s = safeFromUtf8(chunk)
        sb.append(s)
        if (s.contains("\r\n\r\n")) { done = true }
    }
    return sb.toString()
}

/** 等客户端关闭连接（read 返回 <=0 或抛异常都算 EOF） */
func waitEof(conn: StreamingSocket, probe: MockProbe): Unit {
    let buf = Array<Byte>(256, repeat: UInt8(0))
    try {
        while (true) {
            let n = conn.read(buf)
            if (n <= 0) { break }
        }
    } catch (e: Exception) {
        // 连接被重置也视为客户端已关闭
    }
    probe.markEof()
}

/** 轮询等待条件成立（最多 timeoutMs） */
func waitUntilTrue(cond: () -> Bool, timeoutMs: Int64): Bool {
    let t0 = DateTime.now()
    while ((DateTime.now() - t0).toMilliseconds() < timeoutMs) {
        if (cond()) { return true }
        sleep(Duration.millisecond * 20)
    }
    return cond()
}

// ==================== 用例 ====================

@Test
public class HttpClientFetchTest {

    /** 主路径：2xx → status + body 原样返回（UTF-8 中文不坏码）+ 客户端 close */
    @TestCase
    public func testOkReturnsBodyAndCloses(): Unit {
        let port: UInt16 = 18921
        let probe = MockProbe()
        let body = "{\"msg\":\"中文内容\"}"
        let _ = startFetchMock(port, "ok", body, probe)

        let r = httpClientFetch("GET", "http://127.0.0.1:${port}/ok", 5, 65536, "cjh-test", "en-US", None, None)
        @Assert(r.status, 200)
        @Assert(r.isOk(), true)
        @Assert(r.body, body)
        // 读完后客户端必须关闭连接，否则遗留 stdx readTimer 会打 WARN 污染 TUI
        @Assert(waitUntilTrue({ => probe.eof() }, 3000), true)
    }

    /** 错误路径：非 2xx 早退（不排空响应体）→ 状态原样 + body 空 + 客户端必须 close */
    @TestCase
    public func testNon2xxEarlyReturnCloses(): Unit {
        let port: UInt16 = 18922
        let probe = MockProbe()
        let _ = startFetchMock(port, "500", "server-error", probe)

        let r = httpClientFetch("GET", "http://127.0.0.1:${port}/err", 5, 65536, "cjh-test", "en-US", None, None)
        @Assert(r.status, 500)
        @Assert(r.isOk(), false)
        @Assert(r.body, "")
        // 这一条是所有 WARN 泄漏的主路径：早退不 close → readTimeout 后 readTimer 必响
        @Assert(waitUntilTrue({ => probe.eof() }, 3000), true)
    }

    /** 简化接口：非 2xx 对外返回空字符串 */
    @TestCase
    public func testRequestWrapperReturnsEmptyOnNon2xx(): Unit {
        let port: UInt16 = 18923
        let probe = MockProbe()
        let _ = startFetchMock(port, "500", "server-error", probe)

        let body = httpClientRequest("GET", "http://127.0.0.1:${port}/err", 5, 65536, "cjh-test", "en-US", None, None)
        @Assert(body, "")
        @Assert(waitUntilTrue({ => probe.eof() }, 3000), true)
    }

    /** 边界：响应头停滞 → TimeoutException，且在包装超时（2s）到点，而非客户端 readTimeout（12s） */
    @TestCase
    public func testStallTimesOutAtWrapperDeadline(): Unit {
        let port: UInt16 = 18924
        let probe = MockProbe()
        let _ = startFetchMock(port, "stall", "", probe)

        var timedOut = false
        let t0 = DateTime.now()
        try {
            let _ = httpClientFetch("GET", "http://127.0.0.1:${port}/stall", 2, 65536, "cjh-test", "en-US", None, None)
        } catch (e: TimeoutException) {
            timedOut = true
        }
        let ms = (DateTime.now() - t0).toMilliseconds()
        @Assert(timedOut, true)
        // 包装超时 2s 生效；若退化成依赖客户端 readTimeout(2+10s) 会 ≥12s
        @Assert(ms < 10000, true)
        // 头已收到 → 连接确实建起来了（不是连接失败导致的假超时）
        @Assert(probe.headers().contains("GET /stall"), true)
    }

    /** 错误路径：端口无监听 → status=0，不抛异常 */
    @TestCase
    public func testConnectRefusedReturnsStatusZero(): Unit {
        let port: UInt16 = 18929
        let r = httpClientFetch("GET", "http://127.0.0.1:${port}/none", 5, 65536, "cjh-test", "en-US", None, None)
        @Assert(r.status, 0)
        @Assert(r.isOk(), false)
        @Assert(httpClientRequest("GET", "http://127.0.0.1:${port}/none", 5, 65536, "cjh-test", "en-US", None, None), "")
    }

    /** 边界：extraHeaders 给出的 Accept 覆盖默认头，默认 Accept 不重复出现 */
    @TestCase
    public func testExtraHeadersOverrideDefaultAccept(): Unit {
        let port: UInt16 = 18926
        let probe = MockProbe()
        let _ = startFetchMock(port, "ok", "{}", probe)

        let hdrs = HashMap<String, String>()
        hdrs["Accept"] = "application/json"
        hdrs["Content-Type"] = "application/json"
        let r = httpClientFetch("POST", "http://127.0.0.1:${port}/api", 5, 65536, "cjh-test", "en-US", Some("{}"), Some(hdrs))
        @Assert(r.status, 200)

        @Assert(waitUntilTrue({ => probe.headers().size > 0 }, 3000), true)
        // stdx 在线上把头名小写化 → 用小写比较
        let got = probe.headers().toAsciiLower()
        @Assert(got.contains("accept: application/json"), true)
        // JSON API 不得被塞上默认的 text/html Accept
        @Assert(got.contains("text/html"), false)
        @Assert(got.contains("content-type: application/json"), true)
    }

    /**
     * 边界：timeout≤0（配置解析不校验时可出现的宽松值）仍必须在"包装超时"到点收场
     *
     * 回归防护对象：`future.get(Duration.second * 0)` 会退化成无限等待 → 只能等客户端
     * 自己的 readTimeout(0+10s) 收场，届时 stdx 的 readTimer 先响并打出
     * `[ConnNode#sendRequestTimeout readTimer] Client1.1 read response timeout`（污染 TUI 输入栏）。
     */
    @TestCase
    public func testNonPositiveTimeoutStillTimesOutAtWrapperDeadline(): Unit {
        let port: UInt16 = 18925
        let probe = MockProbe()
        let _ = startFetchMock(port, "stall", "", probe)

        var timedOut = false
        let t0 = DateTime.now()
        try {
            let _ = httpClientFetch("GET", "http://127.0.0.1:${port}/stall", 0, 65536, "cjh-test", "en-US", None, None)
        } catch (e: TimeoutException) {
            timedOut = true
        }
        let ms = (DateTime.now() - t0).toMilliseconds()
        // 钳制到 1s → 包装超时生效；若退化则要等到 readTimer(10s) 且不抛异常
        @Assert(timedOut, true)
        @Assert(ms < 5000, true)
        @Assert(probe.headers().contains("GET /stall"), true)
    }

    /** 纯函数边界：超时归一化（≤0 → 1s 下限；极大值 → 86400s 上限，防 Duration 乘法溢出） */
    @TestCase
    public func testNormalizeTimeoutSeconds(): Unit {
        @Assert(normalizeTimeoutSeconds(0), 1)
        @Assert(normalizeTimeoutSeconds(-5), 1)
        @Assert(normalizeTimeoutSeconds(1), 1)
        @Assert(normalizeTimeoutSeconds(30), 30)
        @Assert(normalizeTimeoutSeconds(86400), 86400)
        @Assert(normalizeTimeoutSeconds(86401), 86400)
        @Assert(normalizeTimeoutSeconds(9223372036854775807), 86400)
    }
}
