package cjcfg

import std.fs.*
import stdx.encoding.json.*
import std.collection.*

/**
 * 模型条目（settings.json models 数组项；对齐 pi models.json 的轻量版）
 */
public class ModelEntry {
    public var id: String = ""          // 模型 ID（传给 API）
    public var name: String = ""        // 显示名（可空，默认用 id）
    public var baseUrl: String = ""     // 端点（可空，用全局 base_url）
    public var apiKey: String = ""      // 该模型的 key（可空，用全局 api_key）
    public var temperature: Float64 = 0.7
    public var maxTokens: Int64 = 16384
}

/**
 * MCP 服务器配置（settings.json "mcp_servers" 段）
 *
 * 支持两种传输：
 *   - stdio：启动子进程，JSON-RPC over stdin/stdout（MUST 支持）
 *   - sse  ：远程服务器，HTTP+SSE（可选，暂未实现）
 *
 * stdio 配置示例：
 *   "filesystem": {
 *     "transport": "stdio",
 *     "command": "npx",
 *     "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
 *   }
 */
public class McpServerConfig {
    public let name: String               // 服务器名（唯一标识）
    public var transport: String = "stdio" // "stdio" | "sse"
    public var command: String = ""        // stdio：可执行命令
    public var args: ArrayList<String> = ArrayList<String>()  // stdio：命令参数
    public var url: String = ""            // sse：服务器 URL
    public var env: HashMap<String, String> = HashMap<String, String>()  // 子进程环境变量

    public init(name: String) {
        this.name = name
    }
}

/**
 * 配置系统（对标成熟 agent 的配置目录设计）
 *
 * 目录结构（~/.cjh/，可用 CJH_CONFIG_DIR 覆盖）：
 *   settings.json    # 主配置：模型/端点/行为
 *   auth.json        # 凭据：API keys（文件权限 600）
 *   sessions/        # 会话历史（JSON）
 *   tools/           # 自定义工具（预留）
 *
 * 优先级（高→低）：环境变量 > auth.json/settings.json > 内置默认
 */
public class CjhConfig {
    // 配置目录
    public let configDir: String
    public let settingsPath: String
    public let authPath: String
    public let sessionsDir: String
    // 技能目录（~/.cjh/skills/<name>.md，按需加载注入 system prompt）
    public let skillsDir: String

    // 配置值
    public var baseUrl: String = "https://api.openai.com/v1/chat/completions"
    public var model: String = "gpt-4o-mini"
    public var apiKey: String = ""
    public var maxIterations: Int64 = 50
    public var systemPrompt: String = ""
    // 采样参数（对齐 pi：/settings 可调）
    public var temperature: Float64 = 0.7
    public var maxTokens: Int64 = 16384
    // 可选模型列表（settings.json "models": [...]；/model 可切换）
    public var models: ArrayList<ModelEntry> = ArrayList<ModelEntry>()
    // 三域 capability 安全模型（settings.json "capability": {...}；未配置=宽松模式）
    public var capability: Capability = Capability.fromJson(None)
    // Compaction：消息条数超阈值触发 LLM 摘要压缩早期历史（0=禁用，对齐 pi 自动摘要）
    public var compactThreshold: Int64 = 0
    // 压缩时保留的最近消息条数
    public var compactKeep: Int64 = 12
    // 启用的技能白名单（settings.json "enabled_skills": [...]；空=全部启用）
    public var enabledSkills: ArrayList<String> = ArrayList<String>()
    // TUI 主题（settings.json "theme": "starfrost"|"classic"|...；空=starfrost 默认）
    public var theme: String = "starfrost"
    // 工具结果截断阈值（字符数，0 或负数=禁用截断）
    // 超过阈值的工具结果保留头尾 + 中间省略标记，完整结果落盘到 spillDir
    public var toolResultMaxChars: Int64 = 6000
    // 落盘根目录：工具结果超长时完整内容写到此目录下 <sessionId>/<toolCallId>.txt
    public let spillDir: String
    // 插件根目录：~/.cjh/plugins/<plugin-name>/plugin.json
    public let pluginsDir: String
    // 启用的插件白名单（settings.json "enabled_plugins": [...]；空=全部启用）
    public var enabledPlugins: ArrayList<String> = ArrayList<String>()
    // 是否强制插件必须带签名（settings.json "require_signature": true）
    // 默认 false：无签名插件照常加载
    // 开启 true：无 checksum 或无 pubkey/signature 的插件拒绝加载
    public var requireSignature: Bool = false
    // MCP 服务器配置列表（settings.json "mcp_servers" 段）
    public var mcpServers: ArrayList<McpServerConfig> = ArrayList<McpServerConfig>()
    // ===== Web 服务器配置（settings.json "web" 段）=====
    // 是否启用 Web 服务器（cjh web 子命令强制启用）
    public var webEnabled: Bool = false
    // Web 服务器监听端口
    public var webPort: UInt16 = 8765
    // Web 服务器绑定地址（默认 127.0.0.1 仅本机访问；0.0.0.0 局域网访问）
    public var webBindAddr: String = "127.0.0.1"
    // Web 服务器鉴权 token（空=不鉴权；远程访问强烈建议设置）
    public var webAuthToken: String = ""
    // HTTP 请求体最大字节数（防大请求 OOM）
    public var webMaxRequestSize: Int64 = 1048576

    // ===== Web 搜索配置（settings.json "web_search" 段）=====
    public var webSearchEnabled: Bool = true
    public var webSearchProvider: String = "auto"  // auto|tavily|exa|searxng|ddg
    public var webSearchTavilyKeys: String = ""     // 逗号分隔多 key
    public var webSearchExaKeys: String = ""        // 逗号分隔多 key
    public var webSearchSearxngUrl: String = ""
    public var webSearchMaxResults: Int64 = 5
    public var webSearchTimeoutSeconds: Int64 = 8

    // ===== Web 抓取配置（settings.json "web_fetch" 段）=====
    public var webFetchEnabled: Bool = true
    public var webFetchAllowInternal: Bool = false  // 是否允许抓 localhost 开发服务器
    public var webFetchMaxChars: Int64 = 32000      // ~8K token
    public var webFetchTimeoutSeconds: Int64 = 30

    public init() {
        // 配置目录：环境变量覆盖，默认 ~/.cjh
        let home = readEnv("HOME") ?? "/root"
        this.configDir = readEnv("CJH_CONFIG_DIR") ?? (home + "/.cjh")
        this.settingsPath = this.configDir + "/settings.json"
        this.authPath = this.configDir + "/auth.json"
        this.sessionsDir = this.configDir + "/sessions"
        this.skillsDir = this.configDir + "/skills"
        this.spillDir = this.configDir + "/spill"
        this.pluginsDir = this.configDir + "/plugins"
        this.load()
    }

    /**
     * 确保配置目录存在（含 sessions/）
     */
    public func ensureDirs(): Unit {
        if (!exists(this.configDir)) {
            Directory.create(this.configDir, recursive: true)
        }
        if (!exists(this.sessionsDir)) {
            Directory.create(this.sessionsDir, recursive: true)
        }
        if (!exists(this.spillDir)) {
            Directory.create(this.spillDir, recursive: true)
        }
        if (!exists(this.pluginsDir)) {
            Directory.create(this.pluginsDir, recursive: true)
        }
        // 首次运行：自动生成配置文件模板
        this.ensureTemplate(this.settingsPath, this.settingsTemplate())
        this.ensureTemplate(this.authPath, this.authTemplate())
    }

    /**
     * 文件不存在时写入模板
     */
    private func ensureTemplate(path: String, content: String): Unit {
        if (!exists(path)) {
            try {
                File.writeTo(path, content.toArray())
                eprintln("[cjh] 已生成配置文件: ${path}")
            } catch (e: Exception) {
                eprintln("[cjh] 生成配置文件失败 ${path}: ${e}")
            }
        }
    }

    /**
     * settings.json 模板（包含所有配置项，空值不生效，用户按需填写）
     */
    private func settingsTemplate(): String {
        return """
{
  "_说明": "cjh 配置文件。空字符串/0/false 表示用默认值不生效。修改后重启 cjh 生效。完整字段说明见 docs/。",

  "base_url": "https://api.openai.com/v1/chat/completions",
  "model": "gpt-4o-mini",
  "max_iterations": 10,
  "temperature": 0.7,
  "max_tokens": 16384,
  "system_prompt": "",

  "theme": "starfrost",
  "tool_result_max_chars": 6000,
  "compact_threshold": 0,
  "compact_keep": 12,

  "enabled_skills": [],
  "enabled_plugins": [],
  "require_signature": false,

  "models": [
    { "id": "gpt-4o-mini", "name": "GPT-4o mini" },
    { "id": "deepseek-chat", "name": "DeepSeek V3", "base_url": "https://api.deepseek.com/v1/chat/completions", "temperature": 1.0 }
  ],

  "_capability_说明": "三域安全白名单（可选，默认宽松模式全部放行）。不配置 capability 字段 = 宽松模式，所有工具/命令/路径全部放行。想启用时在下方添加 capability 字段，必须设 enabled: true 才启用严格模式（未声明即拒绝），默认 enabled: false（宽松模式）。子字段：identifier/commands/tools/resources/approval。示例见 docs/进度记录 V2a。",

  "mcp_servers": {
    "_说明": "MCP 服务器配置。每个 key 是服务器名，value 含 transport/command/args/url/env。示例见 docs/MCP设计.md。",
    "_example_stdio": { "transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] },
    "_example_sse": { "transport": "sse", "url": "http://127.0.0.1:8080/sse" }
  },

  "web": {
    "_说明": "Web 服务器配置（cjh web 子命令）。远程访问强烈建议设置 auth_token。",
    "enabled": false,
    "port": 8765,
    "bind_addr": "127.0.0.1",
    "auth_token": "",
    "max_request_size": 1048576
  },

  "web_search": {
    "_说明": "Web 搜索配置。provider 可选 auto|exa-mcp|tavily|exa|searxng|ddg。auto 模式降级链：Exa MCP → 搜狗 → Bing → 付费 provider。",
    "enabled": true,
    "provider": "auto",
    "tavily_api_keys": "",
    "exa_api_keys": "",
    "searxng_url": "",
    "max_results": 5,
    "timeout_seconds": 8
  },

  "web_fetch": {
    "_说明": "Web 抓取配置。allow_internal_hosts=true 允许抓 localhost（开发服务器）。三级降级：Cangjie HTTP → curl → Firecrawl。",
    "enabled": true,
    "allow_internal_hosts": false,
    "max_chars": 32000,
    "timeout_seconds": 30
  }
}
"""
    }

    /**
     * 写回 provider 配置（/provider 命令）：更新 settings.json 的 base_url/model，
     * 保留文件里已有的其他字段（读-改-写）。文件不存在则先建模板再更新。
     */
    public func saveProvider(baseUrl: String, model: String): Unit {
        this.ensureDir(this.configDir)
        var root = JsonObject()
        if (exists(this.settingsPath)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.settingsPath)))
                match (json.kind()) {
                    case JsonKind.JsObject => root = json.asObject()
                    case _ => ()
                }
            } catch (e: Exception) {
                eprintln("[cjh] settings.json 解析失败，重建: ${e}")
            }
        }
        root.put("base_url", JsonString(baseUrl))
        root.put("model", JsonString(model))
        File.writeTo(this.settingsPath, root.toJsonString().toArray())
        // 同步内存配置
        this.baseUrl = baseUrl
        this.model = model
    }

    /**
     * 写回 TUI 主题（/theme 命令）：更新 settings.json 的 theme 字段，
     * 保留文件里已有的其他字段（读-改-写）。文件不存在则先建模板再更新。
     */
    public func saveTheme(theme: String): Unit {
        this.ensureDir(this.configDir)
        var root = JsonObject()
        if (exists(this.settingsPath)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.settingsPath)))
                match (json.kind()) {
                    case JsonKind.JsObject => root = json.asObject()
                    case _ => ()
                }
            } catch (e: Exception) {
                eprintln("[cjh] settings.json 解析失败，重建: ${e}")
            }
        }
        root.put("theme", JsonString(theme))
        File.writeTo(this.settingsPath, root.toJsonString().toArray())
        // 同步内存配置
        this.theme = theme
    }

    /**
     * 写回 API Key（/provider 命令）：更新 auth.json 的 api_key 字段，
     * 保留其他兼容字段。同时同步内存 apiKey。
     */
    public func saveApiKey(key: String): Unit {
        this.ensureDir(this.configDir)
        var root = JsonObject()
        if (exists(this.authPath)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.authPath)))
                match (json.kind()) {
                    case JsonKind.JsObject => root = json.asObject()
                    case _ => ()
                }
            } catch (e: Exception) {
                eprintln("[cjh] auth.json 解析失败，重建: ${e}")
            }
        }
        root.put("api_key", JsonString(key))
        File.writeTo(this.authPath, root.toJsonString().toArray())
        this.apiKey = key
    }

    /**
     * 保存全部可编辑字段到 settings.json（读-改-写，保留未知字段）。
     * 供 Web 配置页面 POST /api/settings 调用。
     */
    public func saveAll(): Unit {
        this.ensureDir(this.configDir)
        var root = JsonObject()
        if (exists(this.settingsPath)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.settingsPath)))
                match (json.kind()) {
                    case JsonKind.JsObject => root = json.asObject()
                    case _ => ()
                }
            } catch (e: Exception) {
                eprintln("[cjh] settings.json 解析失败，重建: ${e}")
            }
        }
        // 写入所有可编辑字段
        root.put("base_url", JsonString(this.baseUrl))
        root.put("model", JsonString(this.model))
        root.put("max_iterations", JsonInt(this.maxIterations))
        root.put("system_prompt", JsonString(this.systemPrompt))
        root.put("temperature", JsonFloat(this.temperature))
        root.put("max_tokens", JsonInt(this.maxTokens))
        root.put("compact_threshold", JsonInt(this.compactThreshold))
        root.put("compact_keep", JsonInt(this.compactKeep))
        root.put("tool_result_max_chars", JsonInt(this.toolResultMaxChars))
        root.put("theme", JsonString(this.theme))
        // enabled_skills / enabled_plugins
        let skillsArr = JsonArray()
        for (i in 0..this.enabledSkills.size) {
            skillsArr.add(JsonString(this.enabledSkills[i]))
        }
        root.put("enabled_skills", skillsArr)
        let pluginsArr = JsonArray()
        for (i in 0..this.enabledPlugins.size) {
            pluginsArr.add(JsonString(this.enabledPlugins[i]))
        }
        root.put("enabled_plugins", pluginsArr)
        // web 配置
        root.put("web_port", JsonInt(Int64(this.webPort)))
        root.put("web_bind_addr", JsonString(this.webBindAddr))
        root.put("web_auth_token", JsonString(this.webAuthToken))
        // web search
        root.put("web_search_enabled", JsonBool(this.webSearchEnabled))
        root.put("web_search_provider", JsonString(this.webSearchProvider))
        root.put("web_search_max_results", JsonInt(this.webSearchMaxResults))
        root.put("web_fetch_enabled", JsonBool(this.webFetchEnabled))
        root.put("web_fetch_max_chars", JsonInt(this.webFetchMaxChars))
        File.writeTo(this.settingsPath, root.toJsonString().toArray())
    }

    /**
     * 确保目录存在（save 系列写文件前调用）
     */
    private func ensureDir(dir: String): Unit {
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    /**
     * auth.json 模板（api_key 任一字段填写即可）
     */
    private func authTemplate(): String {
        return "{\n" +
            "  \"_说明\": \"在此填写 API Key：api_key 或 openai_api_key / deepseek_api_key / dashscope_api_key 任一即可。如：sk-xxxx\",\n" +
            "  \"api_key\": \"\",\n" +
            "  \"openai_api_key\": \"\",\n" +
            "  \"deepseek_api_key\": \"\",\n" +
            "  \"dashscope_api_key\": \"\"\n" +
            "}\n"
    }

    /**
     * 加载配置：settings.json + auth.json，然后环境变量覆盖
     */
    private func load(): Unit {
        this.loadSettings()
        this.loadAuth()
        this.applyEnvOverrides()
        // 默认系统提示词
        if (this.systemPrompt.size == 0) {
            this.systemPrompt = "You are a coding agent running in the terminal (cjh). You can use tools to complete tasks: bash executes commands, read_file reads files, write_file writes files, append_file appends to files, edit_file modifies files." +
                " Tasks usually require multiple steps: first read code to understand the current state, then modify, then verify with bash. Keep it concise, answer in Chinese." +
                "\n\n## Tool selection strategy\n" +
                " 1. Read files with read_file (NOT bash awk/tail/wc). First call read_file WITHOUT offset/limit to load the whole file; only paginate with offset/limit if the file is large (>500 lines).\n" +
                " 2. Read multiple files in parallel: issue several read_file calls in ONE turn.\n" +
                " 3. Edit existing files with edit_file (NOT bash sed/awk).\n" +
                " 4. Use bash ONLY for: git, builds, package managers, running commands, short aggregation (wc/sort/uniq).\n" +
                " 5. List directories with list_dir, find files with glob, search contents with grep — not bash ls/find/rg.\n" +
                " Forbidden: using bash awk/tail/head/sed to extract file content that read_file already provides." +
                "\n\n## Do not hallucinate encodings\n" +
                " read_file and bash return plain text. If you see normal source code (HTML/JS/CSS), it IS the file content — do NOT run python3/awk/od to 'decode' it. Only use od/hexdump on genuinely binary files." +
                "\n\n## Large file write strategy\n" +
                " write_file has a max_tokens limit. For files >150 lines: first write_file the skeleton, then append_file multiple chunks (each <1500 chars), last chunk appends closing tags. Never rewrite a truncated file with write_file — use append_file to continue."
        }
    }

    public func loadSettings(): Unit {
        if (!exists(this.settingsPath)) {
            return
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.settingsPath)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(v) <- obj.get("base_url")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.baseUrl = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("model")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.model = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("max_iterations")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.maxIterations = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("system_prompt")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.systemPrompt = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("temperature")) {
                        match (v.kind()) {
                            case JsonKind.JsFloat => this.temperature = v.asFloat().getValue()
                            case JsonKind.JsInt => this.temperature = Float64(v.asInt().getValue())
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("max_tokens")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.maxTokens = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    // capability 三域安全模型（未配置=宽松模式）
                    if (let Some(v) <- obj.get("capability")) {
                        this.capability = Capability.fromJson(Some(v))
                    }
                    // Compaction：消息条数阈值（0=禁用）+ 保留最近条数
                    if (let Some(v) <- obj.get("compact_threshold")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.compactThreshold = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("compact_keep")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.compactKeep = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    // 启用技能白名单（空=全部启用）
                    if (let Some(v) <- obj.get("enabled_skills")) {
                        match (v.kind()) {
                            case JsonKind.JsArray =>
                                let arr = v.asArray()
                                for (i in 0..arr.size()) {
                                    if (let Some(item) <- arr.get(i)) {
                                        match (item.kind()) {
                                            case JsonKind.JsString =>
                                                this.enabledSkills.add(item.asString().getValue())
                                            case _ => ()
                                        }
                                    }
                                }
                            case _ => ()
                        }
                    }
                    // 启用插件白名单（空=全部启用）
                    if (let Some(v) <- obj.get("enabled_plugins")) {
                        match (v.kind()) {
                            case JsonKind.JsArray =>
                                let arr = v.asArray()
                                for (i in 0..arr.size()) {
                                    if (let Some(item) <- arr.get(i)) {
                                        match (item.kind()) {
                                            case JsonKind.JsString =>
                                                this.enabledPlugins.add(item.asString().getValue())
                                            case _ => ()
                                        }
                                    }
                                }
                            case _ => ()
                        }
                    }
                    // 是否强制插件必须带签名（默认 false）
                    if (let Some(v) <- obj.get("require_signature")) {
                        match (v.kind()) {
                            case JsonKind.JsBool => this.requireSignature = v.asBool().getValue()
                            case _ => ()
                        }
                    }
                    // MCP 服务器配置（mcp_servers 段，object 形态）
                    if (let Some(v) <- obj.get("mcp_servers")) {
                        match (v.kind()) {
                            case JsonKind.JsObject =>
                                let serversObj = v.asObject()
                                for ((serverName, serverCfg) in serversObj.getFields()) {
                                    match (serverCfg.kind()) {
                                        case JsonKind.JsObject =>
                                            let cfg = McpServerConfig(serverName)
                                            let so = serverCfg.asObject()
                                            // transport（默认 stdio）
                                            if (let Some(t) <- so.get("transport")) {
                                                match (t.kind()) {
                                                    case JsonKind.JsString => cfg.transport = t.asString().getValue()
                                                    case _ => ()
                                                }
                                            }
                                            // command（stdio 启动命令）
                                            if (let Some(c) <- so.get("command")) {
                                                match (c.kind()) {
                                                    case JsonKind.JsString => cfg.command = c.asString().getValue()
                                                    case _ => ()
                                                }
                                            }
                                            // args（命令参数数组）
                                            if (let Some(a) <- so.get("args")) {
                                                match (a.kind()) {
                                                    case JsonKind.JsArray =>
                                                        let argsArr = a.asArray()
                                                        for (i in 0..argsArr.size()) {
                                                            if (let Some(argItem) <- argsArr.get(i)) {
                                                                match (argItem.kind()) {
                                                                    case JsonKind.JsString =>
                                                                        cfg.args.add(argItem.asString().getValue())
                                                                    case _ => ()
                                                                }
                                                            }
                                                        }
                                                    case _ => ()
                                                }
                                            }
                                            // url（sse 远程服务器）
                                            if (let Some(u) <- so.get("url")) {
                                                match (u.kind()) {
                                                    case JsonKind.JsString => cfg.url = u.asString().getValue()
                                                    case _ => ()
                                                }
                                            }
                                            // env（子进程环境变量）
                                            if (let Some(e) <- so.get("env")) {
                                                match (e.kind()) {
                                                    case JsonKind.JsObject =>
                                                        let envObj = e.asObject()
                                                        for ((k, vv) in envObj.getFields()) {
                                                            match (vv.kind()) {
                                                                case JsonKind.JsString =>
                                                                    cfg.env.add(k, vv.asString().getValue())
                                                                case _ => ()
                                                            }
                                                        }
                                                    case _ => ()
                                                }
                                            }
                                            this.mcpServers.add(cfg)
                                        case _ => ()
                                    }
                                }
                            case _ => ()
                        }
                    }
                    // TUI 主题（starfrost|classic|...；未配置=starfrost 默认）
                    if (let Some(v) <- obj.get("theme")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.theme = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    // Web 服务器配置（settings.json "web" 段，object 形态）
                    if (let Some(v) <- obj.get("web")) {
                        match (v.kind()) {
                            case JsonKind.JsObject =>
                                let webObj = v.asObject()
                                // enabled
                                match (webObj.get("enabled")) {
                                    case Some(e) =>
                                        match (e.kind()) {
                                            case JsonKind.JsBool => this.webEnabled = e.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // port
                                match (webObj.get("port")) {
                                    case Some(p) =>
                                        match (p.kind()) {
                                            case JsonKind.JsInt =>
                                                let portVal = p.asInt().getValue()
                                                if (portVal >= 0 && portVal <= 65535) {
                                                    this.webPort = UInt16(portVal)
                                                }
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // bind_addr
                                match (webObj.get("bind_addr")) {
                                    case Some(b) =>
                                        match (b.kind()) {
                                            case JsonKind.JsString => this.webBindAddr = b.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // auth_token
                                match (webObj.get("auth_token")) {
                                    case Some(t) =>
                                        match (t.kind()) {
                                            case JsonKind.JsString => this.webAuthToken = t.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                // max_request_size
                                match (webObj.get("max_request_size")) {
                                    case Some(m) =>
                                        match (m.kind()) {
                                            case JsonKind.JsInt => this.webMaxRequestSize = m.asInt().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                            case _ => ()
                        }
                    }
                    // 工具结果截断阈值（字符数，0 或负数=禁用截断）
                    if (let Some(v) <- obj.get("tool_result_max_chars")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.toolResultMaxChars = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    // ===== web_search 段 =====
                    if (let Some(v) <- obj.get("web_search")) {
                        match (v.kind()) {
                            case JsonKind.JsObject =>
                                let ws = v.asObject()
                                match (ws.get("enabled")) {
                                    case Some(e) =>
                                        match (e.kind()) {
                                            case JsonKind.JsBool => this.webSearchEnabled = e.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("provider")) {
                                    case Some(p) =>
                                        match (p.kind()) {
                                            case JsonKind.JsString => this.webSearchProvider = p.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("tavily_api_keys")) {
                                    case Some(k) =>
                                        match (k.kind()) {
                                            case JsonKind.JsString => this.webSearchTavilyKeys = k.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("exa_api_keys")) {
                                    case Some(k) =>
                                        match (k.kind()) {
                                            case JsonKind.JsString => this.webSearchExaKeys = k.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("searxng_url")) {
                                    case Some(u) =>
                                        match (u.kind()) {
                                            case JsonKind.JsString => this.webSearchSearxngUrl = u.asString().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("max_results")) {
                                    case Some(m) =>
                                        match (m.kind()) {
                                            case JsonKind.JsInt => this.webSearchMaxResults = m.asInt().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (ws.get("timeout_seconds")) {
                                    case Some(t) =>
                                        match (t.kind()) {
                                            case JsonKind.JsInt => this.webSearchTimeoutSeconds = t.asInt().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                            case _ => ()
                        }
                    }
                    // ===== web_fetch 段 =====
                    if (let Some(v) <- obj.get("web_fetch")) {
                        match (v.kind()) {
                            case JsonKind.JsObject =>
                                let wf = v.asObject()
                                match (wf.get("enabled")) {
                                    case Some(e) =>
                                        match (e.kind()) {
                                            case JsonKind.JsBool => this.webFetchEnabled = e.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (wf.get("allow_internal_hosts")) {
                                    case Some(a) =>
                                        match (a.kind()) {
                                            case JsonKind.JsBool => this.webFetchAllowInternal = a.asBool().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (wf.get("max_chars")) {
                                    case Some(m) =>
                                        match (m.kind()) {
                                            case JsonKind.JsInt => this.webFetchMaxChars = m.asInt().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                                match (wf.get("timeout_seconds")) {
                                    case Some(t) =>
                                        match (t.kind()) {
                                            case JsonKind.JsInt => this.webFetchTimeoutSeconds = t.asInt().getValue()
                                            case _ => ()
                                        }
                                    case _ => ()
                                }
                            case _ => ()
                        }
                    }
                    // models 列表：每项可覆盖 id/name/base_url/api_key/temperature/max_tokens
                    if (let Some(v) <- obj.get("models")) {
                        match (v.kind()) {
                            case JsonKind.JsArray =>
                                let arr = v.asArray()
                                for (i in 0..arr.size()) {
                                    if (let Some(item) <- arr.get(i)) {
                                        match (item.kind()) {
                                            case JsonKind.JsObject =>
                                                let mo = item.asObject()
                                                let entry = ModelEntry()
                                                if (let Some(f) <- mo.get("id")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsString => entry.id = f.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(f) <- mo.get("name")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsString => entry.name = f.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(f) <- mo.get("base_url")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsString => entry.baseUrl = f.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(f) <- mo.get("api_key")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsString => entry.apiKey = f.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(f) <- mo.get("temperature")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsFloat => entry.temperature = f.asFloat().getValue()
                                                        case JsonKind.JsInt => entry.temperature = Float64(f.asInt().getValue())
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(f) <- mo.get("max_tokens")) {
                                                    match (f.kind()) {
                                                        case JsonKind.JsInt => entry.maxTokens = f.asInt().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (entry.id.size > 0) {
                                                    this.models.add(entry)
                                                }
                                            case _ => ()
                                        }
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            eprintln("[cjh] settings.json 解析失败: ${e}")
        }
    }

    private func loadAuth(): Unit {
        if (!exists(this.authPath)) {
            return
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.authPath)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    // 兼容多种字段名
                    for (key in ["api_key", "openai_api_key", "deepseek_api_key", "dashscope_api_key"]) {
                        if (let Some(v) <- obj.get(key)) {
                            match (v.kind()) {
                                case JsonKind.JsString =>
                                    let k = v.asString().getValue()
                                    if (k.size > 0 && this.apiKey.size == 0) {
                                        this.apiKey = k
                                    }
                                case _ => ()
                            }
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            eprintln("[cjh] auth.json 解析失败: ${e}")
        }
    }

    /**
     * 环境变量覆盖（最高优先级）
     */
    private func applyEnvOverrides(): Unit {
        let key = readEnv("OPENAI_API_KEY") ?? readEnv("DEEPSEEK_API_KEY") ??
            readEnv("DASHSCOPE_API_KEY") ?? readEnv("CJH_API_KEY") ?? ""
        if (key.size > 0) {
            this.apiKey = key
        }
        let baseUrl = readEnv("CJH_BASE_URL") ?? readEnv("OPENAI_BASE_URL") ?? ""
        if (baseUrl.size > 0) {
            this.baseUrl = baseUrl
        }
        let model = readEnv("CJH_MODEL") ?? readEnv("OPENAI_MODEL") ?? ""
        if (model.size > 0) {
            this.model = model
        }
    }

    /**
     * 读取环境变量（经 EnvFfi 封装）
     */
    private static func readEnv(name: String): Option<String> {
        return EnvFfi.getenv(name)
    }
}
