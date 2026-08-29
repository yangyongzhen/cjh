package cjh

/**
 * 工具装配：web 工具、插件、MCP 服务器注册到 ToolRegistry
 *
 * registerWebTools：web_search 多后端路由 + web_fetch 三级降级链
 * loadPlugins：扫描插件目录，注册插件工具
 * loadMcpServers：异步连接 MCP 服务器，注册 MCP 工具
 */

import std.collection.*
import cjlog.*
import cjcfg.*
import cjh.tools.*
import cjh.web.*
import cjutil.*
import stdx.log.*
/**
 * 注册 web_search + web_fetch 工具到 registry
 *
 * web_search：SearchProvider 多后端路由 + per-engine key rotation
 * web_fetch：三级降级链（仓颉 HTTP GET + curl + Firecrawl）+ SSRF 防护
 *
 * 配置来自 cjhCfg.webSearch* / cjhCfg.webFetch*
 */
func registerWebTools(cjhCfg: CjhConfig, registry: ToolRegistry): Unit {
    // 会话级预算（防 prompt injection 烧流量/API key）
    // 默认：20 fetches · 30 searches · 1MB download
    let budget = WebBudget(20, 30, 1048576)

    // web_search
    if (cjhCfg.webSearchEnabled) {
        let providers = ArrayList<SearchProvider>()
        let providerMode = cjhCfg.webSearchProvider
        // Auto 模式：Exa MCP（零 key 主力）→ Tavily → Exa REST → SearXNG → 搜狗/Bing 兜底
        // 借鉴 atomcode：Exa MCP 是主力 provider，无 key 也能用
        let needExaMcp = (providerMode == "auto" || providerMode == "exa-mcp")
        let needTavily = (providerMode == "auto" || providerMode == "tavily") && cjhCfg.webSearchTavilyKeys.size > 0
        let needExa = (providerMode == "auto" || providerMode == "exa") && cjhCfg.webSearchExaKeys.size > 0
        let needSearXNG = (providerMode == "auto" || providerMode == "searxng") && cjhCfg.webSearchSearxngUrl.size > 0
        let needDDG = (providerMode == "auto" || providerMode == "ddg")
        if (needExaMcp) {
            providers.add(ExaMcpProvider(cjhCfg.webSearchTimeoutSeconds))
        }
        if (needTavily) {
            providers.add(TavilyProvider(cjhCfg.webSearchTavilyKeys, cjhCfg.webSearchTimeoutSeconds))
        }
        if (needExa) {
            providers.add(ExaProvider(cjhCfg.webSearchExaKeys, cjhCfg.webSearchTimeoutSeconds))
        }
        if (needSearXNG) {
            providers.add(SearXNGProvider(cjhCfg.webSearchSearxngUrl, cjhCfg.webSearchTimeoutSeconds))
        }
        if (needDDG) {
            providers.add(SogouProvider(cjhCfg.webSearchTimeoutSeconds))
            providers.add(BingProvider(cjhCfg.webSearchTimeoutSeconds))
        }
        // 没有任何 provider，兜底用 Exa MCP + 搜狗 + Bing
        if (providers.size == 0) {
            providers.add(ExaMcpProvider(cjhCfg.webSearchTimeoutSeconds))
            providers.add(SogouProvider(cjhCfg.webSearchTimeoutSeconds))
            providers.add(BingProvider(cjhCfg.webSearchTimeoutSeconds))
        }
        let router = SearchRouter(providers)
        registry.register(WebSearchTool(router, cjhCfg.webSearchMaxResults, budget))
    }

    // web_fetch
    if (cjhCfg.webFetchEnabled) {
        let tool = WebFetchTool(cjhCfg.webFetchAllowInternal, cjhCfg.webFetchMaxChars, cjhCfg.webFetchTimeoutSeconds, budget)
        registry.register(tool)
    }
}

/**
 * 加载插件（V2b Step 1）
 * 扫描 pluginsDir 下每个子目录的 plugin.json，注册插件工具到 registry。
 * 白名单 enabled 为空时全部启用。
 * requireSignature=true 时强制插件必须带完整签名。
 * 返回创建的 PluginManager（供 Agent 事件钩子使用）。
 */
func loadPlugins(pluginsDir: String, registry: ToolRegistry,
    enabled: ArrayList<String>, requireSignature: Bool): PluginManager {
    let pm = PluginManager(pluginsDir)
    pm.loadAll(registry, enabled, requireSignature)
    return pm
}

/**
 * 异步加载 MCP 服务器
 *
 * 纯异步：spawn 后台 connectAll，主线程不等待，TUI 立即启动。
 * MCP 连上后 connectAll 自然把工具 register 到 registry
 * （registry 已加锁，后台 register 与主线程读并发安全）。
 *
 * 返回创建的 McpManager（用于退出时断开连接）。
 */
func loadMcpServers(servers: ArrayList<McpServerConfig>,
    registry: ToolRegistry): McpManager {
    let mgr = McpManager()
    if (servers.size == 0) {
        return mgr
    }
    // 后台异步连接，不阻塞主线程
    spawn {
        try {
            mgr.connectAll(servers, registry)
        } catch (e: Exception) {
            Log.warn("[MCP] connectAll 异常: ${e}")
        }
    }
    return mgr
}
