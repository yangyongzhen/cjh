package cjutil

/**
 * 通用 HTTP 客户端：仓颉原生 ClientBuilder + spawn 超时保护
 *
 * 设计动机：
 *   - 仓颉 ClientBuilder 没有 connectTimeout，目标不可达时卡在 TCP connect，
 *     readTimeout 不触发，导致 68s+ 超时
 *   - 用 spawn 子线程执行 client.send(req)，主线程 future.get(timeout) 带超时等待
 *   - 超时抛 TimeoutException，调用方 catch 后进入降级链
 *
 * 用法：
 *   try {
 *     let html = httpClientGet("https://example.com", 15)
 *     // html 是抓取到的内容
 *   } catch (e: TimeoutException) {
 *     // 超时，进入降级链
 *   } catch (e: Exception) {
 *     // 其他异常
 *   }
 *
 * 原则：
 *   - 不用 curl 子进程（每次 fork 进程，开销大，无法复用连接）
 *   - 保留仓颉原生 HTTP client，只加超时保护层
 *   - 通用基础设施放在 cjutil 包，供所有上层包复用
 *
 * 【stdx readTimer WARN 规避（必守）】
 *   stdx.net.http 的客户端为每个连接挂着 readTimer，一旦超时未取消，就会向
 *   **stdout** 打 `[ConnNode#sendRequestTimeout readTimer] Client1.1 read response
 *   timeout` WARN；该输出绕不过 setGlobalLogger(NoopLogger())，在 TUI 下直接
 *   砸进输入栏。1.0.5 实测结论（见 docs/开发文档与踩坑记录.md §3.17）：
 *     1. 响应体未排空且客户端未 close → readTimeout 后必响（早退非 2xx 的典型泄漏）
 *     2. close() 或排空响应体 → 不响
 *     3. 客户端 readTimeout == 包装 get 超时 → 两边同时到点，close 也来不及，必响
 *   因此两条铁律：
 *     A. 客户端 readTimeout 必须比包装超时留出余量（本文件 +10s）
 *     B. 请求结束路径（成功/失败/超时/早退）必须 close 客户端
 */

import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate

/**
 * HTTP 抓取结果：状态码 + 响应体
 *
 * status = 0 表示未拿到响应（连接失败 / 读取异常 / 超时中断后降级）
 */
public class HttpFetchResult {
    public let status: Int64
    public let body: String

    public init(status: Int64, body: String) {
        this.status = status
        this.body = body
    }

    /** 是否 2xx 成功 */
    public func isOk(): Bool {
        return this.status >= 200 && this.status < 300
    }
}

/**
 * 通用 HTTP 请求（带状态码）：spawn 子线程 + future.get(timeout) 超时保护
 *
 * 支持 GET/POST/任意 method + body + 自定义 headers。
 * 统一保证：包装超时 < 客户端 readTimeout，且所有路径 close 客户端，
 * 因此不会遗留 stdx readTimer（否则 WARN 污染 TUI，见文件头说明）。
 *
 * 参数：
 *   - method: HTTP 方法（"GET" / "POST" 等）
 *   - url: 目标 URL（必须 http:// 或 https://，调用方负责 SSRF 校验）
 *   - timeoutSeconds: 整体超时秒数（包装超时；客户端 readTimeout 自动 +10s 余量）
 *   - maxDownloadBytes: 响应体最大字节数（防 OOM）
 *   - userAgent: User-Agent 头
 *   - acceptLanguage: Accept-Language 头
 *   - body: 请求体（None 表示无请求体）
 *   - extraHeaders: 额外 headers（如 Content-Type / Accept）
 *
 * 返回：HttpFetchResult（status=0 表示未拿到响应）
 * 异常：TimeoutException 超时
 */
public func httpClientFetch(
    method: String,
    url: String,
    timeoutSeconds: Int64,
    maxDownloadBytes: Int64,
    userAgent: String,
    acceptLanguage: String,
    body: ?String,
    extraHeaders: ?Map<String, String>
): HttpFetchResult {
    // 配置 TLS
    var tlsConfig = TlsClientConfig()
    tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
    let host = extractHostFromUrl(url)
    if (host.size > 0) {
        tlsConfig.domain = Some(host)
    }

    // 构建客户端
    // readTimeout 留 +10s 余量：必须严格大于包装超时，否则 readTimer 会先响（WARN 泄漏）
    let client = ClientBuilder()
        .tlsConfig(tlsConfig)
        .readTimeout(Duration.second * (timeoutSeconds + 10))
        .writeTimeout(Duration.second * 10)
        .build()

    // 构建请求
    let builder = HttpRequestBuilder()
    // 设置 method
    if (method == "GET") {
        builder.get()
    } else if (method == "POST") {
        builder.post()
    } else if (method == "PUT") {
        builder.put()
    } else if (method == "DELETE") {
        builder.delete()
    } else {
        builder.get()  // 默认 GET
    }
    builder.url(url)
    // 默认头：extraHeaders 显式给出同名头时不重复设置（如 JSON API 需要 Accept: application/json）
    var hasUA = false
    var hasAccept = false
    var hasLang = false
    match (extraHeaders) {
        case Some(hdrs) =>
            for ((k, _) in hdrs) {
                let lk = k.toAsciiLower()
                if (lk == "user-agent") { hasUA = true }
                if (lk == "accept") { hasAccept = true }
                if (lk == "accept-language") { hasLang = true }
            }
        case None => ()
    }
    if (!hasUA) { builder.header("User-Agent", userAgent) }
    if (!hasAccept) { builder.header("Accept", "text/html,application/xhtml+xml,text/plain,*/*") }
    if (!hasLang) { builder.header("Accept-Language", acceptLanguage) }

    // 添加额外 headers
    match (extraHeaders) {
        case Some(hdrs) =>
            for ((k, v) in hdrs) {
                builder.header(k, v)
            }
        case None => ()
    }

    // 设置请求体
    match (body) {
        case Some(b) => builder.body(b)
        case None => ()
    }

    let req = builder.build()

    // spawn 子线程发送请求
    let future: Future<HttpFetchResult> = spawn {
        try {
            let resp = client.send(req)
            let status = Int64(resp.status)
            if (status < 200 || status >= 300) {
                // 非 2xx 不排空响应体；连接由下面的 close 统一回收
                return HttpFetchResult(status, "")
            }
            let respBody = readResponseBody(resp.body, maxDownloadBytes)
            return HttpFetchResult(status, safeFromUtf8(respBody))
        } catch (_: Exception) {
            return HttpFetchResult(0, "")
        }
    }

    // 带超时等待结果；所有出口都 close 客户端（取消 readTimer + 回收连接）
    try {
        return future.get(Duration.second * timeoutSeconds)
    } finally {
        try { client.close() } catch (_: Exception) {}
    }
}

/**
 * 通用 HTTP 请求：返回响应体字符串（非 2xx / 无响应返回空字符串）
 */
public func httpClientRequest(
    method: String,
    url: String,
    timeoutSeconds: Int64,
    maxDownloadBytes: Int64,
    userAgent: String,
    acceptLanguage: String,
    body: ?String,
    extraHeaders: ?Map<String, String>
): String {
    let result = httpClientFetch(
        method,
        url,
        timeoutSeconds,
        maxDownloadBytes,
        userAgent,
        acceptLanguage,
        body,
        extraHeaders
    )
    if (!result.isOk()) { return "" }
    return result.body
}

/**
 * 通用 HTTP GET（保留向后兼容）
 */
public func httpClientGet(
    url: String,
    timeoutSeconds: Int64,
    maxDownloadBytes: Int64,
    userAgent: String,
    acceptLanguage: String
): String {
    return httpClientRequest(
        "GET",
        url,
        timeoutSeconds,
        maxDownloadBytes,
        userAgent,
        acceptLanguage,
        None,
        None
    )
}

/**
 * 通用 HTTP GET（简化版，用默认 UA 和 Accept-Language）
 */
public func httpClientGetSimple(url: String, timeoutSeconds: Int64, maxDownloadBytes: Int64): String {
    return httpClientGet(
        url,
        timeoutSeconds,
        maxDownloadBytes,
        "cjh/1.3.0 (Cangjie Coding Agent)",
        "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7"
    )
}

/**
 * 从 URL 提取 host
 * 例如 "https://www.example.com/path?q=1" → "www.example.com"
 */
private func extractHostFromUrl(url: String): String {
    let lower = url.toAsciiLower()
    var start = 0
    if (lower.startsWith("https://")) {
        start = 8
    } else if (lower.startsWith("http://")) {
        start = 7
    } else {
        return ""
    }

    // 找 host 结束位置（/ : ? # 之一）
    var end = start
    let n = url.size
    while (end < n) {
        let c = Int64(UInt32(url.toRuneArray()[end]))
        if (c == 47 || c == 58 || c == 63 || c == 35) {  // / : ? #
            break
        }
        end += 1
    }

    if (start >= end) { return "" }
    return url[start..end]
}

/**
 * 读取 HTTP 响应体（最多 maxBytes 字节）
 */
private func readResponseBody(body: InputStream, maxBytes: Int64): Array<Byte> {
    var list = ArrayList<Byte>()
    let bufSize = if (maxBytes < 8192) { maxBytes } else { 8192 }
    var buf = Array<Byte>(bufSize, repeat: UInt8(0))
    try {
        while (list.size < maxBytes) {
            let n = body.read(buf)
            if (n <= 0) { break }
            for (i in 0..n) {
                list.add(buf[i])
            }
        }
    } catch (e: Exception) {
        // 读取中断，返回已读部分
    }
    var result = Array<Byte>(list.size, repeat: UInt8(0))
    for (i in 0..list.size) {
        result[i] = list[i]
    }
    return result
}
