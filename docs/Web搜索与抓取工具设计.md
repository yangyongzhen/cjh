# cjh Web 搜索与抓取工具设计

> 版本：v1.0（设计稿）
> 日期：2026-08-27
> 状态：待实现

## 一、设计目标

为 cjh 新增两个强大的内置工具，增强 Agent 的联网能力：

| 工具 | 职责 | 输入 | 输出 |
|---|---|---|---|
| `web_search` | 信息检索——"我不知道去哪找" | 查询意图（query） | URL 列表 + 摘要 + 引用 |
| `web_fetch` | 信息获取——"我知道去哪了，帮我看看里面写了啥" | 确定 URL | 页面正文（清洗后） |

两者分工明确，配合使用：

```
用户问："仓颉怎么绑 C 库？"
  → agent 调 web_search("仓颉 C FFI 绑定")   ← 搜索：发现去哪
  → 拿到 3 个 URL，挑最靠谱的
  → agent 调 web_fetch(那个URL)              ← 抓取：读具体内容
  → 把正文摘要塞回上下文，生成回答
```

如果用户直接给了 URL（贴链接说"帮我看这个文档"），agent 跳过搜索直接 fetch。

## 二、核心设计原则

### 2.1 零默认依赖——开箱即用

cjh 的定位是"单二进制零运行时依赖"。web 工具同样遵循：

- **默认免 key 兜底**：用户拉二进制、不配任何 key，也能联网搜索（DuckDuckGo Instant Answer API，免 key 无限次）
- **配 key 即升级**：用户在 `settings.json` 填了 Tavily/Exa key，搜索质量自动升级，不用改一行业务代码
- **不搭服务**：不强制用户自建 SearXNG 容器。搜索后端走固定白名单域名（tavily/exa/ddg），攻击面小

### 2.2 Provider 抽象 + 多后端路由

借鉴 omp 的"14+ provider 链 + Auto 滑落"和 AtomCode 的 `SearchProvider trait`，cjh 设计：

```
SearchProvider（接口）
  ├── TavilyProvider    —— 有 key 才 enable，POST api.tavily.com/search
  ├── ExaProvider       —— 有 key 才 enable，GET api.exa.ai/v1/search
  ├── SearXNGProvider   —— 有 searxng_url 才 enable，GET {url}/search
  └── DDGProvider       —— 永远 enable，零 key 兜底，GET api.duckduckgo.com
```

路由策略（Auto 模式）：

```
Tavily(若有key) → Exa(若有key) → SearXNG(若有url) → DDG(永远兜底)
```

每次 `web_search` 调用：先打第一个 enabled provider，结果数达标就回；空结果/非 2xx/超时 → 退避后跳下一个。

### 2.3 SSRF 防护——安全第一

`web_fetch` 必须 SSRF 防护，防止 agent 被诱导抓内网地址（如 `http://169.254.169.254` 云元数据）：

1. **协议层**：只收 `http://` / `https://`，带 `user:pass@` 的 URL 直接拒（防凭证透传内网）
2. **IP 层**：解析主机名后对每个 A/AAAA 记录判段——loopback（127.0.0.0/8、::1）、link-local（169.254.0.0/16，含云元数据 169.254.169.254）、RFC1918 私有段（10/172.16/192.168）、IPv6 unique-local（fc00::/7）、multicast 全拒
3. **重定向重校**：每跳都重判 IP 段，不信任第一次解析结果。主动禁掉自动 redirect，自己按跳数上限（5 跳）逐跳跟，每一跳的目标 URL 都重新过 SSRF 校验——防止"允许域名 → 302 跳到 169.254.169.254"这种开放重定向绕过

### 2.4 省 token——对齐两大硬性指标

web 工具的输出直接进 Agent 上下文，必须严格控制 token：

- **web_search**：每条 snippet 截断到 ~500 字符，按相关度排序，附 citation 序号。默认返回 5 条（最多 10 条）
- **web_fetch**：HTML 清洗后转纯文本，超长截断到 ~32KB（约 8K token），附 `(truncated)` 标记。支持可选 `max_chars` 参数
- **原始下载硬上限 5MB**，超时默认 30s / 上限 60s

### 2.5 高执行效率——降级链设计

`web_fetch` 的抓取成功率直接影响 Agent 效率。设计三级降级链：

```
仓颉 stdx.net.http GET（第一层，~50% 站点）
  ↓ 失败（4xx/5xx/超时/反爬拦截）
exec curl（第二层，带完整浏览器头 + 可选代理，~70% 站点）
  ↓ 还不行
Firecrawl API（第三层，~96% 站点，免注册 1000 次/月）
  ↓ 还不行
返回错误，让 agent 换思路
```

**Firecrawl 降级的关键优势**：

- **免注册免 key**：Firecrawl Keyless 默认提供 1000 free credits/month，no account / no API key / no card，开箱即用
- **多引擎竞速抓取**：Firecrawl 内部用 12 种抓取引擎并发竞速（Engine Waterfall Racing），通过 Promise.race + SnipeAbort 竞速取消慢引擎，官方宣称 96% 抓取成功率
- **LLM-ready Markdown 输出**：Firecrawl 返回清洗后的 Markdown，三层转换管线（Go 微服务 → Go FFI → JS TurndownService）+ Rust NAPI 后处理，无需 cjh 自己清洗 HTML
- **JS 渲染能力**：Firecrawl 能渲染 SPA 页面（React/Vue），弥补仓颉 HTTP GET + curl 不执行 JS 的短板

**Firecrawl API 调用**：

```
POST https://api.firecrawl.dev/v1/scrape
Authorization: Bearer {FIRECRAWL_API_KEY}  // 可选，Keyless 模式免 key
Content-Type: application/json

{
  "url": "https://example.com",
  "formats": ["markdown"],
  "onlyMainContent": true,
  "maxAge": 86400000
}
```

**响应**：

```json
{
  "success": true,
  "data": {
    "markdown": "# Page Title\n\nCleaned content in Markdown...",
    "metadata": {
      "title": "Page Title",
      "sourceURL": "https://example.com",
      "statusCode": 200
    }
  }
}
```

cjh 直接取 `data.markdown`，无需 HTML 清洗步骤。

**curl 降级的安全封装**：

- 用数组式 exec（不经过 shell）：`exec(["curl", "-sL", "-A", ua, "--max-time", "30", url])`
- 而不是 `exec("curl -sL -A " + ua + " " + url)` ——URL 里带 `| bash`、`; rm -rf` 会被 shell 解释
- URL 严格过白名单校验后再降级
- 浏览器头模板：`-A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"` + `-H "Accept-Language: en-US,en;q=0.9"`

## 三、web_search 工具设计

### 3.1 工具 Schema

```json
{
  "name": "web_search",
  "description": "Search the web for information. Returns a list of results with title, URL, and snippet. Use this when you need to find current information, look up documentation, or find answers to questions you don't know. For fetching the content of a specific URL, use web_fetch instead.",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query"
      },
      "max_results": {
        "type": "integer",
        "description": "Maximum number of results to return (default 5, max 10)",
        "default": 5
      },
      "time_range": {
        "type": "string",
        "enum": ["day", "week", "month", "year"],
        "description": "Restrict results to a time range (optional)"
      }
    },
    "required": ["query"]
  }
}
```

### 3.2 返回格式

```json
{
  "content": "Found 3 results for \"cangjie FFI binding\":\n\n[1] Cangjie Language Guide - FFI\n    URL: https://docs.cangjie-lang.com/ffi\n    The foreign function interface allows Cangjie to call C library functions...\n\n[2] GitHub - cangjie-lang/runtime\n    URL: https://github.com/cangjie-lang/runtime\n    Cangjie runtime with FFI support for native interop...\n\n[3] Cangjie FFI Tutorial\n    URL: https://cangjie-tutorial.com/ffi\n    Step by step guide to binding C libraries in Cangjie...",
  "is_error": false
}
```

### 3.3 Provider 实现

#### 3.3.1 TavilyProvider（主力推荐）

Tavily：1000 次/月自动续，不绑卡，返 LLM-ready 摘要+URL，英文编码场景强。

**API 调用**：

```
POST https://api.tavily.com/search
Content-Type: application/json

{
  "api_key": "{TAVILY_API_KEY}",
  "query": "cangjie FFI binding",
  "max_results": 5,
  "search_depth": "basic",
  "include_answer": false,
  "include_raw_content": false
}
```

**响应解析**：

```json
{
  "results": [
    {
      "title": "Cangjie Language Guide - FFI",
      "url": "https://docs.cangjie-lang.com/ffi",
      "content": "The foreign function interface...",
      "score": 0.95
    }
  ],
  "response_time": 1.23
}
```

抽 `results[].title/url/content`，content 截断到 500 字符。

#### 3.3.2 ExaProvider（语义搜索强）

Exa：送 $20 + 每月 $10 自动续（约 1400 次基础搜索/月），不绑卡，语义长尾查询强。

**API 调用**：

```
GET https://api.exa.ai/v1/search
Authorization: Bearer {EXA_API_KEY}
Content-Type: application/json

{
  "query": "cangjie FFI binding",
  "numResults": 5,
  "type": "keyword"
}
```

抽 `results[].title/url/text`，text 截断到 500 字符。

#### 3.3.3 SearXNGProvider（自建零成本）

用户自建 SearXNG 容器，聚合 Google/Bing/DDG/70+ 后端，完全免费无 key 无配额。

**API 调用**：

```
GET {SEARXNG_URL}/search?q=cangjie+FFI+binding&format=json
```

抽 `results[].title/url/content`，content 截断到 500 字符。

#### 3.3.4 DDGProvider（零 key 兜底）

DuckDuckGo Instant Answer API：免 key 无限次，只返摘要不返 SERP，覆盖窄，做最后兜底。

**API 调用**：

```
GET https://api.duckduckgo.com/?q=cangjie+FFI+binding&format=json&no_html=1&skip_disambig=1
```

**响应解析**：

```json
{
  "AbstractText": "The foreign function interface...",
  "AbstractURL": "https://en.wikipedia.org/wiki/...",
  "Heading": "Cangjie FFI",
  "RelatedTopics": [
    { "Text": "FFI allows Cangjie to call C functions", "FirstURL": "https://..." }
  ]
}
```

抽 `AbstractText` + `AbstractURL`（如有）作为第一条结果；遍历 `RelatedTopics` 抽 `Text` + `FirstURL` 作为后续结果。

**DDG 兜底的诚实定位**：免 key 的 DDG 只能算"不死"，不能算"通用"——它答不了"2026 年仓颉 tree-sitter binding 最新 PR"这种长尾。文档里写清楚：默认免 key 模式用于降级演示，生产 agent 请至少配一个 Tavily/Exa 免费 key。

### 3.4 仓颉实现骨架

```cangjie
// libs/cjllm/src/web_search.cj（或 src/tools/web_search.cj）
package cjh.tools

import stdx.net.http.*
import std.json.*
import std.collection.*

// ===== 数据结构 =====

public struct SearchHit {
    public let title: String
    public let url: String
    public let snippet: String
    public init(title: String, url: String, snippet: String) {
        this.title = title; this.url = url; this.snippet = snippet
    }
}

// ===== Provider 接口 =====

public interface SearchProvider {
    func name(): String
    func enabled(): Bool       // 读 config 判断是否启用
    func search(query: String, maxResults: Int64): ArrayList<SearchHit>
}

// ===== per-engine key rotation =====
//
// 借鉴 ModSearch：给 Tavily/Exa/Firecrawl 配多个逗号分隔 key，
// 认证/限流/配额失败时轮换到下一个 key，全部 key 耗尽再降级到引擎链。
//
// 场景：用户有多个免费账号 key，单 key 触发 429 配额墙时，
// 不直接降级引擎，而是先试同引擎的下一个 key，最大化单引擎可用性。

public class KeyRotator {
    private let keys: ArrayList<String>
    private var currentIdx: Int64 = 0
    private var exhausted: Bool = false

    public init(keysCsv: String) {
        this.keys = ArrayList<String>()
        if (keysCsv.size > 0) {
            for (k in keysCsv.split(",")) {
                let trimmed = k.trim()
                if (trimmed.size > 0) { this.keys.add(trimmed) }
            }
        }
    }

    // 当前 key（无 key 返回空串）
    public func current(): String {
        if (keys.size == 0) { return "" }
        if (currentIdx >= keys.size) { return "" }
        return keys[currentIdx]
    }

    public func hasKeys(): Bool { keys.size > 0 }

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

    public func isExhausted(): Bool { exhausted }
}

// ===== Tavily 实现（带 key rotation）=====

public class TavilyProvider <: SearchProvider {
    private let rotator: KeyRotator
    public init(keysCsv: String) { this.rotator = KeyRotator(keysCsv) }
    public func name(): String { "tavily" }
    public func enabled(): Bool { rotator.hasKeys() }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        while (!rotator.isExhausted()) {
            let key = rotator.current()
            let result = doTavilySearch(key, query, maxResults)
            match (result) {
                case Some(hits) => return hits           // 成功
                case None =>
                    // 当前 key 失败（认证/限流/配额）→ 轮换
                    if (!rotator.rotate()) { break }     // 所有 key 耗尽
            }
        }
        return ArrayList<SearchHit>()  // 引擎链降级
    }

    private func doTavilySearch(key: String, query: String, maxResults: Int64): ?ArrayList<SearchHit> {
        // POST https://api.tavily.com/search
        // body: { api_key: key, query, max_results, search_depth: "basic" }
        // 返回 Some(hits) 成功 / None 认证或限流失败
        // 注意：空结果列表是合法成功（Some([])），不是认证失败
        ...
    }
}

// ===== DDG 实现（零 key 兜底）=====

public class DDGProvider <: SearchProvider {
    public init() {}
    public func name(): String { "ddg" }
    public func enabled(): Bool { true }  // 永远兜底
    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        // GET https://api.duckduckgo.com/?q={query}&format=json&no_html=1
        // 解析 AbstractText + AbstractURL + RelatedTopics[].Text/FirstURL
        // 失败返回空列表
        ...
    }
}

// ===== 路由器 =====
//
// 两层降级：
//   1. 引擎内 key rotation：Tavily/Exa 单 key 失败 → 同引擎下一个 key
//   2. 引擎链降级：引擎所有 key 耗尽 → 路由跳下一个引擎
// DDG 永远兜底（无 key），保证零配置也能搜。

public class SearchRouter {
    private let providers: ArrayList<SearchProvider>
    public init(providers: ArrayList<SearchProvider>) { this.providers = providers }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        for (i in 0..providers.size) {
            let p = providers[i]
            if (!p.enabled()) { continue }
            // provider 内部已处理 key rotation，
            // search() 返回即代表该引擎（含所有 key）已尽力
            let hits = p.search(query, maxResults)
            if (hits.size > 0) { return hits }  // 命中就回
            // 空结果/超时 → 引擎链降级，跳下一个引擎
        }
        return ArrayList<SearchHit>()  // 全部失败返回空
    }
}

// ===== 工具注册 =====

public class WebSearchTool <: CjhTool {
    private let router: SearchRouter
    public init(router: SearchRouter) { this.router = router }
    public func isReadOnly(): Bool { true }  // 搜索是纯读

    public func spec(): ToolSpec {
        // 返回上面的 JSON Schema
        ...
    }

    public func execute(args: JsonObject): ToolResult {
        let query = args.get("query").getOrThrow().asString().getValue()
        let maxResults = (args.get("max_results") ?? JsonInt(5)).asInt().getValue()
        let hits = router.search(query, maxResults)
        // 格式化成上面的返回格式
        ...
    }
}
```

### 3.5 配置

`settings.json` 新增 `web_search` 段：

```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto",
    "tavily_api_keys": "",
    "exa_api_keys": "",
    "searxng_url": "",
    "max_results": 5,
    "timeout_seconds": 8
  }
}
```

| 字段 | 说明 | 默认 |
|---|---|---|
| `enabled` | 是否启用 web_search | true |
| `provider` | 搜索后端：`auto` / `tavily` / `exa` / `searxng` / `ddg` | auto |
| `tavily_api_keys` | Tavily API Key，**逗号分隔多 key**（空则跳过） | "" |
| `exa_api_keys` | Exa API Key，**逗号分隔多 key**（空则跳过） | "" |
| `searxng_url` | 自建 SearXNG URL（空则跳过） | "" |
| `max_results` | 最大返回结果数 | 5 |
| `timeout_seconds` | 单次搜索超时 | 8 |

**per-engine key rotation 配置示例**：

```json
{
  "web_search": {
    "tavily_api_keys": "tvly-key1,tvly-key2,tvly-key3",
    "exa_api_keys": "exa-keyA,exa-keyB"
  }
}
```

行为：Tavily 引擎先用 `tvly-key1`，触发 401/429/配额耗尽 → 轮换到 `tvly-key2`，以此类推；所有 Tavily key 耗尽 → 引擎链降级到 Exa（同理 key rotation），最终落到 DDG 兜底。

环境变量覆盖（环境变量同样支持逗号分隔多 key）：

| 变量 | 说明 |
|---|---|
| `TAVILY_API_KEYS` | Tavily API Key（逗号分隔多 key） |
| `EXA_API_KEYS` | Exa API Key（逗号分隔多 key） |
| `SEARXNG_URL` | SearXNG URL |
| `CJH_WEB_SEARCH_PROVIDER` | 强制指定 provider |

> **向后兼容**：单 key 场景下 `tavily_api_keys: "tvly-xxx"` 等价于旧字段 `tavily_api_key: "tvly-xxx"`。若同时配置了旧单 key 字段和新多 key 字段，以新字段为准。

## 四、web_fetch 工具设计

### 4.1 工具 Schema

```json
{
  "name": "web_fetch",
  "description": "Fetch the content of a web page and return it as clean text. Use this when you have a specific URL and want to read its content. The page HTML is cleaned (scripts, styles, navigation removed) and converted to plain text. Results are truncated to ~32KB. For searching the web, use web_search instead.",
  "parameters": {
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "The URL to fetch (must be http:// or https://)"
      },
      "max_chars": {
        "type": "integer",
        "description": "Maximum characters to return (default 32000, max 128000)",
        "default": 32000
      }
    },
    "required": ["url"]
  }
}
```

### 4.2 返回格式

```json
{
  "content": "URL: https://docs.cangjie-lang.com/ffi\nStatus: 200\nFinal URL: https://docs.cangjie-lang.com/ffi (0 redirects)\nTitle: Cangjie Language Guide - FFI\n\n---\n\n# Foreign Function Interface\n\nCangjie provides a foreign function interface (FFI) that allows you to call C library functions from Cangjie code...\n\n## Basic Usage\n\nUse the `@C` and `foreign` keywords to declare external functions...",
  "is_error": false
}
```

错误时：

```json
{
  "content": "Failed to fetch https://example.com: HTTP 403 (after curl fallback)",
  "is_error": true
}
```

### 4.3 核心实现流程

```
web_fetch(url, max_chars)
  ↓ 参数校验：必须 http/https，URL 长度上限（8KB，防数据外泄通道）
  ↓ 协议层校验：拒绝带 user:pass@ 的 URL（防凭证透传内网）
  ↓ SSRF egress guard：解析主机 → 查 DNS → 校验解析出的 IP 是否属于私有/保留段
  ↓ 构造 HTTP 请求（仓颉 stdx.net.http.ClientBuilder）
  ↓   - User-Agent: "cjh/1.3.0 (Cangjie Coding Agent)"
  ↓   - Accept: text/html,application/xhtml+xml,text/plain
  ↓   - 超时：连接 5s，读取 30s
  ↓   - 禁用自动 redirect，自己逐跳跟（每跳重过 SSRF 校验）
  ↓ GET 请求
  ↓ 拿到响应
  ↓   - 状态码非 2xx → 进入降级链
  ↓   - Content-Type 非 text/html/xhtml/plain → 报错
  ↓   - 下载体超 5MB → 截断 + 标记
  ↓ HTML 清洗：
  ↓   - 去 <script> <style> <nav> <footer> <aside> 标签
  ↓   - 去 HTML 注释
  ↓   - 去 class="ad" class="advertisement" 等广告标记
  ↓   - 保留 <article> <main> <section> <p> <h1>-<h6> <ul> <ol> <li> <pre> <code> <a> <table>
  ↓ HTML → 纯文本转换：
  ↓   - <h1>-<h6> → Markdown 标题（# ## ###）
  ↓   - <p> → 段落（\n\n 分隔）
  ↓   - <ul>/<ol> → Markdown 列表
  ↓   - <pre><code> → Markdown 代码块
  ↓   - <a href="...">text</a> → [text](...)
  ↓   - <table> → Markdown 表格
  ↓   - 其他标签剥离，保留纯文本
  ↓ 超长截断：截断到 max_chars，附 "\n...(truncated)" 标记
  ↓ 序列化成 tool result（content + final_url + status_code + truncated + title?）
  ↓ 失败 → 降级链
```

### 4.4 降级链实现

#### 第一层：仓颉 stdx.net.http GET（~50% 站点）

```cangjie
let client = ClientBuilder()
    .connectTimeout(Duration.second * 5)
    .readTimeout(Duration.second * 30)
    .build()
let resp = client.get(url).send()
```

失败条件：4xx/5xx 响应、超时、连接被重置、TLS 握手失败。

#### 第二层：exec curl（~70% 站点）

curl 能过"头检测 + TLS 指纹 + 配代理"三层，成功率从 ~50% 拉到 ~70%。

**安全封装**（数组式 exec 防注入）：

```cangjie
func execCurl(url: String, timeoutSeconds: Int64): ?String {
    // url 已经过 SSRF 校验 + 协议白名单
    let args = ArrayList<String>()
    args.add("curl")
    args.add("-sL")                           // 静默 + 跟重定向
    args.add("--max-time")                    // 总超时
    args.add(timeoutSeconds.toString())
    args.add("--connect-timeout")             // 连接超时
    args.add("5")
    args.add("-A")                            // 浏览器 UA
    args.add("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
    args.add("-H")                            // 浏览器头
    args.add("Accept: text/html,application/xhtml+xml,text/plain,*/*")
    args.add("-H")
    args.add("Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7")
    args.add("--max-filesize")               // 下载体硬上限
    args.add("5242880")                       // 5MB
    args.add(url)

    let result = Process.exec(args)          // 数组式 exec，不经过 shell
    // 解析 stdout，返回 ?String
    ...
}
```

**关键安全点**：

- 用数组式 `Process.exec(args)` 而不是字符串拼接的 shell 命令
- URL 在进入降级链前已过 SSRF 校验 + 协议白名单
- 不允许 URL 里带 `|`、`;`、`&`、`$`、`` ` `` 等 shell 元字符

#### 第三层：Firecrawl API（~96% 站点，免注册 1000 次/月）

Firecrawl 内部用 12 种抓取引擎并发竞速（Engine Waterfall Racing），官方宣称 96% 抓取成功率。Firecrawl Keyless 默认提供 1000 free credits/month，no account / no API key / no card，开箱即用。

**Firecrawl 降级的关键优势**：

- **免注册免 key**：Firecrawl Keyless 默认 1000 credits/month，无需注册或绑定信用卡
- **多引擎竞速抓取**：12 种抓取引擎并发竞速，通过 Promise.race + SnipeAbort 竞速取消慢引擎
- **LLM-ready Markdown 输出**：Firecrawl 返回清洗后的 Markdown，三层转换管线（Go 微服务 → Go FFI → JS TurndownService）+ Rust NAPI 后处理，无需 cjh 自己清洗 HTML
- **JS 渲染能力**：Firecrawl 能渲染 SPA 页面（React/Vue），弥补仓颉 HTTP GET + curl 不执行 JS 的短板

**Firecrawl API 调用**：

```
POST https://api.firecrawl.dev/v1/scrape
Authorization: Bearer {FIRECRAWL_API_KEY}  // 可选，Keyless 模式免 key
Content-Type: application/json

{
  "url": "https://example.com",
  "formats": ["markdown"],
  "onlyMainContent": true,
  "maxAge": 86400000
}
```

**响应**：

```json
{
  "success": true,
  "data": {
    "markdown": "# Page Title\n\nCleaned content in Markdown...",
    "metadata": {
      "title": "Page Title",
      "sourceURL": "https://example.com",
      "statusCode": 200
    }
  }
}
```

cjh 直接取 `data.markdown`，无需 HTML 清洗步骤。

**仓颉实现骨架**：

```cangjie
// libs/cjllm/src/firecrawl.cj（新增）
package cjllm

import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import std.json.*
import cjutil.*

public class FirecrawlClient {
    private let apiKey: String        // 可空（Keyless 模式）
    private let baseUrl: String = "https://api.firecrawl.dev/v1"

    public init(apiKey: String) { this.apiKey = apiKey }

    public func scrape(url: String): ?String {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .connectTimeout(Duration.second * 5)
                .readTimeout(Duration.second * 30)
                .build()

            // 构造请求体
            var body = JsonObject()
            body.add("url", JsonString(url))
            body.add("formats", JsonArray([JsonString("markdown")]))
            body.add("onlyMainContent", JsonBool(true))

            let req = HttpRequestBuilder()
                .post()
                .url("${this.baseUrl}/scrape")
                .header("Content-Type", "application/json")
                .apply({ r =>
                    if (this.apiKey.size > 0) {
                        r.header("Authorization", "Bearer ${this.apiKey}")
                    }
                })
                .body(body.toJsonString())
                .build()

            let resp = client.send(req)
            if (resp.status != 200) { return None }

            // 解析响应 JSON
            let respBody = readBody(resp.body, 1048576)  // 1MB 上限
            let json = JsonValue.parse(respBody)
            let success = json.get("success").getOrThrow().asBool().getValue()
            if (!success) { return None }
            let markdown = json.get("data").getOrThrow()
                .get("markdown").getOrThrow().asString().getValue()
            return Some(markdown)
        } catch (e: Exception) {
            return None
        }
    }
}
```

#### 第四层：返回错误

三层降级全失败 → 返回 `ToolResult("Failed to fetch {url} (cangjie HTTP + curl + Firecrawl all failed)", true)`，让 agent 换思路（换 URL、用 web_search 找别的、或者告诉用户这个站抓不了）。

### 4.5 SSRF 防护实现

```cangjie
// libs/cjutil/src/ssrf.cj（新增）
package cjutil

import std.net.*
import std.collection.*

public class SsrfGuard {
    // 私有/保留 IP 段判断
    public static func isPrivateIp(ip: String): Bool {
        // IPv4
        if (ip.startsWith("127.")) { return true }       // loopback
        if (ip.startsWith("10.")) { return true }         // RFC1918
        if (ip.startsWith("192.168.")) { return true }    // RFC1918
        if (ip.startsWith("169.254.")) { return true }    // link-local + 云元数据
        if (ip.startsWith("172.")) {
            // 172.16.0.0 - 172.31.255.255
            let parts = ip.split(".")
            if (parts.size >= 2) {
                let second = Int64.parse(parts[1])
                if (second >= 16 && second <= 31) { return true }
            }
        }
        // IPv6
        if (ip == "::1") { return true }                  // loopback
        if (ip.startsWith("fc") || ip.startsWith("fd")) { return true }  // unique-local
        if (ip.startsWith("fe80")) { return true }        // link-local
        if (ip.startsWith("ff")) { return true }          // multicast
        return false
    }

    // 解析主机名 → 检查所有 A/AAAA 记录
    public static func isHostAllowed(host: String): Bool {
        // 先查 DNS 解析
        let addrs = DnsResolver.resolve(host)  // 返回 ArrayList<String>
        if (addrs.size == 0) { return false }  // 解析失败，拒绝
        for (i in 0..addrs.size) {
            if (isPrivateIp(addrs[i])) { return false }
        }
        return true
    }

    // URL 校验入口
    public static func validateUrl(url: String): Bool {
        // 协议白名单
        if (!url.startsWith("http://") && !url.startsWith("https://")) { return false }
        // 拒绝带凭证的 URL
        if (url.contains("://") && url.contains("@")) { return false }
        // 提取主机名
        let host = extractHost(url)
        if (host.size == 0) { return false }
        // SSRF 检查
        return isHostAllowed(host)
    }
}
```

### 4.6 HTML 清洗实现

```cangjie
// libs/cjutil/src/html_cleaner.cj（新增）
package cjutil

import std.collection.*

public class HtmlCleaner {
    // HTML → 纯文本（带 Markdown 格式保留）
    public static func toMarkdown(html: String): String {
        var text = html
        // 1. 去 <script> <style> <nav> <footer> <aside> <noscript> <iframe> 块
        text = removeTags(text, ["script", "style", "nav", "footer", "aside", "noscript", "iframe", "form", "header"])
        // 2. 去 HTML 注释
        text = removeHtmlComments(text)
        // 3. 去 class="ad" class="advertisement" 等广告标记（简化版）
        text = removeAds(text)
        // 4. 标题转换：<h1>xxx</h1> → "# xxx"
        text = convertHeadings(text)
        // 5. 段落转换：<p>xxx</p> → "xxx\n\n"
        text = convertParagraphs(text)
        // 6. 列表转换：<ul><li> → "- "
        text = convertLists(text)
        // 7. 代码块转换：<pre><code> → "```...\n```"
        text = convertCodeBlocks(text)
        // 8. 链接转换：<a href="url">text</a> → "[text](url)"
        text = convertLinks(text)
        // 9. 表格转换：<table> → Markdown 表格
        text = convertTables(text)
        // 10. 剥离其他所有标签，保留纯文本
        text = stripRemainingTags(text)
        // 11. HTML 实体解码（&amp; &lt; &gt; &quot; &#39; &nbsp;）
        text = decodeHtmlEntities(text)
        // 12. 压缩多余空行
        text = compressWhitespace(text)
        return text
    }

    // 提取 <title> 标签内容
    public static func extractTitle(html: String): ?String { ... }
}
```

### 4.7 仓颉实现骨架

```cangjie
// src/tools/web_fetch.cj（新增）
package cjh.tools

import stdx.net.http.*
import std.io.*
import std.collection.*
import cjutil.*

public class WebFetchTool <: CjhTool {
    private let maxDownloadBytes: Int64 = 5242880  // 5MB
    private let defaultMaxChars: Int64 = 32000     // ~8K token
    private let hardMaxChars: Int64 = 128000       // 硬上限

    public init() {}
    public func isReadOnly(): Bool { true }  // 抓取是纯读

    public func spec(): ToolSpec {
        // 返回上面的 JSON Schema
        ...
    }

    public func execute(args: JsonObject): ToolResult {
        let url = args.get("url").getOrThrow().asString().getValue()
        let maxChars = (args.get("max_chars") ?? JsonInt(defaultMaxChars)).asInt().getValue()
        // 1. 参数校验
        if (url.size > 8192) { return ToolResult("URL too long", true) }
        // 2. SSRF 校验
        if (!SsrfGuard.validateUrl(url)) { return ToolResult("URL blocked by SSRF guard", true) }
        // 3. 第一层：仓颉 HTTP GET
        let result = fetchWithCangjie(url, maxChars)
        match (result) {
            case Some(content) => return ToolResult(content, false)
            case None => {}  // 进入降级链
        }
        // 4. 第二层：exec curl 降级
        let curlResult = fetchWithCurl(url, maxChars)
        match (curlResult) {
            case Some(content) => return ToolResult(content, false)
            case None => return ToolResult("Failed to fetch ${url} (cangjie HTTP + curl fallback both failed)", true)
        }
    }

    private func fetchWithCangjie(url: String, maxChars: Int64): ?String {
        try {
            let client = ClientBuilder()
                .connectTimeout(Duration.second * 5)
                .readTimeout(Duration.second * 30)
                .build()
            let req = HttpRequestBuilder()
                .get()
                .url(url)
                .header("User-Agent", "cjh/1.3.0 (Cangjie Coding Agent)")
                .header("Accept", "text/html,application/xhtml+xml,text/plain")
                .header("Accept-Language", "en-US,en;q=0.9,zh-CN;q=0.8")
                .build()
            let resp = client.send(req)
            if (resp.status < 200 || resp.status >= 300) { return None }
            // 读取 body（最多 5MB）
            let body = readBody(resp.body, maxDownloadBytes)
            // HTML 清洗 → Markdown
            let title = HtmlCleaner.extractTitle(body)
            let text = HtmlCleaner.toMarkdown(body)
            // 截断
            let truncated = text.size > maxChars
            let content = if (truncated) { text[0..maxChars.toInt64()] + "\n...(truncated)" } else { text }
            // 格式化输出
            let header = "URL: ${url}\nStatus: ${resp.status}\n"
            let titleLine = match (title) { case Some(t) => "Title: ${t}\n"; case None => "" }
            return Some(header + titleLine + "\n---\n\n" + content)
        } catch (e: Exception) {
            return None
        }
    }

    private func fetchWithCurl(url: String, maxChars: Int64): ?String {
        // 数组式 exec curl（防注入）
        // 返回 ?String
        ...
    }
}
```

## 五、工具注册与集成

### 5.1 注册到 ToolRegistry

在 `src/main.cj` 的 `runTui` / `runCli` / `runJson` / `runWeb` 中，构建 ToolRegistry 时注册新工具：

```cangjie
let registry = ToolRegistry()

// 内置工具
registry.register(BashTool(capability, registry))
registry.register(ReadFileTool())
registry.register(WriteFileTool())
registry.register(HashLineEditTool())
registry.register(GrepTool())
registry.register(ListDirTool())
registry.register(TodoWriteTool())

// 新增：web 工具
if (cjhCfg.webSearch.enabled) {
    let router = buildSearchRouter(cjhCfg)
    registry.register(WebSearchTool(router))
}
if (cjhCfg.webFetch.enabled) {
    registry.register(WebFetchTool())
}

// 插件
loadPlugins(cjhCfg, registry)

// MCP（异步）
let mcpMgr = loadMcpServers(cjhCfg.mcpServers, registry)
```

### 5.2 配置加载

在 `libs/cjcfg/src/config.cj` 中新增 `WebSearchConfig` 和 `WebFetchConfig`：

```cangjie
public class WebSearchConfig {
    public var enabled: Bool = true
    public var provider: String = "auto"
    public var tavilyApiKey: String = ""
    public var exaApiKey: String = ""
    public var searxngUrl: String = ""
    public var maxResults: Int64 = 5
    public var timeoutSeconds: Int64 = 8
}

public class WebFetchConfig {
    public var enabled: Bool = true
    public var allowedHosts: ArrayList<String> = ArrayList<String>()  // 空=允许所有（过 SSRF 后）
    public var allowInternalHosts: Bool = false  // 是否允许 localhost 开发服务器
    public var maxChars: Int64 = 32000
    public var timeoutSeconds: Int64 = 30
}
```

`loadSettings` 解析 `settings.json` 的 `web_search` 和 `web_fetch` 段，环境变量覆盖 key。

### 5.3 SSRF 防护与 allow_internal_hosts

`web_fetch` 的 SSRF 防护默认拦截所有私有/保留 IP。但开发场景下用户可能想抓 `http://localhost:3000` 本地开发服务器：

- `allow_internal_hosts: false`（默认）：拦截所有私有 IP
- `allow_internal_hosts: true`：允许 `localhost` / `127.0.0.1`，但仍拦截 `169.254.169.254` 云元数据

## 六、安全考虑

### 6.1 Prompt Injection 防护

Agent 可能被诱导疯狂抓站烧流量。防护措施：

1. **会话级 fetch 次数预算**：默认每会话最多 20 次 `web_fetch`，超出拒绝
2. **会话级 fetch 字节预算**：默认每会话最多 1MB 下载体，超出拒绝
3. **搜索次数预算**：默认每会话最多 30 次 `web_search`，超出拒绝
4. **冷却退避**：provider 返回 429 时，该 provider 冷却 60 秒，路由跳下一个

### 6.2 SSRF 防护清单

| 防护层 | 实现 |
|---|---|
| 协议白名单 | 只收 http/https，拒绝 ftp/file/gopher/data 等 |
| 凭证拒绝 | URL 带 `user:pass@` 直接拒 |
| IP 段拦截 | loopback / link-local / RFC1918 / unique-local / multicast 全拒 |
| 重定向重校 | 每跳都重新过 SSRF 校验，跳数上限 5 |
| DNS Reinding | （已知局限）先解析校验 IP、再交 reqwest 连接时重解析，存在 TOCTOU 窗口。cjh 目前不做 connect-to-pinned-IP + Host 头覆写，但默认行为已挡住绝大多数注入 |

### 6.3 内容安全

- HTML 清洗后转纯文本，剥离所有 `<script>` 标签，防止恶意 JS 内容污染上下文
- HTML 实体解码（`&amp;` → `&`）避免乱码
- 超长截断 + `(truncated)` 标记，防 token 爆炸

## 七、配置示例

### 7.1 最小配置（零 key 兜底）

```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto"
  },
  "web_fetch": {
    "enabled": true
  }
}
```

效果：web_search 走 DDG 免 key 兜底，web_fetch 走仓颉 HTTP GET + curl 降级链。

### 7.2 推荐配置（配 Tavily key 升级搜索质量）

```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto",
    "tavily_api_key": "tvly-xxxxxxxxxxxx",
    "max_results": 5
  },
  "web_fetch": {
    "enabled": true,
    "max_chars": 32000,
    "timeout_seconds": 30
  }
}
```

效果：web_search 走 Tavily（主力）→ DDG（兜底），web_fetch 走降级链。

### 7.3 自建 SearXNG 配置（零成本无限搜索）

```json
{
  "web_search": {
    "enabled": true,
    "provider": "searxng",
    "searxng_url": "http://127.0.0.1:8080",
    "max_results": 10
  }
}
```

效果：web_search 走自建 SearXNG（聚合 Google/Bing/DDG/70+ 后端），完全免费无 key 无配额。

### 7.4 开发场景配置（允许抓 localhost）

```json
{
  "web_fetch": {
    "enabled": true,
    "allow_internal_hosts": true
  }
}
```

效果：web_fetch 允许抓 `http://localhost:3000` 本地开发服务器，但仍拦截云元数据 `169.254.169.254`。

## 八、文件清单

新增文件：

| 文件 | 职责 |
|---|---|
| `src/tools/web_search.cj` | web_search 工具 + SearchProvider 接口 + TavilyProvider + ExaProvider + DDGProvider + SearXNGProvider + SearchRouter |
| `src/tools/web_fetch.cj` | web_fetch 工具 + 仓颉 HTTP GET + curl 降级链 |
| `libs/cjutil/src/ssrf.cj` | SSRF 防护（IP 段判断 + DNS 解析校验 + URL 校验） |
| `libs/cjutil/src/html_cleaner.cj` | HTML 清洗 → Markdown 纯文本 |

修改文件：

| 文件 | 修改 |
|---|---|
| `libs/cjcfg/src/config.cj` | 新增 `WebSearchConfig` + `WebFetchConfig` + `loadSettings` 解析 |
| `src/main.cj` | `runTui` / `runCli` / `runJson` / `runWeb` 注册 web 工具 |
| `docs/cjh功能清单.md` | 新增 web 工具章节 |
| `README.md` / `README.en.md` | 工具列表新增 web_search / web_fetch |

## 九、与现有系统的集成点

### 9.1 与两大硬性指标的对齐

| 指标 | 对齐方式 |
|---|---|
| **省 token** | web_search 每条 snippet 截断到 500 字符，默认返回 5 条；web_fetch HTML 清洗后截断到 ~32KB；会话级 fetch 字节预算防 prompt injection 烧流量 |
| **高执行效率** | web_fetch 三级降级链（仓颉 HTTP → curl → 返回错误），成功率从 ~50% 拉到 ~70%；SSRF 校验失败 fast-fail，不浪费时间重试 |

### 9.2 与插件信任链的对齐

web_search / web_fetch 是**内置工具**，不走插件信任链。但它们遵守 `ToolRegistry` 的 `isReadOnly` 分类：

- `web_search`：`isReadOnly() = true`（纯读）
- `web_fetch`：`isReadOnly() = true`（纯读）

两者都可以在 V2d 并发引擎中与其他 read-only 工具并发执行。

### 9.3 与三域 Capability 的对齐

web_search / web_fetch 归属 `resources` 域（外部网络资源访问）。如果用户配置了 capability 白名单，需要显式允许这两个工具。

### 9.4 与 Web 支持的对齐

Web 模式下（`cjh web`），前端可通过 WebSocket 触发带 web_search 的对话。web_fetch 的结果同样走 Agent Loop 的 observe 阶段塞回上下文。

## 十、实现优先级

| 优先级 | 任务 | 说明 |
|---|---|---|
| P0 | `web_fetch` 仓颉 HTTP GET + HTML 清洗 + SSRF 防护 | 最基础，不依赖任何外部 API key |
| P0 | `web_search` DDGProvider 兜底 | 零 key 即可用 |
| P1 | `web_search` TavilyProvider | 主力搜索后端，配 key 即升级 |
| P1 | `web_fetch` curl 降级链 | 提升抓取成功率到 ~70% |
| P2 | `web_search` ExaProvider | 语义搜索，长尾查询强 |
| P2 | `web_search` SearXNGProvider | 自建零成本方案 |
| P3 | 会话级 fetch/search 预算 | 防 prompt injection 烧流量 |
| P3 | `web_fetch` CSS selector 参数 | 只抽指定容器，减少噪声 token |

## 十一、测试计划

### 11.1 单元测试

- `SsrfGuard.isPrivateIp`：覆盖所有私有/保留 IP 段
- `SsrfGuard.validateUrl`：覆盖协议白名单、凭证拒绝、IP 段拦截
- `HtmlCleaner.toMarkdown`：覆盖标题/段落/列表/代码块/链接/表格转换
- `DDGProvider.search`：mock HTTP 响应，验证解析
- `TavilyProvider.search`：mock HTTP 响应，验证解析
- `SearchRouter.search`：mock 多 provider，验证路由 + 退避

### 11.2 集成测试

- `web_search("cangjie language")` → 返回非空结果列表
- `web_fetch("https://httpbin.org/get")` → 返回 JSON 响应纯文本
- `web_fetch("http://169.254.169.254/latest/meta-data/")` → SSRF 拦截，返回错误
- `web_fetch("http://localhost:3000")` → 默认拦截；`allow_internal_hosts: true` 时放行
- `web_fetch` 降级链：mock 仓颉 HTTP GET 失败 → 验证 curl 降级触发

### 11.3 Mock 模式测试

在 `--mock` 模式下，web_search / web_fetch 返回固定 mock 数据，验证工具链端到端流程。

## 十二、参考实现

| 项目 | 语言 | web_search 实现 | web_fetch 实现 |
|---|---|---|---|
| **AtomCode** | Rust | SearchProvider trait + Exa 默认 + reqwest tokio 异步 | reqwest + SSRF egress guard + html5ever 清洗 + Servo SPA |
| **omp** | TypeScript | 14+ provider 链 + Auto 滑落 + Bun fetch | browser（Puppeteer 无头 Chromium） |
| **ModSearch** | TypeScript | Firecrawl 默认免注册 + Tavily/Exa/Grok 多引擎故障转移 | Firecrawl 抓取 |
| **cjh**（本设计） | Cangjie | SearchProvider interface + Auto 路由 + Tavily/Exa/DDG/SearXNG | 仓颉 stdx.net.http + curl 降级链 + SSRF 防护 + HTML 清洗 |

cjh 的差异化优势：

1. **仓颉原生单二进制**：无 Node/Bun 运行时依赖，`cjh` 一个二进制自带联网能力
2. **零默认依赖**：DDG 兜底 + curl 降级，不强制用户配 key 或装额外依赖
3. **SSRF 防护对齐 AtomCode**：多层独立拦截（协议层 + IP 层 + 重定向重校），防止 agent 被诱导抓内网
4. **省 token 设计对齐 Pi**：snippet 截断 + HTML 清洗 + 会话级预算，web 工具输出严格控 token

## 十三、已知局限与未来扩展

### 13.1 已知局限

1. **SPA 页面抓取弱**：仓颉 stdx.net.http 不执行 JS，React/Vue 单页应用只能拿到静态壳。curl 降级也解决不了。未来可考虑接 Servo 或轻量 JS 引擎（但增加依赖）
2. **DDG 兜底覆盖窄**：DuckDuckGo Instant Answer API 只返摘要不返 SERP，长尾查询空白。生产 agent 请至少配一个 Tavily/Exa 免费 key
3. **DNS Rebinding TOCTOU**：先解析校验 IP、再交连接时重解析，存在理论攻击窗口。cjh 目前不做 connect-to-pinned-IP + Host 头覆写
4. **中文搜索弱**：DDG 中文摘要弱，Tavily 中文一般。未来可加博查 AI 搜索（国内 1000 次/月免费、中文强）作为第五个 provider

### 13.2 未来扩展方向

1. **web_search 加博查 AI 搜索 provider**：国内 1000 次/月免费，中文强，注册成本低
2. **web_fetch 接 Servo**：轻量 Rust 浏览器引擎，能渲染 JS 页面，比 Puppeteer 省内存（但增加依赖，需评估）
3. **web_search 加 Brave Search provider**：注意 Brave 免费档 2026.2 已砍掉，要 $5/月最低消费 + 绑卡
4. **web_fetch 加 Firecrawl 降级层**：搜+抓合一，1000 次/月免费，作为第三级降级（但需要 API key）
5. **会话级 fetch/search 预算的 config 化**：让用户可配 `max_fetches_per_session` / `max_searches_per_session` / `max_fetch_bytes_per_session`
6. **web_search 结果缓存**：相同 query 短时间内不重复请求后端，省 API 配额

---

## 附录 A：DuckDuckGo Instant Answer API 详解

**端点**：`https://api.duckduckgo.com/?q={query}&format=json&no_html=1&skip_disambig=1`

**参数**：

| 参数 | 说明 |
|---|---|
| `q` | 查询字符串 |
| `format` | 输出格式：`json` 或 `xml` |
| `no_html` | 1 = 移除 HTML 标签 |
| `skip_disambig` | 1 = 跳过消歧响应 |
| `pretty` | 1 = 美化 JSON 输出 |
| `no_redirect` | 1 = 跳过 HTTP 重定向（用于 !bang 命令） |

**响应字段**：

| 字段 | 说明 |
|---|---|
| `Abstract` | 主题摘要（可能含 HTML） |
| `AbstractText` | 主题摘要（纯文本） |
| `AbstractSource` | 摘要来源名（通常是 Wikipedia） |
| `AbstractURL` | 源页面深链接 |
| `Heading` | 主题名称 |
| `Answer` | 即时答案值（如计算器结果） |
| `AnswerType` | 即时答案类型 |
| `Definition` | 字典定义文本 |
| `DefinitionSource` | 定义来源 |
| `DefinitionURL` | 定义深链接 |
| `RelatedTopics` | 相关主题数组（每个含 `Text` + `FirstURL`） |
| `Results` | 外部链接数组 |
| `Type` | 响应类型：A=article, D=disambiguation, C=category, N=name, E=exclusive, 空=nothing |
| `Redirect` | !bang 查询的重定向 URL |

**示例**：`GET https://api.duckduckgo.com/?q=valley+forge+national+park&format=json&no_html=1`

## 附录 B：Tavily Search API 详解

**端点**：`POST https://api.tavily.com/search`

**请求体**：

```json
{
  "api_key": "tvly-xxxxxxxxxxxx",
  "query": "cangjie language FFI binding",
  "max_results": 5,
  "search_depth": "basic",
  "include_answer": false,
  "include_raw_content": false,
  "include_domains": [],
  "exclude_domains": []
}
```

**search_depth 选项**：

| 值 | 说明 | 成本 |
|---|---|---|
| `advanced` | 最高相关度，增加延迟 | 2 API Credits |
| `basic` | 平衡相关度和延迟（默认） | 1 API Credit |
| `fast` | 优先低延迟 | 1 API Credit |
| `ultra-fast` | 最小延迟 | 1 API Credit |

**响应体**：

```json
{
  "results": [
    {
      "title": "Cangjie Language Guide - FFI",
      "url": "https://docs.cangjie-lang.com/ffi",
      "content": "The foreign function interface...",
      "score": 0.95,
      "raw_content": "..." // optional
    }
  ],
  "query": "cangjie language FFI binding",
  "response_time": 1.23,
  "answer": "..." // optional
}
```

**免费额度**：1000 次/月自动续，不绑卡。

## 附录 C：Exa Search API 详解

**端点**：`GET https://api.exa.ai/v1/search`

**请求头**：

```
Authorization: Bearer {EXA_API_KEY}
Content-Type: application/json
```

**请求体**：

```json
{
  "query": "cangjie language FFI binding",
  "numResults": 5,
  "type": "keyword"
}
```

**type 选项**：

| 值 | 说明 |
|---|---|
| `keyword` | 关键词搜索 |
| `neural` | 语义搜索（长尾查询强） |
| `auto` | 自动选择 |

**响应体**：

```json
{
  "results": [
    {
      "title": "Cangjie Language Guide - FFI",
      "url": "https://docs.cangjie-lang.com/ffi",
      "text": "The foreign function interface...",
      "score": 0.95
    }
  ]
}
```

**免费额度**：送 $20 + 每月 $10 自动续（约 1400 次基础搜索/月），不绑卡。
