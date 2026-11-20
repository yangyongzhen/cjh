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
import std.convert.*
import std.collection.*
import cjh.tools.*
import cjcfg.*
import cjutil.*

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
