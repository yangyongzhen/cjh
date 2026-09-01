package cjllm

/**
 * 流式 HTTP/1.1 客户端（std.net 直连 + stdx.net.tls）
 *
 * 解决 stdx.net.http 的整体 readTimeout 问题（长任务/停滞只能二选一）：
 *   - per-read readTimeout：每次 read 等待数据 N 秒，无数据抛 SocketTimeoutException
 *     → 流式空闲检测在 read 层天然实现：长任务帧不断则永不超时，停滞 N 秒立即停
 *   - HTTPS：TlsSocket 握手（SNI + 系统证书验证）
 *   - HTTP/1.1：请求构造 + 响应解析（status/headers/content-length/chunked）
 *
 * 使用（流式）：
 *   let c = HttpStreamClient(host, port, useTls)
 *   c.connect()
 *   c.request("POST", "/v1/chat/completions", headers, body)
 *   let (status, hdrs) = c.readResponseHead()
 *   let input = HttpStreamInput(c)   // InputStream 适配（供 SseParser）
 *   ... input.read(buf) 流式读 ...
 *
 * 异常语义：
 *   - SocketTimeoutException：read 超时（N 秒无数据 = 流空闲/停滞）
 *   - ConnectionException：连接关闭/协议错误
 */

import std.net.*
import std.io.*
import std.time.*
import std.collection.*
import std.convert.Parsable
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate

/**
 * HTTP 传输层异常（连接关闭/协议错误）
 */
public class HttpTransportException <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/**
 * 用户中断（cancelChecker 命中）抛出：区别于网络错误/超时，
 * 上层据此标记"已中断"而非"LLM 调用异常"
 */
public class StreamInterruptedException <: Exception {
    public init() {
        super("stream interrupted by user")
    }
}

/**
 * 流式 HTTP/1.1 客户端
 */
public class HttpStreamClient {
    private let host: String
    private let port: UInt16
    private let useTls: Bool
    private let tlsConfig: ?TlsClientConfig
    private var socket: ?StreamingSocket = None
    // 读缓冲（socket 读入整块，readBody 逐字节/逐段消费）
    private var readBuf: Array<Byte> = Array<Byte>(16384, repeat: 0)
    private var readLen: Int64 = 0
    private var readPos: Int64 = 0
    // 响应状态
    private var headRead: Bool = false
    private var statusCode: Int32 = 0
    private var headers: HashMap<String, String> = HashMap<String, String>()
    private var contentLength: Int64 = -1
    private var isChunked: Bool = false
    private var bodyConsumed: Int64 = 0
    private var chunkRemain: Int64 = 0
    private var eof: Bool = false
    // 响应自然读完（0-chunk/content-length/EOF）后可复用（HTTP/1.1 keep-alive）；
    // abort/异常后不可复用
    private var reusable: Bool = false
    // 短读轮询间隔（默认 5s，与 SseParser.POLL_INTERVAL 一致）：
    // 每次 read 至多阻塞该时长——中断（cancelChecker）与空闲预算在短超时后检查，
    // 不依赖 abort() 能否打断阻塞 read（TLS close 语义未验证）
    public var readTimeout: Duration = SseParser.POLL_INTERVAL
    // 中断轮询（上层注入 isCancelled）：短读超时后检查，命中抛 StreamInterruptedException
    public var cancelChecker: () -> Bool = { => false }
    // 建连/响应头阶段的宽容预算（非流式：慢代理/慢握手正常，默认 180s；
    // 超预算抛 SocketTimeoutException = 网络停滞）
    public var idleTimeout: Duration = Duration.second * 180

    /**
     * @param host 目标主机
     * @param port 端口（HTTPS 443）
     * @param useTls 是否 TLS（HTTPS）
     */
    public init(host: String, port: UInt16, useTls: Bool) {
        this.host = host
        this.port = port
        this.useTls = useTls
        this.tlsConfig = None
    }

    /**
     * @param host 目标主机
     * @param port 端口
     * @param useTls 是否 TLS
     * @param tlsConfig TLS 配置（SNI/证书验证；None 用系统证书 + host 做 SNI）
     */
    public init(host: String, port: UInt16, useTls: Bool, tlsConfig: TlsClientConfig) {
        this.host = host
        this.port = port
        this.useTls = useTls
        this.tlsConfig = Some(tlsConfig)
    }

    /**
     * 建立连接（TCP + 可选 TLS 握手），设置 per-read 超时
     */
    public func connect(): Unit {
        let sock = TcpSocket(this.host, this.port)
        sock.connect()
        if (this.useTls) {
            var cfg: TlsClientConfig
            match (this.tlsConfig) {
                case Some(c) => cfg = c
                case None =>
                    var c = TlsClientConfig()
                    c.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
                    c.domain = Some(this.host)
                    cfg = c
            }
            let tls = TlsSocket.client(sock, session: None, clientConfig: cfg)
            // 握手：宽容预算（建连不是流式，慢代理正常）；完成后切短读轮询
            tls.readTimeout = this.idleTimeout
            tls.handshake()
            tls.readTimeout = this.readTimeout
            this.socket = Some(tls)
        } else {
            sock.readTimeout = this.readTimeout
            this.socket = Some(sock)
        }
    }

    /**
     * 发送 HTTP/1.1 请求
     * @param method GET/POST 等
     * @param path 路径（如 /v1/chat/completions）
     * @param headers 请求头（Host 自动补）
     * @param body 请求体（自动 Content-Length）
     */
    public func request(method: String, path: String, headers: ArrayList<(String, String)>, body: String): Unit {
        var req = StringBuilder()
        req.append("${method} ${path} HTTP/1.1\r\n")
        var hasHost: Bool = false
        for ((k, v) in headers) {
            req.append("${k}: ${v}\r\n")
            if (k == "Host") {
                hasHost = true
            }
        }
        if (!hasHost) {
            req.append("Host: ${this.host}\r\n")
        }
        req.append("Content-Length: ${body.size}\r\n")
        req.append("\r\n")
        req.append(body)
        let sock = this.socket.getOrThrow()
        sock.write(req.toString().toArray())
    }

    /**
     * 读响应头：返回 (statusCode, headers)
     * @throws ConnectionException 连接关闭
     */
    public func readResponseHead(): (Int32, HashMap<String, String>) {
        // 响应头阶段也做中断轮询 + 宽容预算：
        // - 每次短读超时（readTimeout）后检查 cancelChecker——用户 Ctrl+C 在
        //   ≤POLL_INTERVAL 内生效（响应头阶段此前是无轮询盲区，只能等 180s）
        // - 总预算 idleTimeout：慢代理长时间不返回头 = 网络停滞 → 抛超时
        let headStart = DateTime.now()
        var head = StringBuilder()
        while (true) {
            var b: Int64 = 0
            try {
                b = this.readByte()
            } catch (e: SocketTimeoutException) {
                if (this.cancelChecker()) {
                    throw StreamInterruptedException()
                }
                if ((DateTime.now() - headStart).toMilliseconds() > this.idleTimeout.toMilliseconds()) {
                    throw e  // 响应头超预算：网络停滞，交上层报错
                }
                continue  // 未超预算：继续等响应头
            }
            if (b < 0) {
                throw HttpTransportException("连接关闭（读响应头 EOF）")
            }
            head.append(this.byteToChar(b))
            if (head.toString().endsWith("\r\n\r\n")) {
                break
            }
        }
        let lines = head.toString().split("\r\n", -1)
        // 状态行：HTTP/1.1 200 OK
        if (lines.size > 0) {
            let statusParts = lines[0].split(" ", -1)
            if (statusParts.size >= 2) {
                try {
                    this.statusCode = Int32.parse(statusParts[1])
                } catch (e: Exception) {
                    this.statusCode = 0
                }
            }
        }
        this.headers = HashMap<String, String>()
        for (i in 1..lines.size) {
            let line = lines[i]
            if (line.size == 0) {
                continue
            }
            let idx = line.indexOf(":")
            if (idx.isSome()) {
                let k = line[0..idx.getOrThrow()].trimAscii()
                let v = line[(idx.getOrThrow() + 1)..line.size].trimAscii()
                this.headers.add(k, v)
            }
        }
        // 传输语义：chunked or content-length or 连接关闭定界
        let te = this.headers.get("Transfer-Encoding")
        if (te.isSome() && te.getOrThrow().contains("chunked")) {
            this.isChunked = true
            this.contentLength = -1
        } else {
            let cl = this.headers.get("Content-Length")
            if (cl.isSome()) {
                try {
                    this.contentLength = Int64.parse(cl.getOrThrow())
                } catch (e: Exception) {
                    this.contentLength = -1
                }
            } else {
                this.contentLength = -1  // 读至连接关闭
            }
        }
        this.headRead = true
        return (this.statusCode, this.headers)
    }

    /**
     * 流式读响应体（适配 InputStream.read 语义）。
     * @param buf 输出缓冲
     * @return 读取字节数；0 = EOF
     * @throws SocketTimeoutException read 超时（N 秒无数据）
     * @throws ConnectionException 连接关闭（非 EOF 语义）
     */
    public func readBody(buf: Array<Byte>): Int64 {
        if (this.eof) {
            return 0
        }
        if (!this.headRead) {
            this.readResponseHead()
        }
        // content-length 模式：读剩余
        if (!this.isChunked && this.contentLength >= 0) {
            let remain = this.contentLength - this.bodyConsumed
            if (remain <= 0) {
                this.eof = true
                this.reusable = true
                return 0
            }
            let want = if (remain < Int64(buf.size)) { remain } else { Int64(buf.size) }
            let n = this.readRaw(buf, 0, want)
            if (n <= 0) {
                this.eof = true
                return 0
            }
            this.bodyConsumed += n
            if (this.bodyConsumed >= this.contentLength) {
                this.eof = true
                this.reusable = true
            }
            return n
        }
        // chunked 模式：每次调用读一个完整 chunk 后立即返回。
        // 让解析层（SseParser）及时处理已读帧并检测协议结束标记
        // （data: [DONE] / event: message_stop）——若填满 buf 才返回，
        // 服务器在 chunk 间隙挂起（不发 0 长度 chunk）时会阻塞在下一 chunk，
        // SseParser 拿不到已读帧，DONE 检测被无限延迟
        if (this.isChunked) {
            var filled: Int64 = 0
            while (filled < Int64(buf.size)) {
                if (this.chunkRemain <= 0) {
                    // 读下一个 chunk 大小行
                    let sizeLine = this.readLine()
                    if (sizeLine.size == 0) {
                        this.eof = true
                        this.reusable = true
                        return filled  // chunked 结束（0 大小 chunk 后空行）
                    }
                    let hexStr = sizeLine.split(";", -1)[0].trimAscii()
                    let chunkSize = parseHexChunk(hexStr)
                    if (chunkSize == 0) {
                        // 结束 chunk：读尾部 CRLF
                        this.readLine()
                        this.eof = true
                        this.reusable = true
                        return filled
                    }
                    this.chunkRemain = chunkSize
                }
                // 关键修复：单次读取不得超过 buf 剩余空间。
                // 旧实现 want=chunkRemain 对大 chunk（聚合代理单帧 >8KB 常见）越界
                // 写 buf[8192] 抛 IndexOutOfBoundsException → 流被截断 → 内容不完整
                // → 模型被迫续跑 → 轮次空转（实测 13 次越界 + 50 轮强制结束）。
                // 大 chunk 分多次 readBody 返回，chunkRemain 跨调用保留
                let want = if (this.chunkRemain < Int64(buf.size) - filled) {
                    this.chunkRemain
                } else {
                    Int64(buf.size) - filled
                }
                let n = this.readRaw(buf, filled, want)
                if (n <= 0) {
                    this.eof = true
                    this.reusable = true
                    return filled
                }
                filled += n
                this.chunkRemain -= n
                if (this.chunkRemain == 0) {
                    // chunk 数据后 CRLF
                    this.readCRLF()
                    return filled  // 读完一个完整 chunk 立即返回
                }
            }
            return filled
        }
        // 连接关闭定界：直接读
        let n = this.readRaw(buf, 0, Int64(buf.size))
        if (n <= 0) {
            this.eof = true
            this.reusable = true
            return 0
        }
        return n
    }

    /**
     * 中止：关闭连接打断阻塞 read（上层中断时调用）
     */
    public func abort(): Unit {
        this.reusable = false
        match (this.socket) {
            case Some(s) =>
                try {
                    s.close()
                } catch (e: Exception) {
                    // 忽略
                }
            case None => ()
        }
    }

    /**
     * 关闭连接
     */
    public func close(): Unit {
        this.abort()
    }

    /**
     * 响应是否自然读完（可复用：HTTP/1.1 keep-alive 同连接发下个请求）
     */
    public func canReuse(): Bool {
        return this.reusable && this.eof
    }

    /**
     * 复用前重置流状态（保持 socket/TLS 连接，清空响应解析状态）
     * @return true=可复用；false=状态不干净（调用方应关闭重建）
     */
    public func resetForReuse(): Bool {
        if (!this.canReuse()) {
            return false
        }
        this.headRead = false
        this.statusCode = 0
        this.headers = HashMap<String, String>()
        this.contentLength = -1
        this.isChunked = false
        this.bodyConsumed = 0
        this.chunkRemain = 0
        this.eof = false
        this.reusable = false  // 使用中
        this.readPos = 0
        this.readLen = 0
        return true
    }

    /**
     * 读完响应剩余字节（SseParser 因协议结束标记提前 break 时，尾随的
     * 0-chunk/CRLF 还在缓冲里）。成功读到自然结束 → 可存回复用池。
     * 短超时保护：读不出（代理 keep-alive 已挂/停滞）→ 不可复用。
     */
    public func drainToEnd(limit: Duration): Bool {
        if (this.eof) {
            this.reusable = true
            return true
        }
        let deadline = DateTime.now() + limit
        var buf = Array<Byte>(4096, repeat: 0)
        while (!this.eof) {
            if (DateTime.now() > deadline) {
                return false  // 超时：不可复用
            }
            try {
                let n = this.readBody(buf)
                if (n <= 0) {
                    break
                }
            } catch (e: Exception) {
                return false  // 读失败（含短超时）：不可复用
            }
        }
        this.reusable = true
        return true
    }

    // ==================== 内部：原始读 + 缓冲 ====================

    /**
     * 从缓冲读；缓冲空则从 socket 读（per-read 超时）
     */
    private func fillBuffer(): Int64 {
        if (this.readPos < this.readLen) {
            return this.readLen - this.readPos
        }

        // 缓冲耗尽：重新读
        this.readPos = 0
        this.readLen = 0
        let sock = this.socket.getOrThrow()
        var n: Int64 = 0
        try {
            n = sock.read(this.readBuf)
        } catch (e: SocketTimeoutException) {
            // 短读超时：先查用户中断（命中 → 明确中断，不误判为网络停滞）
            if (this.cancelChecker()) {
                throw StreamInterruptedException()
            }
            throw e  // 否则按超时交给上层（parser 空闲预算 / 响应头重试）
        } catch (e: SocketException) {
            // 对端异常关闭（Connection reset）：已收数据在缓冲里先消费，
            // 缓冲耗尽后按 EOF 处理——流式尾部 reset 不算错误
            return 0
        }

        if (n <= 0) {
            return 0  // EOF
        }
        this.readLen = n
        return n
    }

    /**
     * 读原始字节到 buf[off..off+len)，返回实际读取（可能 < len 当 EOF）
     */
    private func readRaw(buf: Array<Byte>, off: Int64, len: Int64): Int64 {
        var filled: Int64 = 0
        while (filled < len) {
            let avail = this.fillBuffer()
            if (avail <= 0) {
                break  // EOF
            }
            let take = if (avail < len - filled) { avail } else { len - filled }
            for (i in 0..take) {
                buf[off + filled + i] = this.readBuf[this.readPos + i]
            }
            this.readPos += take
            filled += take
        }
        return filled
    }

    /**
     * 读单字节；EOF 返回 -1
     */
    private func readByte(): Int64 {
        let avail = this.fillBuffer()
        if (avail <= 0) {
            return -1
        }
        let b = Int64(this.readBuf[this.readPos])
        this.readPos += 1
        return b
    }

    /**
     * 读一行（到 \n；剥 \r\n）
     */
    private func readLine(): String {
        var sb = StringBuilder()
        while (true) {
            let b = this.readByte()
            if (b < 0) {
                return sb.toString()
            }
            if (b == 10) {  // \n
                // 剥尾部 \r
                let s = sb.toString()
                if (s.endsWith("\r")) {
                    return s[0..s.size - 1]
                }
                return s
            }
            sb.append(this.byteToChar(b))
        }
        return sb.toString()
    }

    /**
     * 读并丢弃 CRLF（chunk 数据尾部）
     */
    private func readCRLF(): Unit {
        let b1 = this.readByte()
        if (b1 == 13) {  // \r
            let b2 = this.readByte()
            if (b2 == 10) {  // \n
                return
            }
            if (b2 >= 0) {
                // 非 \n：回退？简化忽略（容忍）
            }
            return
        }
        if (b1 == 10) {
            return  // 容忍裸 \n
        }
        // 非 CRLF：忽略（容忍不严格 chunk 结尾）
    }

    private func byteToChar(b: Int64): String {
        return Rune(Int32(b)).toString()
    }
}

/**
 * InputStream 适配器：把 HttpStreamClient.readBody 暴露为 InputStream.read，
 * 供 SseParser 等流式解析器复用（保持现有解析逻辑不变）
 */
public class HttpStreamInput <: InputStream {
    private let client: HttpStreamClient

    public init(client: HttpStreamClient) {
        this.client = client
    }

    public override func read(buf: Array<Byte>): Int64 {
        return this.client.readBody(buf)
    }
}

/**
 * 解析 chunked 十六进制块大小
 */
public func parseHexChunk(s: String): Int64 {
    var v: Int64 = 0
    for (r in s.toRuneArray()) {
        let c = UInt32(r)
        var d: Int64 = -1
        if (c >= 48 && c <= 57) {
            d = Int64(c - 48)
        } else if (c >= 97 && c <= 102) {
            d = Int64(c - 97 + 10)
        } else if (c >= 65 && c <= 70) {
            d = Int64(c - 65 + 10)
        }
        if (d < 0) {
            break
        }
        v = v * 16 + d
    }
    return v
}

/**
 * 拆分端点 URL → (host, port, path, useTls)
 * 例：https://api.deepseek.com/v1/chat/completions → ("api.deepseek.com", 443, "/v1/chat/completions", true)
 * 例：http://localhost:11434/v1/chat/completions → ("localhost", 11434, "/v1/chat/completions", false)
 */
public func splitEndpoint(url: String): (String, UInt16, String, Bool) {
    var rest = url
    var useTls: Bool = true
    if (rest.startsWith("https://")) {
        rest = rest[8..rest.size]
        useTls = true
    } else if (rest.startsWith("http://")) {
        rest = rest[7..rest.size]
        useTls = false
    }
    var host = rest
    var port: UInt16 = if (useTls) { 443 } else { 80 }
    var path = "/"
    if (let Some(slash) <- rest.indexOf("/")) {
        host = rest[0..slash]
        path = rest[slash..rest.size]
    }
    if (let Some(colon) <- host.indexOf(":")) {
        let portStr = host[(colon + 1)..host.size]
        host = host[0..colon]
        try {
            port = UInt16.parse(portStr)
        } catch (e: Exception) {
            // 端口解析失败用默认
        }
    }
    return (host, port, path, useTls)
}

/**
 * 流式空闲超时（per-read readTimeout）默认值
 *
 * 读取 CJH_IDLE_TIMEOUT_SECS（默认 180s）。
 * 背景：第三方代理（如 taotoken.net）会缓冲 SSE 响应，模型思考/长生成阶段
 * 客户端可能长时间无帧；60s 太激进会误切正常任务。180s 覆盖绝大多数
 * 思考+代理缓冲场景，真实停滞 3min 内网络恢复亦覆盖。
 */
/**
 * 流式空闲超时（per-read readTimeout）默认值
 *
 * 读取 CJH_IDLE_TIMEOUT_SECS（默认 180s）。
 * 背景：第三方代理（如 taotoken.net）会缓冲 SSE 响应，模型思考/长生成阶段
 * 客户端可能长时间无帧；60s 太激进会误切正常任务。180s 覆盖绝大多数
 * 思考+代理缓冲场景，真实停滞 3min 内网络恢复亦覆盖。
 */
public func defaultIdleTimeout(): Duration {
    // 默认 60s：内容已输出后 60s 无帧即视为停滞（timedOut 语义已改为
    // 内容保留不重试，短预算不会丢内容）。此前 180s 是配合"timedOut 重试"
    // 防误切——重试已移除，60s 安全且用户感知响应快
    var secs: Int64 = 60
    try {
        unsafe {
            // 复用 cjllm 包级 FFI getenv（见 mock.cj），零依赖
            let p = getenv(LibC.mallocCString("CJH_IDLE_TIMEOUT_SECS"))
            if (!p.isNull()) {
                let v = CString(p).toString()
                if (v.size > 0) {
                    let parsed = Int64.parse(v)
                    if (parsed >= 10) {
                        secs = parsed
                    }
                }
            }
        }
    } catch (e: Exception) {
        // 非法配置用默认
    }
    return Duration.second * secs
}
