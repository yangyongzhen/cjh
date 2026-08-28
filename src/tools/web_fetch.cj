package cjh.tools

import std.collection.*
import std.process.*
import std.io.*
import std.fs.*
import std.env.*
import std.convert.Parsable
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjllm.FirecrawlClient
import cjutil.*

/**
 * web_fetch 工具：抓取指定 URL 的页面内容，返回清洗后的纯文本
 *
 * 三级降级链：
 *   1. 仓颉 stdx.net.http GET（第一层，~50% 站点）
 *   2. exec curl + 浏览器头（第二层，~70% 站点）
 *   3. （P1-A）Firecrawl API（第三层，~96% 站点）
 *
 * SSRF 防护：协议白名单 + IP 段拦截 + DNS 解析校验
 * HTML 清洗：去 script/style/nav + 标签剥离 + HTML 实体解码 → Markdown
 */
public class WebFetchTool <: CjhTool {
    private let allowInternal: Bool
    private let maxChars: Int64
    private let timeoutSeconds: Int64
    private let budget: WebBudget
    private let maxDownloadBytes: Int64 = 5242880  // 5MB

    public init(allowInternal: Bool, maxChars: Int64, timeoutSeconds: Int64, budget: WebBudget) {
        this.allowInternal = allowInternal
        this.maxChars = maxChars
        this.timeoutSeconds = timeoutSeconds
        this.budget = budget
    }

    public func isReadOnly(): Bool {
        return true  // 抓取是纯读
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("url", JsonSchema.str("The URL to fetch (must be http:// or https://)"))
        props.add("max_chars", JsonSchema.str("Maximum characters to return (default 32000, max 128000)"))
        props.add("query", JsonSchema.str("Search query for BM25 compression of long articles (>10K chars). Pass the user's question or key terms so the most relevant paragraphs are kept. Optional but recommended for long pages."))
        let schema = JsonSchema.object(props, ArrayList<String>(["url"]))
        return ToolSpec("web_fetch",
            "Fetch the content of a web page and return it as clean Markdown text. " +
            "Use this when you have a specific URL and want to read its content. " +
            "The page HTML is cleaned (scripts, styles, navigation removed) and converted to Markdown. " +
            "Results are truncated to ~32KB. For searching the web, use web_search instead.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        // 1. 参数校验
        if (!args.containsKey("url")) {
            return ToolResult("Missing parameter: url", true)
        }
        let url = args.get("url").getOrThrow().asString().getValue()

        // 解析可选 max_chars
        var effectiveMaxChars = this.maxChars
        if (let Some(mcVal) <- args.get("max_chars")) {
            match (mcVal.kind()) {
                case JsonKind.JsString =>
                    match (parseIntSafe(mcVal.asString().getValue())) {
                        case Some(n) => effectiveMaxChars = n
                        case None => ()
                    }
                case JsonKind.JsInt => effectiveMaxChars = mcVal.asInt().getValue()
                case _ => ()
            }
        }
        // 硬上限 128KB
        if (effectiveMaxChars > 128000) { effectiveMaxChars = 128000 }

        // 解析可选 query：用于 BM25 检索压缩长文章
        var query = ""
        if (let Some(qVal) <- args.get("query")) {
            match (qVal.kind()) {
                case JsonKind.JsString => query = qVal.asString().getValue()
                case _ => ()
            }
        }

        // 会话级预算检查（防 prompt injection 烧流量）
        // 只记次数，不预扣字节（实际下载量在调用时未知）
        match (budget.tryFetch(0)) {
            case Some(reason) => return ToolResult(reason, true)
            case None => ()
        }

        // 2. SSRF 校验
        if (!SsrfGuard.validateUrl(url, this.allowInternal)) {
            return ToolResult("URL blocked by SSRF guard: ${url}", true)
        }

        // 3. 第一层：仓颉 stdx.net.http GET
        let cangjieResult = fetchWithCangjie(url)
        match (cangjieResult) {
            case Some(content) =>
                let cleaned = HtmlCleaner.toMarkdown(content)
                return ToolResult(compressIfNeeded(url, cleaned, query, effectiveMaxChars), false)
            case None => ()  // 进入降级链
        }

        // 4. 第二层：exec curl 降级
        let curlResult = fetchWithCurl(url)
        match (curlResult) {
            case Some(content) =>
                let cleaned = HtmlCleaner.toMarkdown(content)
                return ToolResult(compressIfNeeded(url, cleaned, query, effectiveMaxChars), false)
            case None => ()  // curl 也失败，进入第三层
        }

        // 5. 第三层：Firecrawl API 降级（~96% 站点，Keyless 1000 credits/month）
        let firecrawlResult = fetchWithFirecrawl(url)
        match (firecrawlResult) {
            case Some(markdown) =>
                // Firecrawl 返回的已经是清洗后的 Markdown，无需再清洗
                return ToolResult(compressIfNeeded(url, markdown, query, effectiveMaxChars), false)
            case None => ()  // Firecrawl 也失败
        }

        // 6. 三层全失败，返回错误
        return ToolResult("Failed to fetch ${url} (cangjie HTTP + curl + Firecrawl all failed)", true)
    }

    /**
     * 长文章压缩：文章超过阈值时用 BM25 检索 query 相关的 top-k 块
     *
     * 策略：
     *   - 文章 <= 阈值：直接 formatResult 返回
     *   - 文章 > 阈值且有 query：BM25 检索 top-3 块拼接，压缩比约 10:1
     *   - 文章 > 阈值但无 query：按 maxChars 截断（保留头部）
     */
    private func compressIfNeeded(url: String, content: String, query: String, maxChars: Int64): String {
        let compressThreshold: Int64 = 10000  // >10K 字符才压缩
        let runes = content.toRuneArray()
        let charCount = Int64(runes.size)

        if (charCount <= compressThreshold) {
            // 短文章，直接返回
            return formatResult(url, content, maxChars)
        }

        if (query.size == 0) {
            // 长文章但无 query，按 maxChars 截断
            return formatResult(url, content, maxChars)
        }

        // 长文章 + 有 query：BM25 压缩
        let topK: Int64 = 3
        let compressed = ArticleCompressor.compress(content, query, topK, maxChars)
        return formatResult(url, compressed, maxChars)
    }

    /**
     * 第一层：仓颉 stdx.net.http GET
     *
     * 仓颉 ClientBuilder 没有 connectTimeout，目标不可达时卡在 TCP connect，
     * readTimeout 不触发。用 spawn 子线程 + 主线程 join 超时的方式做整体超时保护：
     *   - spawn 子线程执行 client.send(req)
     *   - 主线程等待 future，超时则放弃（子线程自然终止）
     *
     * 成功返回 HTML 内容，失败返回 None
     */
    private func fetchWithCangjie(url: String): ?String {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            let host = SsrfGuard.extractHost(url)
            if (host.size > 0) { tlsConfig.domain = Some(host) }

            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .readTimeout(Duration.second * timeoutSeconds)
                .writeTimeout(Duration.second * 10)
                .build()

            let req = HttpRequestBuilder()
                .get()
                .url(url)
                .header("User-Agent", "cjh/1.3.0 (Cangjie Coding Agent)")
                .header("Accept", "text/html,application/xhtml+xml,text/plain,*/*")
                .header("Accept-Language", "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7")
                .build()

            // spawn 子线程发送请求，主线程 get(timeout) 超时保护
            // 超时抛 TimeoutException，catch 后返回 None 进入降级链
            let future: Future<?String> = spawn {
                let resp = client.send(req)
                if (resp.status < 200 || resp.status >= 300) {
                    return None
                }
                let body = readBody(resp.body, maxDownloadBytes)
                return Some(safeFromUtf8(body))
            }

            // 带超时等待结果；超时抛 TimeoutException
            return future.get(Duration.second * timeoutSeconds)
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 第二层：仓颉原生 HTTP client（带浏览器头 + spawn 超时保护）
     *
     * 第一层 fetchWithCangjie 用 cjh UA，部分站点返回 403。
     * 第二层换浏览器 UA 重试，仍用仓颉原生 ClientBuilder + spawn 超时保护。
     */
    private func fetchWithCurl(url: String): ?String {
        try {
            let html = httpClientGet(
                url,
                timeoutSeconds,
                maxDownloadBytes,
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7"
            )
            if (html.size == 0) { return None }
            return Some(html)
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 第三层：Firecrawl API 降级（~96% 站点）
     * Firecrawl Keyless 默认 1000 credits/month，免注册免 key
     * 返回清洗后的 Markdown，无需 cjh 自己清洗 HTML
     */
    private func fetchWithFirecrawl(url: String): ?String {
        try {
            // FIRECRAWL_API_KEY 环境变量可选（Keyless 模式免 key）
            let apiKey = (getVariable("FIRECRAWL_API_KEY") ?? "")
            let client = FirecrawlClient(apiKey, this.timeoutSeconds)
            return client.scrape(url)
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 读取 InputStream 到 Array<Byte>，最多 maxBytes
     */
    private func readBody(body: InputStream, maxBytes: Int64): Array<Byte> {
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

    /**
     * 格式化输出结果
     * maxChars 按 Rune（字符）数计算，避免多字节 UTF-8 截断产生乱码
     */
    private func formatResult(url: String, content: String, maxChars: Int64): String {
        var result = "URL: ${url}\n\n---\n\n"
        let runes = content.toRuneArray()
        if (runes.size > maxChars) {
            // 按 Rune 截断，避免截断在多字节字符中间
            var sb = StringBuilder()
            for (i in 0..maxChars) {
                sb.append(String(runes[i]))
            }
            result += sb.toString()
            result += "\n\n...(truncated at ${maxChars} chars)"
        } else {
            result += content
        }
        return result
    }

    /**
     * 安全解析整数，失败返回 None
     */
    private func parseIntSafe(s: String): ?Int64 {
        try {
            return Int64.parse(s)
        } catch (e: Exception) {
            return None
        }
    }
}
