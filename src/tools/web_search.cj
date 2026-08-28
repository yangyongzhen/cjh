package cjh.tools

import std.collection.*
import std.convert.Parsable
import std.io.*
import std.process.*
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

// ===== 搜狗搜索实现（零 key 兜底，国内可达）=====
//
// DDG (api.duckduckgo.com / html.duckduckgo.com) 在国内网络完全不可达，
// 搜狗 (www.sogou.com) 在国内可达且响应快（<1s），作为零 key 兜底。
//
// 策略：
//   - curl 子进程 + --max-time 硬超时（连接失败立即退出，不卡 105s）
//   - 浏览器 User-Agent（搜狗对非浏览器 UA 返回 403）
//   - 解析搜狗结果页 HTML：class="vr-title" 提取标题+链接+摘要

public class SogouProvider <: SearchProvider {
    private let timeoutSeconds: Int64

    public init(timeoutSeconds: Int64) {
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "sogou" }
    public func enabled(): Bool { true }  // 永远兜底

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        try {
            let encodedQuery = urlEncode(query)
            let url = "https://www.sogou.com/web?query=" + encodedQuery

            // 仓颉原生 HTTP client + spawn 超时保护（不用 curl 子进程）
            let html = httpClientGet(
                url,
                timeoutSeconds,
                1048576,  // 1MB max download
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "zh-CN,zh;q=0.9"
            )

            if (html.size == 0) { return ArrayList<SearchHit>() }
            // 反爬检测：搜狗触发 antispider 时返回验证码页，vr-title 为 0
            // 检测到反爬返回空，让 SearchRouter 降级到 Bing
            if (isSogouAntispider(html)) { return ArrayList<SearchHit>() }
            return parseSogouHtml(html, maxResults)
        } catch (e: Exception) {
            return ArrayList<SearchHit>()
        }
    }
}

/**
 * 搜狗反爬检测
 * 搜狗触发反爬时返回验证码页，含 antispider / captcha / 验证码 关键词
 */
func isSogouAntispider(html: String): Bool {
    let lower = html.toAsciiLower()
    if (lower.contains("antispider")) { return true }
    if (lower.contains("captcha")) { return true }
    if (lower.contains("验证码")) { return true }
    if (lower.contains("访问过于频繁")) { return true }
    return false
}

/**
 * Bing 反爬检测
 * Bing 触发反爬时返回空结果页或 robot 页
 */
func isBingAntispider(html: String): Bool {
    let lower = html.toAsciiLower()
    if (lower.contains("robot")) { return true }
    if (lower.contains("captcha")) { return true }
    if (lower.contains("验证码")) { return true }
    // b_algo 为 0 且有 b_no 结果提示
    if (!lower.contains("b_algo") && lower.contains("b_no")) { return true }
    return false
}

/**
 * 解析搜狗搜索结果页 HTML
 *
 * 搜狗结果页结构：
 *   <h3 class="vr-title">...</h3>
 *   <p class="str_text_info">摘要</p> 或 <div class="str-time-info">摘要</div>
 *   链接在 <a href="..."> 里，搜狗不做重定向跳转，直接是目标 URL
 */
func parseSogouHtml(html: String, maxResults: Int64): ArrayList<SearchHit> {
    let hits = ArrayList<SearchHit>()
    let lower = html.toAsciiLower()
    var pos = 0

    while (hits.size < maxResults) {
        // 找 vr-title
        let titleOpt = lower.indexOf("vr-title", pos)
        if (let None <- titleOpt) { break }
        let titleIdx = titleOpt.getOrThrow()
        pos = titleIdx + 8

        // 从 vr-title 往后找最近的 <a
        let aStartOpt = lower.indexOf("<a", titleIdx)
        if (let None <- aStartOpt) { break }
        let aStart = aStartOpt.getOrThrow()
        if (aStart > titleIdx + 200) { continue }  // 太远

        // 提取 href
        let hrefOpt = lower.indexOf("href=\"", aStart)
        if (let None <- hrefOpt) { continue }
        let hrefStart = hrefOpt.getOrThrow() + 6
        let hrefEndOpt = lower.indexOf("\"", hrefStart)
        if (let None <- hrefEndOpt) { continue }
        let hrefEnd = hrefEndOpt.getOrThrow()
        let rawHref = html[hrefStart..hrefEnd]

        // 提取标题文本（<a ...>文本</a>）
        let gtOpt = lower.indexOf(">", aStart)
        if (let None <- gtOpt) { continue }
        let gt = gtOpt.getOrThrow()
        let aEndOpt = lower.indexOf("</a>", gt)
        if (let None <- aEndOpt) { continue }
        let aEnd = aEndOpt.getOrThrow()
        let titleHtml = html[gt + 1..aEnd]
        let title = trimStr(stripTags(titleHtml))
        if (title.size == 0) { continue }

        // 提取 URL（搜狗可能是直接 URL 或 /link?url=xxx 格式）
        let url = cleanSogouUrl(rawHref)

        // 找摘要：在 vr-title 之后找 str_text_info 或 str_text_info
        let snippet = findSogouSnippet(lower, html, aEnd)

        hits.add(SearchHit(title, url, snippet))
    }

    return hits
}

/**
 * 清理搜狗 URL
 * 搜狗链接格式：
 *   - 直接 URL：https://www.example.com/...
 *   - 重定向：/link?url=xxx&v=...
 */
func cleanSogouUrl(rawHref: String): String {
    // 直接 URL
    if (rawHref.startsWith("http://") || rawHref.startsWith("https://")) {
        return rawHref
    }

    // 搜狗重定向格式 /link?url=xxx
    // 简化处理：返回搜狗搜索页作为兜底
    // （解析重定向 URL 需要额外 HTTP 请求，太慢，跳过）
    return rawHref
}

/**
 * 在搜狗结果页中查找摘要文本
 */
func findSogouSnippet(lower: String, html: String, startPos: Int64): String {
    // 找 str_text_info 或 str-text-info
    let snippetOpt = lower.indexOf("str_text_info", startPos)
    if (let Some(sIdx) <- snippetOpt) {
        if (sIdx < startPos + 2000) {
            // 找 > 和 </p> 或 </div>
            let gtOpt = lower.indexOf(">", sIdx)
            if (let Some(gt) <- gtOpt) {
                let endOpt = lower.indexOf("</", gt)
                if (let Some(end) <- endOpt) {
                    let snippetHtml = html[gt + 1..end]
                    var snippet = trimStr(stripTags(snippetHtml))
                    if (snippet.size > 300) { snippet = snippet[0..300] }
                    return snippet
                }
            }
        }
    }
    return ""
}

// ===== Bing 搜索实现（零 key 兜底，国内可达）=====
//
// 搜狗容易触发反爬，Bing 作为第二免费降级。
// Bing 结果页结构：<li class="b_algo">...<h2><a href="url">标题</a></h2>...<p>摘要</p>

public class BingProvider <: SearchProvider {
    private let timeoutSeconds: Int64

    public init(timeoutSeconds: Int64) {
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "bing" }
    public func enabled(): Bool { true }  // 永远兜底

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        try {
            let encodedQuery = urlEncode(query)
            let url = "https://cn.bing.com/search?q=" + encodedQuery + "&count=" + maxResults.toString()

            let html = httpClientGet(
                url,
                timeoutSeconds,
                1048576,  // 1MB max download
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "zh-CN,zh;q=0.9,en;q=0.8"
            )

            if (html.size == 0) { return ArrayList<SearchHit>() }
            // 反爬检测：Bing 触发反爬时返回 robot/captcha 页
            // 检测到反爬返回空，让 SearchRouter 降级到付费 provider
            if (isBingAntispider(html)) { return ArrayList<SearchHit>() }
            return parseBingHtml(html, maxResults)
        } catch (e: Exception) {
            return ArrayList<SearchHit>()
        }
    }
}

/**
 * 解析 Bing 搜索结果页 HTML
 *
 * Bing 结果页结构：
 *   <li class="b_algo">
 *     <h2><a href="url">标题</a></h2>
 *     <p class="b_lineclamp...">摘要</p>
 *   </li>
 */
func parseBingHtml(html: String, maxResults: Int64): ArrayList<SearchHit> {
    let hits = ArrayList<SearchHit>()
    let lower = html.toAsciiLower()
    var pos = 0

    while (hits.size < maxResults) {
        // 找 b_algo
        let algoOpt = lower.indexOf("b_algo", pos)
        if (let None <- algoOpt) { break }
        let algoIdx = algoOpt.getOrThrow()
        pos = algoIdx + 6

        // 在 b_algo 之后找 <h2>
        let h2Opt = lower.indexOf("<h2", algoIdx)
        if (let None <- h2Opt) { continue }
        let h2Idx = h2Opt.getOrThrow()
        if (h2Idx > algoIdx + 500) { continue }  // 太远，不是同一个块

        // 在 <h2 之后找 <a href="
        let aOpt = lower.indexOf("<a", h2Idx)
        if (let None <- aOpt) { continue }
        let aIdx = aOpt.getOrThrow()
        if (aIdx > h2Idx + 100) { continue }

        let hrefOpt = lower.indexOf("href=\"", aIdx)
        if (let None <- hrefOpt) { continue }
        let hrefStart = hrefOpt.getOrThrow() + 6
        let hrefEndOpt = lower.indexOf("\"", hrefStart)
        if (let None <- hrefEndOpt) { continue }
        let hrefEnd = hrefEndOpt.getOrThrow()
        let url = html[hrefStart..hrefEnd]

        // 提取标题文本（<a ...>文本</a>）
        let gtOpt = lower.indexOf(">", aIdx)
        if (let None <- gtOpt) { continue }
        let gt = gtOpt.getOrThrow()
        let aEndOpt = lower.indexOf("</a>", gt)
        if (let None <- aEndOpt) { continue }
        let aEnd = aEndOpt.getOrThrow()
        let titleHtml = html[gt + 1..aEnd]
        let title = trimStr(stripTags(titleHtml))
        if (title.size == 0) { continue }

        // 找摘要：在 </h2> 之后找 <p> 或 b_lineclamp
        let h2EndOpt = lower.indexOf("</h2>", h2Idx)
        let snippet = match (h2EndOpt) {
            case Some(h2End) => findBingSnippet(lower, html, h2End)
            case None => ""
        }

        hits.add(SearchHit(title, url, snippet))
    }

    return hits
}

/**
 * 在 Bing 结果块中查找摘要文本
 * Bing 摘要通常在 <p class="b_lineclamp..."> 或 <div class="b_caption"> 中
 */
func findBingSnippet(lower: String, html: String, startPos: Int64): String {
    // 找 b_caption 或 b_lineclamp
    let patterns = ["b_caption", "b_lineclamp", "<p"]
    for (pattern in patterns) {
        let opt = lower.indexOf(pattern, startPos)
        if (let Some(idx) <- opt) {
            if (idx > startPos + 1000) { continue }  // 太远
            // 找 > 和 </p> 或 </div>
            let gtOpt = lower.indexOf(">", idx)
            if (let Some(gt) <- gtOpt) {
                let endOpt = lower.indexOf("</", gt)
                if (let Some(end) <- endOpt) {
                    let snippetHtml = html[gt + 1..end]
                    var snippet = trimStr(stripTags(snippetHtml))
                    if (snippet.size > 300) { snippet = snippet[0..300] }
                    return snippet
                }
            }
        }
    }
    return ""
}

/**
 * 解析 DDG HTML 搜索结果页
 *
 * DDG HTML 页面结构：
 *   <a class="result__a" href="...">标题</a>
 *   <a class="result__snippet" href="...">摘要</a>
 *
 * 策略：
 *   1. 找 result__a 的 href 和文本
 *   2. 找对应的 result__snippet 文本
 *   3. DDG 的 href 是 /l/?uddg=<encoded_url> 格式，需要解码
 */
func parseDDgHtml(html: String, encodedQuery: String, maxResults: Int64): ArrayList<SearchHit> {
    let hits = ArrayList<SearchHit>()
    let lower = html.toAsciiLower()

    // 找所有 result__a 链接
    var pos = 0
    while (hits.size < maxResults) {
        // 找 result__a
        let resultOpt = lower.indexOf("result__a", pos)
        if (let None <- resultOpt) { break }
        let resultIdx = resultOpt.getOrThrow()
        pos = resultIdx + 9

        // 从 result__a 往前找最近的 <a
        let aStartOpt = lower.indexOf("<a", resultIdx)
        if (let None <- aStartOpt) { break }
        let aStart = aStartOpt.getOrThrow()
        if (aStart > resultIdx + 100) { continue }  // 太远，不是同一个标签

        // 找 <a ...> 的 href
        let hrefOpt = lower.indexOf("href=\"", aStart)
        if (let None <- hrefOpt) { continue }
        let hrefStart = hrefOpt.getOrThrow() + 6
        let hrefEndOpt = lower.indexOf("\"", hrefStart)
        if (let None <- hrefEndOpt) { continue }
        let hrefEnd = hrefEndOpt.getOrThrow()
        let rawHref = html[hrefStart..hrefEnd]

        // 解码 DDG 重定向 URL：/l/?uddg=<encoded_url>
        let url = decodeDDgRedirect(rawHref, encodedQuery)

        // 找链接文本（<a ...>文本</a>）
        let gtOpt = lower.indexOf(">", aStart)
        if (let None <- gtOpt) { continue }
        let gt = gtOpt.getOrThrow()
        let aEndOpt = lower.indexOf("</a>", gt)
        if (let None <- aEndOpt) { continue }
        let aEnd = aEndOpt.getOrThrow()
        let titleHtml = html[gt + 1..aEnd]
        let title = trimStr(stripTags(titleHtml))
        if (title.size == 0) { continue }

        // 找对应的 snippet（result__snippet）
        let snippetStartOpt = lower.indexOf("result__snippet", aEnd)
        if (let None <- snippetStartOpt) {
            hits.add(SearchHit(title, url, ""))
            continue
        }
        let snippetStart = snippetStartOpt.getOrThrow()
        // snippet 是 <a class="result__snippet" ...>文本</a>
        let sGtOpt = lower.indexOf(">", snippetStart)
        if (let None <- sGtOpt) { continue }
        let sGt = sGtOpt.getOrThrow()
        let sEndOpt = lower.indexOf("</a>", sGt)
        if (let None <- sEndOpt) { continue }
        let sEnd = sEndOpt.getOrThrow()
        let snippetHtml = html[sGt + 1..sEnd]
        var snippet = trimStr(stripTags(snippetHtml))
        if (snippet.size > 300) { snippet = snippet[0..300] }

        hits.add(SearchHit(title, url, snippet))
    }

    return hits
}

/**
 * 解码 DDG 重定向 URL
 * DDG 的搜索结果链接格式：/l/?uddg=<encoded_url>&rut=...
 * 需要 URL 解码 uddg 参数得到真实 URL
 */
func decodeDDgRedirect(rawHref: String, encodedQuery: String): String {
    // 检查是否是 DDG 重定向格式
    let lower = rawHref.toAsciiLower()
    let uddgOpt = lower.indexOf("uddg=")
    if (let Some(_) <- uddgOpt) {
        // 提取 uddg 参数值
        let uddgStart = rawHref.indexOf("uddg=")
        if (let Some(us) <- uddgStart) {
            let valStart = us + 5
            let valEndOpt = rawHref.indexOf("&", valStart)
            let valEnd = match (valEndOpt) {
                case Some(e) => e
                case None => rawHref.size
            }
            let encoded = rawHref[valStart..valEnd]
            // URL 解码（%XX → 字符）
            return urlDecode(encoded)
        }
    }

    // 不是重定向格式，直接返回（可能是完整 URL）
    if (rawHref.startsWith("http://") || rawHref.startsWith("https://")) {
        return rawHref
    }

    // 兜底：返回 DDG 搜索页
    return "https://duckduckgo.com/?q=" + encodedQuery
}

/**
 * 手动 trim：去除首尾空白字符
 * 仓颉 String 没有 trim() 方法，手动实现
 */
func trimStr(s: String): String {
    let runes = s.toRuneArray()
    var start = 0
    var end = runes.size
    while (start < end && isWsR(runes[start])) { start += 1 }
    while (end > start && isWsR(runes[end - 1])) { end -= 1 }
    if (start >= end) { return "" }
    var sb = StringBuilder()
    for (i in start..end) { sb.append(String(runes[i])) }
    return sb.toString()
}

private func isWsR(r: Rune): Bool {
    let v = Int64(UInt32(r))
    return v == 32 || v == 9 || v == 10 || v == 13 || v == 12 || v == 11
}

/**
 * URL 解码：%XX → 对应字符，+ → 空格
 */
func urlDecode(s: String): String {
    var result = StringBuilder()
    let runes = s.toRuneArray()
    let n = runes.size
    var i = 0
    while (i < n) {
        let r = runes[i]
        if (r == Rune(37)) {  // %
            // %XX 格式
            if (i + 2 < n) {
                let h1 = Int64(UInt32(runes[i + 1]))
                let h2 = Int64(UInt32(runes[i + 2]))
                let v1 = hexVal(h1)
                let v2 = hexVal(h2)
                if (v1 >= 0 && v2 >= 0) {
                    let byte = UInt8(v1 * 16 + v2)
                    // 收集连续的 %XX 字节，形成完整 UTF-8 字符
                    // 简化：逐字节解码，非 ASCII 字节可能显示乱码
                    result.append(String(Rune(Int64(byte))))
                    i += 3
                    continue
                }
            }
            // 无效的 % 编码，原样保留
            result.append(String(r))
            i += 1
        } else if (r == Rune(43)) {  // +
            result.append(" ")
            i += 1
        } else {
            result.append(String(r))
            i += 1
        }
    }
    return result.toString()
}

/**
 * 十六进制字符转数值（0-15），非十六进制返回 -1
 */
private func hexVal(c: Int64): Int64 {
    if (c >= 48 && c <= 57) { return c - 48 }      // 0-9
    if (c >= 97 && c <= 102) { return c - 87 }     // a-f
    if (c >= 65 && c <= 70) { return c - 55 }      // A-F
    return -1
}

/**
 * 剥离 HTML 标签，返回纯文本
 */
func stripTags(html: String): String {
    var result = StringBuilder()
    var inTag = false
    let runes = html.toRuneArray()
    for (i in 0..runes.size) {
        let r = runes[i]
        if (r == Rune(60)) {  // <
            inTag = true
        } else if (r == Rune(62)) {  // >
            inTag = false
        } else if (!inTag) {
            result.append(String(r))
        }
    }
    return result.toString()
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

// ===== Exa MCP 实现（零 key，借鉴 atomcode）=====
//
// atomcode 的主力 web_search provider：
//   POST https://mcp.exa.ai/mcp
//   JSON-RPC tools/call web_search_exa
//   响应是 SSE，解析 data: 行里的 JSON result.content[].text
//
// 无 key 也能用（atomcode 默认无 key），有 key 则带 exaApiKey 参数。
// 这比 cjh 现有的 ExaProvider（REST API + Bearer key）更优：
//   - 无 key 即可用
//   - 返回 LLM-ready text，不需要再清洗

public class ExaMcpProvider <: SearchProvider {
    private let timeoutSeconds: Int64

    public init(timeoutSeconds: Int64) {
        this.timeoutSeconds = timeoutSeconds
    }

    public func name(): String { "exa-mcp" }
    public func enabled(): Bool { true }  // 无 key 也能用，永远 enable

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        try {
            let sse = doExaMcpSearch(query, maxResults)
            if (sse.size == 0) { return ArrayList<SearchHit>() }
            return parseExaMcpSse(sse, maxResults)
        } catch (e: Exception) {
            return ArrayList<SearchHit>()
        }
    }

    /**
     * POST https://mcp.exa.ai/mcp
     * JSON-RPC tools/call web_search_exa
     * 用 httpClientRequest 统一超时保护（超时后 client.close() 取消 readTimer，不触发 WARN）
     * 返回 SSE body
     */
    private func doExaMcpSearch(query: String, maxResults: Int64): String {
        let url = "https://mcp.exa.ai/mcp"

        // 构造 JSON-RPC 请求体
        var argsObj = JsonObject()
        argsObj.put("query", JsonString(query))
        argsObj.put("numResults", JsonInt(maxResults))

        var paramsObj = JsonObject()
        paramsObj.put("name", JsonString("web_search_exa"))
        paramsObj.put("arguments", argsObj)

        var bodyObj = JsonObject()
        bodyObj.put("jsonrpc", JsonString("2.0"))
        bodyObj.put("id", JsonInt(1))
        bodyObj.put("method", JsonString("tools/call"))
        bodyObj.put("params", paramsObj)

        // extraHeaders: Content-Type + Accept
        var hdrs = HashMap<String, String>()
        hdrs["Content-Type"] = "application/json"
        hdrs["Accept"] = "application/json, text/event-stream"

        return httpClientRequest(
            "POST",
            url,
            timeoutSeconds,
            1048576,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
            "en-US,en;q=0.9",
            Some(bodyObj.toJsonString()),
            Some(hdrs)
        )
    }
}

/**
 * 解析 Exa MCP SSE 响应
 *
 * SSE 格式：
 *   data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"..."}]}}
 *
 * 策略：
 *   1. 扫描 data: 行
 *   2. 解析 JSON，提取 result.content[].text
 *   3. 合并所有 text，按双换行分隔
 */
func parseExaMcpSse(sse: String, maxResults: Int64): ArrayList<SearchHit> {
    let hits = ArrayList<SearchHit>()
    let lines = sse.split('\n')
    var combinedText = StringBuilder()

    for (line in lines) {
        let trimmed = line.trimStart()
        if (!trimmed.startsWith("data:")) { continue }
        let payload = trimmed[5..].trimStart()
        if (payload.size == 0) { continue }

        try {
            let json = JsonValue.fromStr(payload)
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let contentOpt = json.asObject().get("result")
                    match (contentOpt) {
                        case Some(resultVal) =>
                            match (resultVal.kind()) {
                                case JsonKind.JsObject =>
                                    let contentArrOpt = resultVal.asObject().get("content")
                                    match (contentArrOpt) {
                                        case Some(contentArr) =>
                                            match (contentArr.kind()) {
                                                case JsonKind.JsArray =>
                                                    let arr = contentArr.asArray()
                                                    var i = 0
                                                    while (i < arr.size()) {
                                                        let item = arr[i]
                                                        match (item.kind()) {
                                                            case JsonKind.JsObject =>
                                                                let textOpt = item.asObject().get("text")
                                                                match (textOpt) {
                                                                    case Some(t) =>
                                                                        match (t.kind()) {
                                                                            case JsonKind.JsString =>
                                                                                if (combinedText.size > 0) {
                                                                                    combinedText.append("\n\n")
                                                                                }
                                                                                combinedText.append(t.asString().getValue())
                                                                            case _ => ()
                                                                        }
                                                                    case None => ()
                                                                }
                                                            case _ => ()
                                                        }
                                                        i += 1
                                                    }
                                                case _ => ()
                                            }
                                        case None => ()
                                    }
                                case _ => ()
                            }
                        case None => ()
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            continue
        }
    }

    // Exa MCP 返回的是 LLM-ready text，格式：
    //   Title: Rust Programming Language
    //   URL: https://rust-lang.org/
    //   Published: N/A
    //   Author: N/A
    //   Highlights:
    //   Rust is blazingly fast...
    //
    //   ---
    //
    //   Title: The Rust Programming Language
    //   URL: https://doc.rust-lang.org/stable/book/
    //   ...
    //
    // 策略：按行扫描，Title: 行设标题，URL: 行设 URL，--- 分隔结果块
    let text = combinedText.toString()
    if (text.size == 0) { return hits }

    let textLines = text.split('\n')
    var currentTitle = ""
    var currentUrl = ""
    var currentSnippet = StringBuilder()

    for (textLine in textLines) {
        let trimmed = textLine.trimStart().trimEnd()
        if (trimmed.size == 0) { continue }

        // --- 分隔符：保存上一个结果，开始新结果
        if (trimmed.startsWith("---")) {
            if (currentUrl.size > 0) {
                hits.add(SearchHit(currentTitle, currentUrl, currentSnippet.toString().trimEnd()))
                if (hits.size >= maxResults) { return hits }
            }
            currentTitle = ""
            currentUrl = ""
            currentSnippet = StringBuilder()
            continue
        }

        // Title: 行
        if (trimmed.startsWith("Title:")) {
            currentTitle = trimmed[6..].trimStart()
            continue
        }

        // URL: 行
        if (trimmed.startsWith("URL:")) {
            currentUrl = trimmed[4..].trimStart()
            continue
        }

        // Published: / Author: 行跳过
        if (trimmed.startsWith("Published:") || trimmed.startsWith("Author:")) {
            continue
        }

        // Highlights: 标记开始摘要
        if (trimmed.startsWith("Highlights:")) {
            continue
        }

        // 其他行作为摘要内容
        if (currentSnippet.size > 0) {
            currentSnippet.append(" ")
        }
        currentSnippet.append(trimmed)
    }

    // 保存最后一个结果
    if (currentUrl.size > 0) {
        hits.add(SearchHit(currentTitle, currentUrl, currentSnippet.toString().trimEnd()))
    }

    return hits
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
