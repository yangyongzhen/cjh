package cjh.tests

/**
 * MCP http 传输会话语义单测（issue #12 对齐 Streamable HTTP 规范）
 *
 * 用本地 mock MCP 服务器（TcpServerSocket，每个 POST 一条新连接）验证：
 *   1. initialize 响应带的 Mcp-Session-Id 被客户端保存
 *   2. 后续请求（tools/list）回传 Mcp-Session-Id 头
 *   3. initialize 之后的所有请求携带 MCP-Protocol-Version 头
 *
 * 网络真实端点不做单测（实机验证为准）。
 */

import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
import std.collection.*
import cjh.tools.*
import cjcfg.*
import cjutil.*

/** 轮询等待条件成立（最多 timeoutMs） */
func waitUntilMcp(cond: () -> Bool, timeoutMs: Int64): Bool {
    let t0 = DateTime.now()
    while ((DateTime.now() - t0).toMilliseconds() < timeoutMs) {
        if (cond()) { return true }
        sleep(Duration.millisecond * 20)
    }
    return cond()
}

/** 推送流测试观察者：记录 GET 请求头与 GET 次数（跨线程，Mutex 守护） */
class McpPushProbe {
    private let m = Mutex()
    private var lastGetHeaders = ""
    private var getCount = 0

    func recordGet(h: String): Unit {
        m.lock()
        try {
            getCount += 1
            lastGetHeaders = h
        } finally {
            m.unlock()
        }
    }

    func headers(): String {
        m.lock()
        try {
            return lastGetHeaders
        } finally {
            m.unlock()
        }
    }

    func count(): Int64 {
        m.lock()
        try {
            return getCount
        } finally {
            m.unlock()
        }
    }
}

/**
 * 推送流 mock 连接处理：
 *   POST → initialize（回 mcp-session-id）/ tools_list（回空 tools）/ 其他回 {}
 *   GET  → 第 1 次：发两条带 id 的 SSE 事件后关闭（触发客户端重连）
 *          第 2 次：记录请求头（应含 Last-Event-ID）后回 405（客户端停止订阅）
 */
func handleMcpPushConn(conn: StreamingSocket, probe: McpPushProbe): Unit {
    let sb = StringBuilder()
    let buf = Array<Byte>(4096, repeat: UInt8(0))
    var head = ""
    while (true) {
        let n = conn.read(buf)
        if (n <= 0) { break }
        let chunk = Array<Byte>(n, repeat: UInt8(0))
        for (i in 0..n) {
            chunk[i] = buf[i]
        }
        sb.append(safeFromUtf8(chunk))
        let s = sb.toString()
        let idx = s.indexOf("\r\n\r\n")
        if (idx.isSome()) {
            head = s[0..idx.getOrThrow()]
            let bodyStart = idx.getOrThrow() + 4
            var contentLen: Int64 = 0
            for (line in head.split("\r\n")) {
                let lower = line.toAsciiLower()
                if (lower.startsWith("content-length:")) {
                    contentLen = Int64.parse(line[15..line.size].trimAscii())
                }
            }
            let have = s.size - bodyStart
            if (have < contentLen) { continue }
            let body = s[bodyStart..s.size]
            let isGet = head.toAsciiLower().startsWith("get")
            if (isGet) {
                let first = probe.count() == 0
                probe.recordGet(head)
                if (first) {
                    let sse = "id: 1\nevent: message\ndata: {\"method\":\"notifications/message\"}\n\nid: 2\nevent: message\ndata: {\"method\":\"notifications/changed\"}\n\n"
                    conn.write(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n").toArray())
                    conn.write(sse.toArray())
                } else {
                    conn.write(("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n").toArray())
                }
            } else if (body.contains("\"initialize\"")) {
                let resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\"}}"
                let respBytes = resp.toArray()
                conn.write(("HTTP/1.1 200 OK\r\nmcp-session-id: push-sess-7\r\nContent-Type: application/json\r\nContent-Length: ${respBytes.size}\r\n\r\n").toArray())
                conn.write(respBytes)
            } else if (body.contains("\"tools/list\"")) {
                let resp = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}"
                let respBytes = resp.toArray()
                conn.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${respBytes.size}\r\n\r\n").toArray())
                conn.write(respBytes)
            } else {
                conn.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}").toArray())
            }
            break
        }
    }
    try { conn.close() } catch (e: Exception) {}
}

@Test
public class McpHttpPushTest {
    /**
     * 端到端：initialize 保存会话 → GET 推送流收到两条事件 → 断线重连带
     * Last-Event-ID → 405 停止订阅 → disconnect 正常收尾
     */
    @TestCase
    public func testPushStreamEventsAndLastEventIdReconnect(): Unit {
        // 端口绑定失败自动换下一端口重试（与 cjutil 探针同款）
        var server: ?TcpServerSocket = None
        var candidate: UInt16 = 18932
        for (_ in 0..20) {
            let s = TcpServerSocket(bindAt: candidate)
            try {
                s.bind()
                server = Some(s)
                break
            } catch (e: Exception) {
                candidate = candidate + 1
            }
        }
        let srv = server.getOrThrow()
        let port = candidate
        let probe = McpPushProbe()
        spawn {
            try {
                while (true) {
                    handleMcpPushConn(srv.accept(), probe)
                }
            } catch (e: Exception) {}
        }

        let cfg = McpServerConfig("mock-push")
        cfg.transport = "http"
        cfg.url = "http://127.0.0.1:${port}/mcp"
        let client = McpClient(cfg)
        @Assert(client.connect(), true)

        // 收到两条推送事件
        @Assert(waitUntilMcp({ => client.getPushedEvents().size >= 2 }, 10000), true)
        let events = client.getPushedEvents()
        @Assert(events.size, 2)
        @Assert(events[0].contains("notifications/message"), true)
        @Assert(events[1].contains("notifications/changed"), true)

        // 断线重连：第 2 次 GET 带上 Last-Event-ID（断点续传），随后 405 停止订阅
        @Assert(waitUntilMcp({ => probe.headers().toAsciiLower().contains("last-event-id: 2") }, 10000), true)
        // 第 2 次 GET 请求头还应带会话 id 与协议版本
        let got = probe.headers().toAsciiLower()
        @Assert(got.contains("mcp-session-id: push-sess-7"), true)
        @Assert(got.contains("mcp-protocol-version: 2025-03-26"), true)

        client.disconnect()  // 停推送流 + DELETE 终止会话，不挂死
    }
}


// mock 服务器观察到的请求头（跨线程，Mutex 守护）
class McpSessionProbe {
    private let m = Mutex()
    private var reqHeaders = ""

    func setHeaders(h: String): Unit {
        m.lock()
        try {
            reqHeaders = h
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

/** 单连接应答：读请求头 + body，按 JSON-RPC method 回包 */
func handleMcpConn(conn: StreamingSocket, probe: McpSessionProbe): Unit {
    let sb = StringBuilder()
    let buf = Array<Byte>(4096, repeat: UInt8(0))
    // 读到 \r\n\r\n（头结束），再按 Content-Length 读 body
    var head = ""
    while (true) {
        let n = conn.read(buf)
        if (n <= 0) { break }
        let chunk = Array<Byte>(n, repeat: UInt8(0))
        for (i in 0..n) {
            chunk[i] = buf[i]
        }
        sb.append(safeFromUtf8(chunk))
        let s = sb.toString()
        let idx = s.indexOf("\r\n\r\n")
        if (idx.isSome()) {
            head = s[0..idx.getOrThrow()]
            let bodyStart = idx.getOrThrow() + 4
            var contentLen: Int64 = 0
            for (line in head.split("\r\n")) {
                let lower = line.toAsciiLower()
                if (lower.startsWith("content-length:")) {
                    contentLen = Int64.parse(line[15..line.size].trimAscii())
                }
            }
            let have = s.size - bodyStart
            if (have < contentLen) { continue }
            let body = s[bodyStart..s.size]
            let isInit = body.contains("\"initialize\"")
            let isList = body.contains("\"tools/list\"")
            let isDelete = head.toAsciiLower().startsWith("delete")
            // 只记录 tools/list 的请求头（DELETE 收尾会覆盖 probe，且它本就不带协议版本头）
            if (isList && !isDelete) {
                probe.setHeaders(head)
            }
            let respBody = if (isInit) {
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\"}}"
            } else if (isList) {
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}"
            } else {
                "{}"
            }
            let respBytes = respBody.toArray()
            let sessionHeader = if (isInit) { "mcp-session-id: sess-abc-99\r\n" } else { "" }
            conn.write(("HTTP/1.1 200 OK\r\n${sessionHeader}Content-Type: application/json\r\nContent-Length: ${respBytes.size}\r\n\r\n").toArray())
            conn.write(respBytes)
            break
        }
    }
    try { conn.close() } catch (e: Exception) {}
}

@Test
public class McpHttpSessionTest {
    /**
     * 主路径：initialize 保存 Mcp-Session-Id → tools/list 回传该头 + MCP-Protocol-Version
     */
    @TestCase
    public func testSessionIdEchoedOnSubsequentRequests(): Unit {
        // 端口绑定失败自动换下一端口重试（与 cjutil 探针同款）
        var server: ?TcpServerSocket = None
        var candidate: UInt16 = 18931
        for (_ in 0..20) {
            let s = TcpServerSocket(bindAt: candidate)
            try {
                s.bind()
                server = Some(s)
                break
            } catch (e: Exception) {
                candidate = candidate + 1
            }
        }
        let srv = server.getOrThrow()
        let port = candidate
        let probe = McpSessionProbe()
        spawn {
            try {
                while (true) {
                    handleMcpConn(srv.accept(), probe)
                }
            } catch (e: Exception) {}
        }

        let cfg = McpServerConfig("mock-http")
        cfg.transport = "http"
        cfg.url = "http://127.0.0.1:${port}/mcp"
        let client = McpClient(cfg)
        @Assert(client.connect(), true)
        let tools = client.listTools()
        @Assert(tools.size, 0)  // mock 回包 tools 为空，走通即视为成功
        client.disconnect()

        let got = probe.headers().toAsciiLower()
        // tools/list 的请求头：会话头回传 + 协议版本头都在
        @Assert(got.contains("mcp-session-id: sess-abc-99"), true)
        @Assert(got.contains("mcp-protocol-version: 2025-03-26"), true)
    }
}
