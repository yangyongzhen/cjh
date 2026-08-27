package cjh.tools

import std.collection.*
import std.convert.Parsable
import std.io.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjutil.*

// =====================================================================
// web_search 工具
//
// SearchProvider 接口 + 多后端路由（Auto fallback）
//   - TavilyProvider：主力，1000 req/月免费不绑卡
//   - DDGProvider：零 key 兜底，永远 enable
//   - （P1-B）ExaProvider + SearXNGProvider 待实现
//
// per-engine key rotation（借鉴 ModSearch）：
//   给 Tavily 配多个逗号分隔 key，认证/限流/配额失败时轮换到下一个 key，
//   全部 key 耗尽再降级到引擎链。
//
// 两层降级：
//   1. 引擎内 key rotation：单 key 失败 → 同引擎下一个 key
//   2. 引擎链降级：引擎所有 key 耗尽 → 路由跳下一个引擎 → DDG 兜底
// =====================================================================

// ===== 数据结构 =====

public struct SearchHit {
    public let title: String
    public let url: String
    public let snippet: String
    public init(title: String, url: String, snippet: String) {
        this.title = title
        this.url = url
        this.snippet = snippet
    }
}

// ===== per-engine key rotation =====

public class KeyRotator {
    private let keys: ArrayList<String>
    private var currentIdx: Int64 = 0
    private var exhausted: Bool = false

    public init(keysCsv: String) {
        this.keys = ArrayList<String>()
        if (keysCsv.size > 0) {
            for (k in keysCsv.split(",")) {
                let trimmed = k.trimAscii()
                if (trimmed.size > 0) {
                    this.keys.add(trimmed)
                }
            }
        }
    }

    // 当前 key（无 key 返回空串）
    public func current(): String {
        if (keys.size == 0) { return "" }
        if (currentIdx >= keys.size) { return "" }
        return keys[currentIdx]
    }

    public func hasKeys(): Bool {
        return keys.size > 0
    }

    // 当前 key 判定为认证/限流/配额失败时调用
    // 返回 true=已轮换到下一个 key；false=所有 key 耗尽
    public func rotate(): Bool {
        currentIdx += 1
        if (currentIdx >= keys.size) {
            exhausted = true
            return false
        }
        return true
    }

    public func isExhausted(): Bool {
        return exhausted
    }
}

// ===== Provider 接口 =====

public interface SearchProvider {
    func name(): String
    func enabled(): Bool       // 读 config 判断是否启用
    func search(query: String, maxResults: Int64): ArrayList<SearchHit>
}

// ===== Tavily 实现（带 key rotation）=====

public class TavilyProvider <: SearchProvider {
    private let rotator: KeyRotator
    private let timeoutSeconds: Int64

    public init(keysCsv: String, timeoutSeconds: Int64) {
        this.rotator = KeyRotator(keysCsv)
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "tavily" }
    public func enabled(): Bool { rotator.hasKeys() }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        while (!rotator.isExhausted()) {
            let key = rotator.current()
            match (doTavilySearch(key, query, maxResults)) {
                case Some(hits) => return hits  // 成功（含空结果列表）
                case None =>
                    // 当前 key 失败（认证/限流/配额）→ 轮换
                    if (!rotator.rotate()) { break }  // 所有 key 耗尽
            }
        }
        return ArrayList<SearchHit>()  // 引擎链降级
    }

    private func doTavilySearch(key: String, query: String, maxResults: Int64): ?ArrayList<SearchHit> {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            tlsConfig.domain = Some("api.tavily.com")
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            // 构造请求体 JSON
            var bodyObj = JsonObject()
            bodyObj.put("api_key", JsonString(key))
            bodyObj.put("query", JsonString(query))
            bodyObj.put("max_results", JsonInt(maxResults))
            bodyObj.put("search_depth", JsonString("basic"))
            bodyObj.put("include_answer", JsonBool(false))
            bodyObj.put("include_raw_content", JsonBool(false))

            let req = HttpRequestBuilder()
                .post()
                .url("https://api.tavily.com/search")
                .header("Content-Type", "application/json")
                .body(bodyObj.toJsonString())
                .build()

            let resp = client.send(req)
            // 401/429/5xx → 认证或限流失败，返回 None 触发 key rotation
            if (resp.status == 401 || resp.status == 429 || resp.status >= 500) {
                return None
            }
            if (resp.status != 200) { return None }

            let respBody = readAll(resp.body, 1048576)  // 1MB 上限
            let rootJson = JsonValue.fromStr(safeFromUtf8(respBody))
            let resultsOpt: ?JsonValue = match (rootJson.kind()) {
                case JsonKind.JsObject => rootJson.asObject().get("results")
                case _ => None
            }

            let hits = ArrayList<SearchHit>()
            match (resultsOpt) {
                case Some(results) =>
                    match (results.kind()) {
                        case JsonKind.JsArray =>
                            let arr = results.asArray()
                            var i = 0
                            while (i < arr.size()) {
                                let item = arr[i]
                                let title = getStringField(item, "title")
                                let url = getStringField(item, "url")
                                let content = getStringField(item, "content")
                                // content 截断到 500 字符
                                let snippet = if (content.size > 500) {
                                    content[0..500]
                                } else {
                                    content
                                }
                                if (url.size > 0) {
                                    hits.add(SearchHit(title, url, snippet))
                                }
                                i += 1
                            }
                        case _ => ()
                    }
                case None => ()
            }
            return Some(hits)  // 空列表也是合法成功
        } catch (e: Exception) {
            return None
        }
    }
}

// ===== DDG 实现（零 key 兜底）=====

public class DDGProvider <: SearchProvider {
    private let timeoutSeconds: Int64

    public init(timeoutSeconds: Int64) {
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "ddg" }
    public func enabled(): Bool { true }  // 永远兜底

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            tlsConfig.domain = Some("api.duckduckgo.com")
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            // DDG Instant Answer API
            // GET https://api.duckduckgo.com/?q={query}&format=json&no_html=1&skip_disambig=1
            let encodedQuery = urlEncode(query)
            let url = "https://api.duckduckgo.com/?q=${encodedQuery}&format=json&no_html=1&skip_disambig=1"

            let req = HttpRequestBuilder()
                .get()
                .url(url)
                .header("User-Agent", "cjh/1.3.0 (Cangjie Coding Agent)")
                .header("Accept", "application/json")
                .build()

            let resp = client.send(req)
            if (resp.status != 200) { return ArrayList<SearchHit>() }

            let respBody = readAll(resp.body, 1048576)
            let rootJson = JsonValue.fromStr(safeFromUtf8(respBody))
            // 仅当根是 Object 时才取字段
            let rootObj = match (rootJson.kind()) {
                case JsonKind.JsObject => rootJson.asObject()
                case _ => return ArrayList<SearchHit>()
            }

            let hits = ArrayList<SearchHit>()

            // 第一条：AbstractText + AbstractURL
            let abstractText = getStringFieldObj(rootObj, "AbstractText")
            let abstractURL = getStringFieldObj(rootObj, "AbstractURL")
            let heading = getStringFieldObj(rootObj, "Heading")
            if (abstractText.size > 0 || abstractURL.size > 0) {
                let title = if (heading.size > 0) { heading } else { "DuckDuckGo Result" }
                let snippet = if (abstractText.size > 0) {
                    if (abstractText.size > 500) { abstractText[0..500] } else { abstractText }
                } else {
                    ""
                }
                let url = if (abstractURL.size > 0) { abstractURL } else { "https://duckduckgo.com/?q=${encodedQuery}" }
                hits.add(SearchHit(title, url, snippet))
            }

            // RelatedTopics 数组
            match (rootObj.get("RelatedTopics")) {
                case Some(related) =>
                    match (related.kind()) {
                        case JsonKind.JsArray =>
                            let arr = related.asArray()
                            var i = 0
                            while (i < arr.size()) {
                                if (hits.size >= maxResults) { break }
                                let topic = arr[i]
                                let text = getStringField(topic, "Text")
                                let firstURL = getStringField(topic, "FirstURL")
                                if (text.size > 0 || firstURL.size > 0) {
                                    let snippet = if (text.size > 500) { text[0..500] } else { text }
                                    let url = if (firstURL.size > 0) { firstURL } else { "https://duckduckgo.com/?q=${encodedQuery}" }
                                    let title = if (text.size > 0) {
                                        if (text.size > 80) { text[0..80] } else { text }
                                    } else {
                                        "DuckDuckGo Related"
                                    }
                                    hits.add(SearchHit(title, url, snippet))
                                }
                                i += 1
                            }
                        case _ => ()
                    }
                case None => ()
            }

            return hits
        } catch (e: Exception) {
            return ArrayList<SearchHit>()
        }
    }
}

// ===== Exa 实现（带 key rotation，语义搜索强）=====

public class ExaProvider <: SearchProvider {
    private let rotator: KeyRotator
    private let timeoutSeconds: Int64

    public init(keysCsv: String, timeoutSeconds: Int64) {
        this.rotator = KeyRotator(keysCsv)
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "exa" }
    public func enabled(): Bool { rotator.hasKeys() }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        while (!rotator.isExhausted()) {
            let key = rotator.current()
            match (doExaSearch(key, query, maxResults)) {
                case Some(hits) => return hits
                case None =>
                    if (!rotator.rotate()) { break }
            }
        }
        return ArrayList<SearchHit>()
    }

    private func doExaSearch(key: String, query: String, maxResults: Int64): ?ArrayList<SearchHit> {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            tlsConfig.domain = Some("api.exa.ai")
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            // 构造请求体 JSON
            var bodyObj = JsonObject()
            bodyObj.put("query", JsonString(query))
            bodyObj.put("numResults", JsonInt(maxResults))
            bodyObj.put("type", JsonString("keyword"))
            // contents: { text: true } —— 让 Exa 返回正文摘要
            var contentsObj = JsonObject()
            contentsObj.put("text", JsonBool(true))
            bodyObj.put("contents", contentsObj)

            let req = HttpRequestBuilder()
                .post()
                .url("https://api.exa.ai/search")
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer ${key}")
                .body(bodyObj.toJsonString())
                .build()

            let resp = client.send(req)
            if (resp.status == 401 || resp.status == 429 || resp.status >= 500) {
                return None
            }
            if (resp.status != 200) { return None }

            let respBytes = readAll(resp.body, 1048576)
            let rootJson = JsonValue.fromStr(safeFromUtf8(respBytes))
            let resultsOpt: ?JsonValue = match (rootJson.kind()) {
                case JsonKind.JsObject => rootJson.asObject().get("results")
                case _ => None
            }

            let hits = ArrayList<SearchHit>()
            match (resultsOpt) {
                case Some(results) =>
                    match (results.kind()) {
                        case JsonKind.JsArray =>
                            let arr = results.asArray()
                            var i = 0
                            while (i < arr.size()) {
                                let item = arr[i]
                                let title = getStringField(item, "title")
                                let url = getStringField(item, "url")
                                // Exa 正文在 contents.text
                                var snippet = ""
                                match (item.kind()) {
                                    case JsonKind.JsObject =>
                                        match (item.asObject().get("text")) {
                                            case Some(t) =>
                                                match (t.kind()) {
                                                    case JsonKind.JsString => snippet = t.asString().getValue()
                                                    case _ => ()
                                                }
                                            case None => ()
                                        }
                                    case _ => ()
                                }
                                if (snippet.size > 500) { snippet = snippet[0..500] }
                                if (url.size > 0) {
                                    hits.add(SearchHit(title, url, snippet))
                                }
                                i += 1
                            }
                        case _ => ()
                    }
                case None => ()
            }
            return Some(hits)
        } catch (e: Exception) {
            return None
        }
    }
}

// ===== SearXNG 实现（自建零成本，聚合 70+ 后端）=====

public class SearXNGProvider <: SearchProvider {
    private let searxngUrl: String    // 如 http://127.0.0.1:8080
    private let timeoutSeconds: Int64

    public init(searxngUrl: String, timeoutSeconds: Int64) {
        this.searxngUrl = searxngUrl
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "searxng" }
    public func enabled(): Bool { searxngUrl.size > 0 }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        try {
            // SearXNG 不一定走 TLS，按 URL 协议决定
            // GET {searxngUrl}/search?q={query}&format=json
            let encodedQuery = urlEncode(query)
            let url = "${searxngUrl}/search?q=${encodedQuery}&format=json"

            // 构建 client（SearXNG 可能是 http，TLS config 仅对 https 生效）
            let client = ClientBuilder()
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            let req = HttpRequestBuilder()
                .get()
                .url(url)
                .header("User-Agent", "cjh/1.3.0 (Cangjie Coding Agent)")
                .header("Accept", "application/json")
                .build()

            let resp = client.send(req)
            if (resp.status != 200) { return ArrayList<SearchHit>() }

            let respBytes = readAll(resp.body, 1048576)
            let rootJson = JsonValue.fromStr(safeFromUtf8(respBytes))
            let resultsOpt: ?JsonValue = match (rootJson.kind()) {
                case JsonKind.JsObject => rootJson.asObject().get("results")
                case _ => None
            }

            let hits = ArrayList<SearchHit>()
            match (resultsOpt) {
                case Some(results) =>
                    match (results.kind()) {
                        case JsonKind.JsArray =>
                            let arr = results.asArray()
                            var i = 0
                            while (i < arr.size()) {
                                if (hits.size >= maxResults) { break }
                                let item = arr[i]
                                let title = getStringField(item, "title")
                                let url = getStringField(item, "url")
                                var snippet = getStringField(item, "content")
                                if (snippet.size > 500) { snippet = snippet[0..500] }
                                if (url.size > 0) {
                                    hits.add(SearchHit(title, url, snippet))
                                }
                                i += 1
                            }
                        case _ => ()
                    }
                case None => ()
            }
            return hits
        } catch (e: Exception) {
            return ArrayList<SearchHit>()
        }
    }
}

public class SearchRouter {
    private let providers: ArrayList<SearchProvider>

    public init(providers: ArrayList<SearchProvider>) {
        this.providers = providers
    }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        for (i in 0..providers.size) {
            let p = providers[i]
            if (!p.enabled()) { continue }
            // provider 内部已处理 key rotation
            let hits = p.search(query, maxResults)
            if (hits.size > 0) { return hits }  // 命中就回
            // 空结果/超时 → 引擎链降级，跳下一个引擎
        }
        return ArrayList<SearchHit>()  // 全部失败返回空
    }
}

// ===== web_search 工具 =====

public class WebSearchTool <: CjhTool {
    private let router: SearchRouter
    private let maxResults: Int64
    private let budget: WebBudget

    public init(router: SearchRouter, maxResults: Int64, budget: WebBudget) {
        this.router = router
        this.maxResults = maxResults
        this.budget = budget
    }

    public func isReadOnly(): Bool {
        return true  // 搜索是纯读
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("query", JsonSchema.str("The search query"))
        props.add("max_results", JsonSchema.str("Maximum number of results to return (default 5, max 10)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["query"]))
        return ToolSpec("web_search",
            "Search the web for information. Returns a list of results with title, " +
            "URL, and snippet. Use this when you need to find current information, " +
            "look up documentation, or find answers to questions you don't know. " +
            "For fetching the content of a specific URL, use web_fetch instead.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        // 1. 参数校验
        if (!args.containsKey("query")) {
            return ToolResult("Missing parameter: query", true)
        }
        let query = args.get("query").getOrThrow().asString().getValue()
        if (query.size == 0) {
            return ToolResult("Empty query", true)
        }

        // 会话级预算检查（防 prompt injection 烧 API key）
        match (budget.trySearch()) {
            case Some(reason) => return ToolResult(reason, true)
            case None => ()
        }

        // 2. 解析可选 max_results
        var effectiveMax = this.maxResults
        if (let Some(mrVal) <- args.get("max_results")) {
            match (mrVal.kind()) {
                case JsonKind.JsString =>
                    match (parseIntSafe(mrVal.asString().getValue())) {
                        case Some(n) => effectiveMax = n
                        case None => ()
                    }
                case JsonKind.JsInt => effectiveMax = mrVal.asInt().getValue()
                case _ => ()
            }
        }
        if (effectiveMax < 1) { effectiveMax = 1 }
        if (effectiveMax > 10) { effectiveMax = 10 }

        // 3. 执行搜索
        let hits = router.search(query, effectiveMax)

        if (hits.size == 0) {
            return ToolResult("No results found for \"${query}\". Try a different query or check your network connection.", false)
        }

        // 4. 格式化输出
        var content = StringBuilder()
        content.append("Found ${hits.size} result(s) for \"${query}\":\n\n")
        for (i in 0..hits.size) {
            let hit = hits[i]
            let num = i + 1
            content.append("[${num}] ${hit.title}\n")
            content.append("    URL: ${hit.url}\n")
            if (hit.snippet.size > 0) {
                content.append("    ${hit.snippet}\n")
            }
            content.append("\n")
        }
        content.append("Use web_fetch to read the full content of any URL above.")
        return ToolResult(content.toString(), false)
    }
}

// ===== 辅助函数 =====

/**
 * 从 JsonObject 提取字符串字段
 */
func getStringFieldObj(obj: JsonObject, field: String): String {
    match (obj.get(field)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/**
 * 从 JsonValue 提取字符串字段（先判断 kind 为 Object）
 */
func getStringField(json: JsonValue, field: String): String {
    match (json.kind()) {
        case JsonKind.JsObject => return getStringFieldObj(json.asObject(), field)
        case _ => return ""
    }
}

/**
 * URL 编码（查询字符串用）
 */
func urlEncode(s: String): String {
    var result = StringBuilder()
    for (i in 0..s.size) {
        let c = s[i]
        // ASCII 字母数字保持原样
        if ((c >= 48 && c <= 57) ||   // 0-9
            (c >= 65 && c <= 90) ||   // A-Z
            (c >= 97 && c <= 122) ||  // a-z
            c == 45 ||                // -
            c == 95 ||                // _
            c == 46 ||                // .
            c == 126) {               // ~
            result.append(String(Rune(Int32(c))))
        } else if (c == 32) {         // 空格 → +
            result.append("+")
        } else {
            // 其他字符 → %XX
            let hexChars = "0123456789ABCDEF"
            result.append("%")
            let hi = (c >> 4) & 0x0F
            let lo = c & 0x0F
            // Byte → Int32 → Rune → String（查表方式）
            let hiChar = hexChars[Int64(hi)]
            let loChar = hexChars[Int64(lo)]
            let hiArr = Array<Rune>(1, repeat: Rune(Int32(UInt32(hiChar))))
            let loArr = Array<Rune>(1, repeat: Rune(Int32(UInt32(loChar))))
            result.append(String(hiArr))
            result.append(String(loArr))
        }
    }
    return result.toString()
}

/**
 * 读取 InputStream 全部内容到 Array<Byte>，最多 maxBytes
 */
func readAll(stream: InputStream, maxBytes: Int64): Array<Byte> {
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

/**
 * 安全解析整数，失败返回 None
 */
func parseIntSafe(s: String): ?Int64 {
    try {
        return Int64.parse(s)
    } catch (e: Exception) {
        return None
    }
}
