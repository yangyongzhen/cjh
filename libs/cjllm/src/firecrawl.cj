package cjllm

/**
 * Firecrawl 客户端：web_fetch 第三级降级
 *
 * Firecrawl 内部用 12 种抓取引擎并发竞速（Engine Waterfall Racing），
 * 官方宣称 96% 抓取成功率。Firecrawl Keyless 默认 1000 credits/month，
 * no account / no API key / no card，开箱即用。
 *
 * API:
 *   POST https://api.firecrawl.dev/v1/scrape
 *   Authorization: Bearer {FIRECRAWL_API_KEY}  // 可选，Keyless 模式免 key
 *   Content-Type: application/json
 *
 *   Request: { "url": "...", "formats": ["markdown"], "onlyMainContent": true }
 *   Response: { "success": true, "data": { "markdown": "...", "metadata": {...} } }
 *
 * 设计要点：
 *   - Firecrawl 返回清洗后的 Markdown，无需 cjh 自己清洗 HTML
 *   - Firecrawl 能渲染 SPA 页面（React/Vue），弥补仓颉 HTTP GET + curl 不执行 JS 的短板
 *   - 失败时返回 None，让 web_fetch 进入"返回错误"兜底
 */

import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import stdx.encoding.json.*
import std.collection.*
import std.io.*
import cjutil.*

public class FirecrawlClient {
    private let apiKey: String        // 可空（Keyless 模式）
    private let baseUrl: String = "https://api.firecrawl.dev/v1"
    private let timeoutSeconds: Int64

    public init(apiKey: String, timeoutSeconds: Int64) {
        this.apiKey = apiKey
        this.timeoutSeconds = timeoutSeconds
    }

    /**
     * 抓取指定 URL，返回 Firecrawl 清洗后的 Markdown
     * @param url 待抓取的 URL（已过 SSRF 校验）
     * @return Some(markdown) 成功；None 失败
     */
    public func scrape(url: String): ?String {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            tlsConfig.domain = Some("api.firecrawl.dev")
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            // 构造请求体 JSON
            var bodyObj = JsonObject()
            bodyObj.put("url", JsonString(url))
            // formats: ["markdown"]
            var formatsArr = JsonArray()
            formatsArr.add(JsonString("markdown"))
            bodyObj.put("formats", formatsArr)
            bodyObj.put("onlyMainContent", JsonBool(true))

            // 构造请求
            var reqBuilder = HttpRequestBuilder()
                .post()
                .url("${this.baseUrl}/scrape")
                .header("Content-Type", "application/json")
            // Keyless 模式免 key；有 key 则加 Authorization 头
            if (this.apiKey.size > 0) {
                reqBuilder = reqBuilder.header("Authorization", "Bearer ${this.apiKey}")
            }
            let req = reqBuilder.body(bodyObj.toJsonString()).build()

            let resp = client.send(req)
            // 401/402/429/5xx → 失败（Keyless 额度耗尽或服务异常）
            if (resp.status == 401 || resp.status == 402 || resp.status == 429 || resp.status >= 500) {
                return None
            }
            if (resp.status != 200) { return None }

            // 读取响应（最多 2MB）
            let respBytes = readInputStream(resp.body, 2097152)
            let rootJson = JsonValue.fromStr(safeFromUtf8(respBytes))

            // 检查 success 字段
            let rootObj = match (rootJson.kind()) {
                case JsonKind.JsObject => rootJson.asObject()
                case _ => return None
            }
            match (rootObj.get("success")) {
                case Some(s) =>
                    match (s.kind()) {
                        case JsonKind.JsBool =>
                            if (!s.asBool().getValue()) { return None }
                        case _ => return None
                    }
                case None => return None
            }

            // 提取 data.markdown
            match (rootObj.get("data")) {
                case Some(data) =>
                    match (data.kind()) {
                        case JsonKind.JsObject =>
                            let dataObj = data.asObject()
                            match (dataObj.get("markdown")) {
                                case Some(md) =>
                                    match (md.kind()) {
                                        case JsonKind.JsString => return Some(md.asString().getValue())
                                        case _ => return None
                                    }
                                case None => return None
                            }
                        case _ => return None
                    }
                case None => return None
            }
        } catch (e: Exception) {
            return None
        }
    }
}

/**
 * 读取 InputStream 全部内容到 Array<Byte>，最多 maxBytes
 */
func readInputStream(stream: InputStream, maxBytes: Int64): Array<Byte> {
    var list = ArrayList<Byte>()
    var buf = Array<Byte>(8192, repeat: UInt8(0))
    try {
        while (list.size < maxBytes) {
            let n = stream.read(buf)
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
