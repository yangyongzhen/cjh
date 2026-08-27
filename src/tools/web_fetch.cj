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

        // 会话级预算检查（防 prompt injection 烧流量）
        // 预估本次下载字节数 = maxDownloadBytes（5MB），实际可能更少
        match (budget.tryFetch(maxDownloadBytes)) {
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
                return ToolResult(formatResult(url, cleaned, effectiveMaxChars), false)
            case None => ()  // 进入降级链
        }

        // 4. 第二层：exec curl 降级
        let curlResult = fetchWithCurl(url)
        match (curlResult) {
            case Some(content) =>
                let cleaned = HtmlCleaner.toMarkdown(content)
                return ToolResult(formatResult(url, cleaned, effectiveMaxChars), false)
            case None => ()  // curl 也失败，进入第三层
        }

        // 5. 第三层：Firecrawl API 降级（~96% 站点，Keyless 1000 credits/month）
        let firecrawlResult = fetchWithFirecrawl(url)
        match (firecrawlResult) {
            case Some(markdown) =>
                // Firecrawl 返回的已经是清洗后的 Markdown，无需再清洗
                return ToolResult(formatResult(url, markdown, effectiveMaxChars), false)
            case None => ()  // Firecrawl 也失败
        }

        // 6. 三层全失败，返回错误
        return ToolResult("Failed to fetch ${url} (cangjie HTTP + curl + Firecrawl all failed)", true)
    }

    /**
     * 第一层：仓颉 stdx.net.http GET
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

            let resp = client.send(req)
            if (resp.status < 200 || resp.status >= 300) { return None }

            // 读取 body（最多 maxDownloadBytes）
            let body = readBody(resp.body, maxDownloadBytes)
            return Some(safeFromUtf8(body))
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 第二层：exec curl 降级（带浏览器头）
     * 安全封装：数组式 exec 防注入
     */
    private func fetchWithCurl(url: String): ?String {
        try {
            // 构造数组式 exec 参数（不经过 shell）
            var argv = Array<String>(15, repeat: "")
            argv[0] = "curl"
            argv[1] = "-sL"                              // 静默 + 跟重定向
            argv[2] = "--max-time"
            argv[3] = timeoutSeconds.toString()
            argv[4] = "--connect-timeout"
            argv[5] = "5"
            argv[6] = "-A"                               // 浏览器 UA
            argv[7] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            argv[8] = "-H"                               // 浏览器头
            argv[9] = "Accept: text/html,application/xhtml+xml,text/plain,*/*"
            argv[10] = "-H"
            argv[11] = "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7"
            argv[12] = "--max-filesize"
            argv[13] = maxDownloadBytes.toString()
            // url 必须是最后一个参数
            argv[14] = url

            let (code, stdoutBytes, stderrBytes) = executeWithOutput("curl", argv)
            if (code != 0) { return None }
            if (stdoutBytes.size == 0) { return None }
            return Some(safeFromUtf8(stdoutBytes))
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
     */
    private func formatResult(url: String, content: String, maxChars: Int64): String {
        var result = "URL: ${url}\n\n---\n\n"
        if (content.size > maxChars) {
            result += content[0..maxChars]
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
