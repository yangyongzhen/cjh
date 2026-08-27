package cjh

import std.collection.*
import std.env.*
import std.fs.*
import std.convert.Parsable
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjh.agent.*
import cjh.tools.*
import cjllm.*
import cjh.tui.*
import cjh.web.*
import cjterm.*
import cjcfg.*
import cjutil.*
import stdx.log.*

@C
foreign func getenv(name: CString): CPointer<UInt8>

/**
 * 读取环境变量（FFI getenv，返回空指针表示未设置）
 */
func readEnv(name: String): Option<String> {
    unsafe {
        let p = getenv(LibC.mallocCString(name))
        if (p.isNull()) {
            return None
        }
        let cs = CString(p)
        return Some(cs.toString())
    }
}


class VerifyState {
    static var toolCalls: Int64 = 0
}

/**
 * --mock 模式：离线验证 agent 工具调用链（无 API Key 环境）
 */
func runMockVerify(): Int64 {
    let testPath = "/tmp/cjh_verify.txt"
    File.writeTo(testPath, "line1\nline2\nline3\n".toArray())

    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())

    let provider = MockProvider(testPath)
    let config = AgentConfig("你是测试代理。", 5)
    let agent = Agent(provider, registry, config)

    VerifyState.toolCalls = 0
    agent.onToolStart = { name, args =>
        VerifyState.toolCalls += 1
        println("  ▶ 工具调用 #${VerifyState.toolCalls}: ${name} ${args.toJsonString()}")
    }
    agent.onToolResult = { name, result =>
        var preview = result.content
        if (preview.size > 60) {
            preview = truncateUtf8(preview, 60) + "…"
        }
        println("  ↳ ${name} 结果: ${preview}")
    }

    println("=== cjh agent 工具调用链验证（4 段）===")
    let summary = agent.run("请读取 /tmp/cjh_verify.txt 并统计行数")
    println("=== 最终答复 ===")
    println(summary.reply)

    if (VerifyState.toolCalls == 3 && summary.reply.contains("验证完成")) {
        println("\n✅ 验证通过：工具调用链完整（read_file → grep → list_dir → 最终答复）")
        return 0
    } else {
        println("\n❌ 验证失败：工具调用=${VerifyState.toolCalls}（期望 3）")
        return 1
    }
}


/**
 * 由配置生成 LLM provider（业务装配，不属于 cjcfg 通用库）
 * 提供商选择：
 *   - CJH_PROVIDER=ollama 或 base_url 含 localhost/127.0.0.1 → OllamaProvider（本地模型，apiKey 可空）
 *   - CJH_PROVIDER=anthropic → AnthropicProvider
 *   - 默认 → OpenAiProvider（OpenAI/DeepSeek/通义 等兼容协议）
 */
func makeProvider(cfg: CjhConfig): LlmProvider {
    // provider 选择：显式 CJH_PROVIDER=anthropic 才用 Anthropic
    // （auth.json 的 key 优先；env 变量可覆盖。绝不自动劫持到 Anthropic）
    let providerName = readEnv("CJH_PROVIDER") ?? ""
    // Ollama 本地模型：CJH_PROVIDER=ollama 或 base_url 指向 localhost/127.0.0.1
    let isOllama = (providerName == "ollama") ||
        cfg.baseUrl.contains("localhost") || cfg.baseUrl.contains("127.0.0.1")
    // Ollama 本地服务无需认证，apiKey 可空；其他 provider 必须有 apiKey
    if (!isOllama && cfg.apiKey.size == 0) {
        throw LlmException(
            "未配置 API Key。请在 ${cfg.authPath} 的 api_key 字段填写，或设置 OPENAI_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY 环境变量")
    }
    var p: LlmProvider
    if (isOllama) {
        // Ollama 端点：base_url 已指向 localhost/127.0.0.1 时优先用配置；
        // 否则（CJH_PROVIDER=ollama 但 base_url 是云端默认）强制 localhost
        let ollamaBase = if (cfg.baseUrl.contains("localhost") ||
            cfg.baseUrl.contains("127.0.0.1")) {
            cfg.baseUrl
        } else {
            "http://localhost:11434/v1"
        }
        p = OllamaProvider(ollamaBase, cfg.apiKey, cfg.model)
    } else if (providerName == "anthropic") {
        let anthropicKey = readEnv("ANTHROPIC_API_KEY") ?? readEnv("ANTHROPIC_AUTH_TOKEN") ?? cfg.apiKey
        let anthropicBase = readEnv("ANTHROPIC_BASE_URL") ?? "https://api.anthropic.com/v1/messages"
        p = AnthropicProvider(anthropicBase, anthropicKey, cfg.model)
    } else {
        p = OpenAiProvider(cfg.baseUrl, cfg.apiKey, cfg.model)
    }
    // 应用采样参数（/settings 调整后重建 provider 时生效）
    match (p) {
        case oa: OpenAiProvider => oa.setSampling(cfg.temperature, cfg.maxTokens)
        case ap: AnthropicProvider => ap.setSampling(cfg.temperature, cfg.maxTokens)
        case op: OllamaProvider => op.setSampling(cfg.temperature, cfg.maxTokens)
        case _ => ()
    }
    return p
}

/**
 * 从标准输入读取一行（基于 getStdIn 流）
 */
func readLineFromStdIn(): Option<String> {
    try {
        let stdin = getStdIn()
        var buf = Array<Byte>(1024, repeat: 0)
        let n = stdin.read(buf)
        if (n <= 0) {
            return None
        }
        var line = safeFromUtf8(buf[0..n])
        // 去尾部换行
        while (line.size > 0 && (line[line.size - 1] == 10u8 || line[line.size - 1] == 13u8)) {
            line = line[0..line.size - 1]
        }
        return Some(line)
    } catch (e: Exception) {
        return None
    }
}

/**
 * 字节安全截断：最多截取 maxBytes 字节，若落在 UTF-8 多字节字符中间则递减到合法边界
 * （与 cjterm TuiCanvas.truncate 同思路；避免 String 切片在字符中间抛
 *  IllegalArgumentException: Invalid utf8 byte sequence）
 */
func truncateUtf8(text: String, maxBytes: Int64): String {
    if (text.size <= maxBytes) {
        return text
    }
    var k = maxBytes
    while (k > 0) {
        try {
            return text[0..k]
        } catch (e: Exception) {
            k -= 1
        }
    }
    return ""
}

/**
 * 加载项目指令（AGENTS.md，对齐 pi 的 AGENTS.md 能力）：
 * 从当前工作目录开始逐级向上查找，找到第一个 AGENTS.md 读取其内容；
 * 找不到返回 ""。内容注入 system prompt（项目级指令优先于全局配置）。
 */
func loadProjectInstructions(): String {
    var dir = getWorkingDirectory()
    var depth: Int64 = 0
    while (depth < 8) {
        let p = dir.toString() + "/AGENTS.md"
        if (exists(p)) {
            try {
                let content = safeFromUtf8(File.readFrom(p))
                if (content.size > 0) {
                    return content
                }
            } catch (e: Exception) {
                ()
            }
        }
        let parent = dir.parent
        if (parent.toString() == dir.toString()) {
            break
        }
        dir = parent
        depth += 1
    }
    return ""
}

/**
 * 解析 Markdown frontmatter（--- 之间的 YAML 子集）。
 * 返回字段名 → 原始值字符串的 map。支持两种形态：
 *   1) 单行标量：`name: xxx` → value = "xxx"
 *   2) 多行块：`tools:` 单独成行，其后到下一个顶级 key 或 frontmatter
 *      结束的所有行合并为 value（保留 JSON 数组字面量）
 * 标量值做 trimAscii；多行块保留原始缩进与换行，由调用方按 JSON 解析。
 */
func parseFrontmatter(fm: String): HashMap<String, String> {
    let result = HashMap<String, String>()
    let lines = fm.split("\n", -1)
    var i = 0
    while (i < lines.size) {
        let line = lines[i]
        let t = line.trimAscii()
        if (t.size == 0 || t.startsWith("#")) {
            i += 1
            continue
        }
        // key: value 单行形态
        let colon = t.indexOf(":")
        if (colon.isSome()) {
            let key = t[0..colon.getOrThrow()].trimAscii()
            let rest = t[colon.getOrThrow() + 1..t.size].trimAscii()
            if (rest.size > 0) {
                // 单行标量：key: value
                result.add(key, rest)
                i += 1
            } else {
                // 多行块：key: 单独成行，后续缩进行合并
                var sb = StringBuilder()
                var j = i + 1
                var gathered: Bool = false
                while (j < lines.size) {
                    let nl = lines[j]
                    let nt = nl.trimAscii()
                    // 空行或注释跳过
                    if (nt.size == 0) {
                        j += 1
                        continue
                    }
                    // 下一个顶级 key（非缩进、含冒号）则结束块
                    let nColon = nt.indexOf(":")
                    if (nColon.isSome() && nl.size > 0 && nl[0] != 32u8 /* ' ' */ && nl[0] != 9u8 /* '\t' */) {
                        break
                    }
                    // 缩进行：合并（保留 trimAscii 后内容，换行分隔）
                    if (gathered) {
                        sb.append("\n")
                    }
                    sb.append(nt)
                    gathered = true
                    j += 1
                }
                if (gathered) {
                    result.add(key, sb.toString())
                }
                i = j
            }
        } else {
            i += 1
        }
    }
    return result
}

/**
 * 统计 frontmatter tools 段里声明的工具数（JSON 数组长度）。
 * 解析失败或非数组返回 0。
 */
func countSkillTools(toolsStr: String): Int64 {
    try {
        let v = JsonValue.fromStr(toolsStr)
        match (v.kind()) {
            case JsonKind.JsArray => return Int64(v.asArray().size())
            case _ => return 0
        }
    } catch (e: Exception) {
        return 0
    }
}

/**
 * 技能是否启用（enabledSkills 空=全部启用；非空=白名单）
 */
func skillEnabled(name: String, enabled: ArrayList<String>): Bool {
    if (enabled.size == 0) {
        return true
    }
    for (e in enabled) {
        if (e == name) {
            return true
        }
    }
    return false
}

/**
 * 列示技能（/skills 命令）：扫描 ~/.cjh/skills/<name>.md，输出名称、启用状态、
 * 前端声明的描述与携带工具数；无技能目录时提示创建方法。
 */
func listSkills(skillsDir: String, enabled: ArrayList<String>, tui: TuiApp): Unit {
    if (!exists(skillsDir)) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[技能目录不存在: ${skillsDir}；创建 ~/.cjh/skills/<name>.md 即可启用]" + Ansi.reset())
        return
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    if (files.size == 0) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[无技能；创建 ~/.cjh/skills/<name>.md（frontmatter: name/description + 正文指令）]" + Ansi.reset())
        return
    }
    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用技能（settings.json 的 enabled_skills 白名单控制开关，空=全部启用）：" + Ansi.reset())
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            var name = f[0..f.size - 3]
            var desc = ""
            var toolCount: Int64 = 0
            if (content.startsWith("---")) {
                let endFm = content.indexOf("\n---")
                if (endFm.isSome()) {
                    let fm = content[3..endFm.getOrThrow()]
                    let fields = parseFrontmatter(fm)
                    if (let Some(v) <- fields.get("name")) {
                        if (v.size > 0) {
                            name = v
                        }
                    }
                    if (let Some(v) <- fields.get("description")) {
                        if (v.size > 0) {
                            desc = v
                        }
                    }
                    if (let Some(v) <- fields.get("tools")) {
                        // 统计 tools JSON 数组里的对象数
                        toolCount = countSkillTools(v)
                    }
                }
            }
            let state = if (skillEnabled(name, enabled)) {
                Ansi.fg(Ansi.THEME_OK) + "● 启用" + Ansi.reset()
            } else {
                Ansi.fg(Ansi.THEME_MUTED) + "○ 禁用" + Ansi.reset()
            }
            var line = "  ${state} ${name}"
            if (desc.size > 0) {
                line += " — ${desc}"
            }
            if (toolCount > 0) {
                line += Ansi.fg(Ansi.THEME_MUTED) + " [${toolCount} 个声明式工具]" + Ansi.reset()
            }
            tui.appendOutput(line)
        } catch (e: Exception) {
            ()
        }
    }
    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "示例：/skills 查看；编辑 ~/.cjh/settings.json 的 enabled_skills 数组切换开关" + Ansi.reset())
}

/**
 * 加载技能（Skills，对齐 pi 的按需能力包）：
 * 扫描 ~/.cjh/skills/<name>.md（v2 4.3c"技能即文件"：Markdown 文本资产，
 * frontmatter 声明 name/description + 正文为指令），把所有技能指令拼接返回；
 * 目录不存在或无技能返回 ""。技能指令注入 system prompt（按需能力，不破缓存）。
 */
func loadSkills(skillsDir: String, enabled: ArrayList<String>): String {
    if (!exists(skillsDir)) {
        return ""
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    if (files.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    var count: Int64 = 0
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            if (content.size == 0) {
                continue
            }
            // 提取 frontmatter：---\nname: xxx\ndescription: xxx\n---\n正文
            var name = f[0..f.size - 3]  // 去 .md
            var body = content
            if (content.startsWith("---")) {
                let endFm = content.indexOf("\n---")
                if (endFm.isSome()) {
                    let fmEnd = endFm.getOrThrow()
                    let fm = content[3..fmEnd]
                    let fields = parseFrontmatter(fm)
                    if (let Some(v) <- fields.get("name")) {
                        if (v.size > 0) {
                            name = v
                        }
                    }
                    body = content[fmEnd + 4..content.size].trimAscii()
                }
            }
            // 白名单过滤：未启用的技能不注入
            if (!skillEnabled(name, enabled)) {
                continue
            }
            if (body.size == 0) {
                continue
            }
            if (count > 0) {
                sb.append("\n\n")
            }
            sb.append("### 技能：${name}\n")
            sb.append(body)
            count += 1
        } catch (e: Exception) {
            ()
        }
    }
    return sb.toString()
}

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
        // Auto 模式：Tavily → Exa → SearXNG → DDG 兜底
        let needTavily = (providerMode == "auto" || providerMode == "tavily") && cjhCfg.webSearchTavilyKeys.size > 0
        let needExa = (providerMode == "auto" || providerMode == "exa") && cjhCfg.webSearchExaKeys.size > 0
        let needSearXNG = (providerMode == "auto" || providerMode == "searxng") && cjhCfg.webSearchSearxngUrl.size > 0
        let needDDG = (providerMode == "auto" || providerMode == "ddg")
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
            providers.add(DDGProvider(cjhCfg.webSearchTimeoutSeconds))
        }
        // 没有任何 provider，兜底用 DDG
        if (providers.size == 0) {
            providers.add(DDGProvider(cjhCfg.webSearchTimeoutSeconds))
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
 * 加载技能携带的声明式工具（对齐 v2 4.3b 声明式形态）：
 * 技能 frontmatter 的 tools 段为 JSON 数组，每项 {name, description, command, args?}，
 * 注册为 DeclarativeTool（shell 模板 + 参数 schema，低门槛）。
 * 无 tools 段或解析失败则跳过该技能；技能目录不存在时静默。
 */
func loadSkillTools(skillsDir: String, registry: ToolRegistry, enabled: ArrayList<String>): Unit {
    if (!exists(skillsDir)) {
        return
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            if (content.size == 0 || !content.startsWith("---")) {
                continue
            }
            let endFm = content.indexOf("\n---")
            if (endFm.isNone()) {
                continue
            }
            let fm = content[3..endFm.getOrThrow()]
            let fields = parseFrontmatter(fm)
            // 技能名（frontmatter name 或文件名去 .md），白名单过滤
            var name = f[0..f.size - 3]
            if (let Some(v) <- fields.get("name")) {
                if (v.size > 0) {
                    name = v
                }
            }
            if (!skillEnabled(name, enabled)) {
                continue
            }
            // frontmatter 的 tools 段（多行 JSON 数组），注册声明式工具
            if (let Some(toolsStr) <- fields.get("tools")) {
                if (toolsStr.size > 0) {
                    registerSkillTools(toolsStr, registry)
                }
            }
        } catch (e: Exception) {
            ()
        }
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

/**
 * 解析 tools JSON 数组并注册声明式工具
 */
func registerSkillTools(jsonStr: String, registry: ToolRegistry): Unit {
    try {
        let v = JsonValue.fromStr(jsonStr)
        match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    if (let Some(item) <- arr.get(i)) {
                        match (item.kind()) {
                            case JsonKind.JsObject =>
                                let obj = item.asObject()
                                let name = obj.get("name").getOrThrow().asString().getValue()
                                let desc = obj.get("description").getOrThrow().asString().getValue()
                                let cmd = obj.get("command").getOrThrow().asString().getValue()
                                // 参数 schema（可选）：args: {"argName": "描述"}
                                var argSpecs = HashMap<String, (String, String)>()
                                if (let Some(av) <- obj.get("args")) {
                                    match (av.kind()) {
                                        case JsonKind.JsObject =>
                                            let ao = av.asObject()
                                            for ((k, sv) in ao.getFields()) {
                                                match (sv.kind()) {
                                                    case JsonKind.JsString =>
                                                        argSpecs.add(k, ("string", sv.asString().getValue()))
                                                    case _ => ()
                                                }
                                            }
                                        case _ => ()
                                    }
                                }
                                let tool = DeclarativeTool(name, desc, cmd, argSpecs)
                                registry.register(tool)
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
    } catch (e: Exception) {
        ()
    }
}

/**
 * 组装 system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
 */
func buildSystemPrompt(base: String, skillsDir: String, enabled: ArrayList<String>): String {
    var s = base
    let instr = loadProjectInstructions()
    if (instr.size > 0) {
        s += "\n\n## 项目指令（AGENTS.md）\n" + instr
    }
    let skills = loadSkills(skillsDir, enabled)
    if (skills.size > 0) {
        s += "\n\n## 可用技能（Skills，按需使用）\n" + skills
    }
    // 工具结果截断与回溯（对标 Pi spill extension）
    s += "\n\n## 工具结果截断\n当工具返回的结果过长时，cjh 会自动截断：保留结果的头部和尾部，"
    s += "中间被截断的部分会保存到磁盘文件。省略标记里会显示完整结果的保存路径。\n"
    s += "如果你需要查看被截断的中间部分，请使用 read_file 工具读取省略标记中提到的文件路径。"
    s += "你可以指定 offset 和 limit 参数来读取特定区段。"
    return s
}

/**
 * 工具参数紧凑显示（无大括号）：
 *   bash → 直接展示命令文本：▶ bash cat hello.cpp && ./hello
 *   read/list/write → 直接展示路径：▶ read_file hello.cpp
 *   grep 等多字段 → 主字段值 + 其余 "key: value" 平铺
 * 字符串值取原始文本（避免 toJsonString 的 \u0026 等 JSON 转义），超长截断。
 */
func formatToolArgs(name: String, args: JsonObject): String {
    let fields = args.getFields()
    if (fields.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    var first: Bool = true
    // 主字段：bash→command，其余→path（直接展示值，无 key 前缀）
    let mainKey = if (name == "bash") { "command" } else { "path" }
    if (let Some(v) <- args.get(mainKey)) {
        sb.append(shortArgValue(v))
        first = false
    }
    // 其余字段：key: value 平铺（无大括号）
    for ((k, v) in fields) {
        if (k == mainKey) {
            continue
        }
        if (!first) {
            sb.append(" ")
        }
        first = false
        sb.append(k)
        sb.append(": ")
        sb.append(shortArgValue(v))
    }
    return sb.toString()
}

/**
 * 单值紧凑显示：字符串取原始文本（无引号/转义），超长截断
 */
func shortArgValue(v: JsonValue): String {
    var raw = ""
    match (v.kind()) {
        case JsonKind.JsString => raw = v.asString().getValue()
        case _ => raw = v.toJsonString()
    }
    return if (raw.size > 120) { truncateUtf8(raw, 120) + "…" } else { raw }
}

main(args: Array<String>): Int64 {
    // 禁掉 stdx 库内部日志（如 stdx.net.http 的 read response timeout WARN）
    // 这些日志走 stdx.log 全局 logger 直接到 stderr，污染 TUI 输入框
    // 必须在任何 stdx 库调用之前设置，否则早期日志仍会漏出
    setGlobalLogger(NoopLogger())
    if (args.size > 0 && args[0] == "--mock") {
        return runMockVerify()
    }
    if (args.size > 0 && args[0] == "--mode" && args.size > 1 && args[1] == "json") {
        // --mode json [--resume <id>] <prompt...>：无头模式，输出 JSON 结果（脚本可解析）
        var sessionId = ""
        var prompt = ""
        var i: Int64 = 2
        while (i < args.size) {
            if (args[i] == "--resume" && i + 1 < args.size) {
                sessionId = args[i + 1]
                i += 2
            } else {
                prompt = args[i]
                i += 1
            }
        }
        return runJson(prompt, sessionId)
    }
    if (args.size > 0 && args[0] == "--cli") {
        if (args.size > 2 && args[1] == "--resume") {
            return runCli(args[2])
        }
        return runCli("")
    }
    if (args.size > 1 && args[0] == "--resume") {
        return runTui(args[1])
    }
    if (args.size > 0 && args[0] == "--list") {
        return listSessions()
    }
    // cjh web [--port <n>] [--bind <addr>] [--token <t>]
    if (args.size > 0 && (args[0] == "web" || args[0] == "--web")) {
        return runWeb(args)
    }
    return runTui("")
}

/**
 * cjh web 子命令入口
 *
 * 解析命令行参数，构造 AgentConfig，启动 WebServer。
 *
 * 参数：
 *   --port <n>      监听端口（默认 8765）
 *   --bind <addr>   绑定地址（默认 127.0.0.1）
 *   --token <t>     鉴权 token（默认空=不鉴权）
 */
func runWeb(args: Array<String>): Int64 {
    let cjhCfg = CjhConfig()
    cjhCfg.loadSettings()

    // 命令行参数覆盖 settings.json
    var i: Int64 = 1
    while (i < args.size) {
        if (args[i] == "--port" && i + 1 < args.size) {
            try {
                let portVal = Int64.parse(args[i + 1])
                if (portVal >= 0 && portVal <= 65535) {
                    cjhCfg.webPort = UInt16(portVal)
                }
            } catch (e: Exception) {
                // 忽略非法端口参数
            }
            i += 2
        } else if (args[i] == "--bind" && i + 1 < args.size) {
            cjhCfg.webBindAddr = args[i + 1]
            i += 2
        } else if (args[i] == "--token" && i + 1 < args.size) {
            cjhCfg.webAuthToken = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    // 强制启用 Web 模式
    cjhCfg.webEnabled = true

    // 安全检查：远程绑定但无鉴权 token
    if (cjhCfg.webBindAddr != "127.0.0.1" && cjhCfg.webBindAddr != "localhost" && cjhCfg.webAuthToken.size == 0) {
        println("⚠️  安全警告：绑定地址 ${cjhCfg.webBindAddr} 非 127.0.0.1，但未设置鉴权 token")
        println("   任何人都能访问你的 cjh 实例并执行工具调用")
        println("   建议：cjh web --bind ${cjhCfg.webBindAddr} --token <your-secret>")
        println()
    }

    // 构造 provider + registry（复用 runCli 的构造方式）
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())
    registerWebTools(cjhCfg, registry)
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)

    let provider = makeProvider(cjhCfg)

    // 启动 Web 服务器
    let server = WebServer(cjhCfg, provider, registry)
    return server.serve()
}

class CliSession {
    static var id: String = ""
}

func runCli(sessionId: String): Int64 {
    println("cjh - Cangjie Coding Agent")
    println("========================")

    // 注册工具
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    // 注册技能携带的声明式工具（Skill 自定义工具）
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }

    // system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactKeep,
        cjhCfg.toolResultMaxChars,
        cjhCfg.spillDir,
        effectiveSessionId)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = makeProvider(cjhCfg)
        }
        let agent = Agent(provider, registry, config)
        agent.setPluginManager(pluginManager)
        let store = SessionStore(cjhCfg.sessionsDir)
        CliSession.id = ""
        if (sessionId.size > 0) {
            let history = store.load(sessionId)
            if (history.size > 0) {
                agent.loadHistory(history)
                CliSession.id = sessionId
                println("[resumed session ${sessionId} (${history.size} messages)]")
            } else {
                println("[session ${sessionId} not found, starting new]")
            }
        }

        // 事件 → 终端输出
        agent.onDelta = { d => () }  // 流式增量：TUI 显示，CLI 由 onAssistantText 汇总
        agent.onToolStart = { name, args =>
            println("")
            println("▶ 调用工具: ${name} ${args.toJsonString()}")
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            if (preview.size > 800) {
                preview = truncateUtf8(preview, 800) + "\n…（截断）"
            }
            println("  ↳ ${name} → ${preview}")
            println("")
        }
        // 审批链：CLI 模式读 stdin 一行 y/n（空/其它=拒绝；EOF 也拒绝，谨慎默认）
        agent.onApproval = { name, args, reason =>
            println("")
            println("⚠ 需人工确认: ${name} ${args.toJsonString()}")
            println("  ${reason}")
            print("  同意执行? [y/N] ", flush: true)
            let line = readLineFromStdIn()
            if (line.isNone()) {
                return false
            }
            let answer = line.getOrThrow().trimAscii()
            return (answer == "y" || answer == "Y" || answer == "yes")
        }
        agent.onAssistantText = { text =>
            println("── 最终答复 ──")
            println(text)
        }

        // 交互循环
        while (true) {
            print("\n❯ ", flush: true)
            let line = readLineFromStdIn()
            if (line.isNone()) {
                break
            }
            let input = line.getOrThrow()
            if (input == "exit" || input == "quit" || input == ":q") {
                break
            }
            if (input.size == 0) {
                continue
            }
            try {
                let _ = agent.run(input)
                // 保存会话
                if (CliSession.id.size == 0) {
                    CliSession.id = store.save(agent.history())
                    eprintln("[session saved: ${CliSession.id}, use --resume ${CliSession.id}]")
                } else {
                    let _ = store.save(agent.history())
                }
            } catch (e: Exception) {
                println("错误: ${e}")
            }
        }
        println("再见")
        return 0
    } catch (e: Exception) {
        eprintln("启动失败: ${e}")
        return 1
    }
}

/**
 * --mode json 无头模式（对齐 pi 的 print-JSON 模式，供脚本/集成调用）：
 * 单次运行：加载配置 → 恢复可选会话 → agent.run(prompt) → 输出 JSON
 * {"reply", "session_id", "tool_calls": [{name, args, result}], "error"}
 * 会话自动保存（新会话或原会话 id 覆盖），便于链式调用。
 */
class JsonState {
    // 静态字段：lambda 闭包不能捕获可变局部变量，用静态容器收集工具调用记录
    static var toolCalls: ArrayList<(String, String, String)> = ArrayList<(String, String, String)>()
}

func runJson(prompt: String, sessionId: String): Int64 {
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())

    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }

    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactKeep,
        cjhCfg.toolResultMaxChars,
        cjhCfg.spillDir,
        effectiveSessionId)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = makeProvider(cjhCfg)
        }
        let agent = Agent(provider, registry, config)
        agent.setPluginManager(pluginManager)
        let store = SessionStore(cjhCfg.sessionsDir)

        // TodoWriteTool：LLM 通过工具调用管理任务列表（回调绑定到 agent）
        registry.register(TodoWriteTool(
            { c => agent.addTask(c) },
            { id => agent.updateTaskStatus(id, TodoStatus.InProgress) },
            { id => agent.updateTaskStatus(id, TodoStatus.Completed) },
            { id, c => agent.updateTaskContent(id, c) },
            { => agent.clearTodos() },
            { =>
                let todos = agent.getTodos()
                if (todos.size == 0) { return "暂无任务" }
                var result = "Tasks:\n"
                for (item in todos) {
                    let marker = match (item.status) {
                        case TodoStatus.Completed => "✓"
                        case TodoStatus.InProgress => "▶"
                        case TodoStatus.Pending => "☐"
                    }
                    result += "  ${marker} #${item.id} ${item.content}\n"
                }
                return result
            }
        ))

        // 恢复会话（--resume <id>）
        var curId = sessionId
        if (curId.size > 0) {
            let history = store.load(curId)
            if (history.size > 0) {
                agent.loadHistory(history)
            } else {
                curId = ""
            }
        }

        // 收集工具调用记录（供 JSON 输出）
        JsonState.toolCalls = ArrayList<(String, String, String)>()
        agent.onDelta = { d => () }
        agent.onToolStart = { name, args =>
            JsonState.toolCalls.add((name, args.toJsonString(), ""))
        }
        agent.onToolResult = { name, result =>
            for (i in 0..JsonState.toolCalls.size) {
                if (JsonState.toolCalls[i][0] == name && JsonState.toolCalls[i][2].size == 0) {
                    JsonState.toolCalls[i] = (JsonState.toolCalls[i][0], JsonState.toolCalls[i][1], result.content)
                    break
                }
            }
        }
        agent.onApproval = { name, args, reason => false }  // 无头模式默认拒绝危险操作
        agent.onAssistantText = { text => () }

        if (prompt.size == 0) {
            // 无 prompt：输出会话摘要 JSON（--mode json --resume <id> 查历史）
            var out = JsonObject()
            out.put("reply", JsonString(""))
            out.put("session_id", JsonString(curId))
            out.put("error", JsonString("empty prompt"))
            println(out.toJsonString())
            return 1
        }

        let summary = agent.run(prompt)

        // 保存会话：新会话用 store.save；恢复的会话更新原文件（删旧建新以更新消息）
        if (curId.size == 0) {
            curId = store.save(agent.history())
        } else {
            let _ = store.save(agent.history())
        }

        // 输出 JSON 结果
        var out = JsonObject()
        out.put("reply", JsonString(summary.reply))
        out.put("session_id", JsonString(curId))
        var tcArr = ArrayList<JsonValue>()
        for (tc in JsonState.toolCalls) {
            var t = JsonObject()
            t.put("name", JsonString(tc[0]))
            t.put("args", JsonString(tc[1]))
            t.put("result", JsonString(tc[2]))
            tcArr.add(t)
        }
        out.put("tool_calls", JsonArray(tcArr))
        println(out.toJsonString())
        return 0
    } catch (e: Exception) {
        var err = JsonObject()
        err.put("reply", JsonString(""))
        err.put("session_id", JsonString(sessionId))
        err.put("error", JsonString(e.toString()))
        println(err.toJsonString())
        return 1
    }
}

/**
 * TUI 交互模式（默认）
 */
func runTui(sessionId: String): Int64 {
    // 临时启动计时（CJH_STARTUP_PROF=1 开启）
    let profiling = (readEnv("CJH_STARTUP_PROF") ?? "") == "1"
    let t0 = MonoTime.now()
    func mark(label: String): Unit {
        if (!profiling) { return }
        let elapsed = MonoTime.now() - t0
        try {
            let f = File("/tmp/cjh_startup.log", OpenMode.Append)
            f.write(stringToBytes("${elapsed}\t${label}\n"))
            f.close()
        } catch (e: Exception) {}
    }
    mark("runTui enter")
    // 在屏蔽 stderr 前先缓存终端尺寸（suppress 后 ioctl(STDERR) 失效）
    let (initRows, initCols) = TermSize.get()
    // TUI 全屏模式：立即屏蔽 stderr（配置生成等提示不污染屏幕）
    Stderr.suppress()
    mark("stderr suppressed")
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())
    mark("builtin tools registered")

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    mark("CjhConfig loaded")
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    mark("theme applied")
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    // 注册技能携带的声明式工具（Skill 自定义工具）
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    mark("skill tools loaded")
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    mark("plugins loaded")
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)
    mark("mcp servers loaded")

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }
    mark("session id generated")

    // system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactKeep,
        cjhCfg.toolResultMaxChars,
        cjhCfg.spillDir,
        effectiveSessionId)
    mark("AgentConfig built")

    var tuiOpt: Option<TuiApp> = None

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = makeProvider(cjhCfg)
        }
        mark("provider created (warmup spawned)")
        let agent = Agent(provider, registry, config)
        agent.setPluginManager(pluginManager)

        // TodoWriteTool：LLM 通过工具调用管理任务列表（回调绑定到 agent）
        registry.register(TodoWriteTool(
            { c => agent.addTask(c) },
            { id => agent.updateTaskStatus(id, TodoStatus.InProgress) },
            { id => agent.updateTaskStatus(id, TodoStatus.Completed) },
            { id, c => agent.updateTaskContent(id, c) },
            { => agent.clearTodos() },
            { =>
                let todos = agent.getTodos()
                if (todos.size == 0) { return "暂无任务" }
                var result = "Tasks:\n"
                for (item in todos) {
                    let marker = match (item.status) {
                        case TodoStatus.Completed => "✓"
                        case TodoStatus.InProgress => "▶"
                        case TodoStatus.Pending => "☐"
                    }
                    result += "  ${marker} #${item.id} ${item.content}\n"
                }
                return result
            }
        ))
        // 线程安全的输出队列（agent 在调用线程运行，输出经队列到 TUI）
        let tui = TuiApp()
        tuiOpt = Some(tui)
        tui.setModel(cjhCfg.model)

        // 会话：恢复历史 / 新会话
        let store = SessionStore(cjhCfg.sessionsDir)
        // 欢迎视图右栏：最近会话摘要（id 不显示，仅摘要）
        let sessionList = store.list()
        let sessionSummaries = ArrayList<String>()
        for (s in sessionList) {
            sessionSummaries.add(s[1])
        }
        tui.setSessions(sessionSummaries)
        var curSessionId = sessionId
        if (curSessionId.size > 0) {
            let history = store.load(curSessionId)
            if (history.size > 0) {
                agent.loadHistory(history)
                tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[resumed ${curSessionId} (${history.size} msgs)]" + Ansi.reset())
            } else {
                tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[session ${curSessionId} not found, new session]" + Ansi.reset())
                curSessionId = ""
            }
        }

        StreamState.active = false
        StreamState.md = MarkdownRender()
        TuiBridge.app = tui
        agent.onDelta = { d =>
            if (d.size > 0) {
                try {
                    if (!StreamState.active) {
                        TuiBridge.delta("")
                        StreamState.active = true
                    }
                    TuiBridge.delta(StreamState.md.process(d))
                } catch (e: Exception) {
                    // 流式增量含非法 UTF-8 字节：跳过本帧，不崩 TUI
                }
            }
            tui.setAgentState("Streaming…")
        }
        agent.onThinking = { =>
            tui.resetAgentTimer()
            tui.setAgentState("Thinking…")
        }
        agent.onTokens = { tokens =>
            tui.addAgentTokens(tokens)
        }
        agent.onToolStart = { name, args =>
            if (StreamState.active) {
                TuiBridge.delta("")
                StreamState.active = false
            }
            TuiBridge.ensureNewline()
            TuiBridge.output(Ansi.fg(Ansi.THEME_OK) + "▶ ${name} " + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + formatToolArgs(name, args) + Ansi.reset())
            tui.setAgentState("Running ${name}…")
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            if (preview.size > 200) {
                preview = truncateUtf8(preview, 200) + "…"
            }
            TuiBridge.ensureNewline()
            TuiBridge.output(Ansi.fg(Ansi.THEME_MUTED) + "  ↳ ${name}: ${preview}" + Ansi.reset())
        }
        // 审批链：危险操作需人工确认时，在 TUI 内嵌审批（y/n）
        agent.onApproval = { name, args, reason =>
            TuiBridge.ensureNewline()
            TuiBridge.output(Ansi.fg(Ansi.THEME_WARN) + "⚠ 需人工确认: ${name} " + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + formatToolArgs(name, args) + Ansi.reset())
            TuiBridge.requestApproval(reason)
        }
        agent.onAssistantText = { text =>
            // 回复内容左侧缩进 1 个空格：不贴左边缘，视觉更舒适
            let indentReply = { raw: String =>
                let lines = raw.split("\n", -1)
                var sb = StringBuilder()
                for (i in 0..lines.size) {
                    if (i > 0) {
                        sb.append("\n")
                    }
                    sb.append(" " + lines[i])
                }
                sb.toString()
            }
            if (StreamState.active) {
                // 流式结束：用最终完整文本（已整体修复 mojibake）整体渲染并重绘替换流式段
                let md = MarkdownRender()
                TuiBridge.endStream(indentReply(md.process(text) + md.finish()))
                StreamState.active = false
            } else {
                // 非流式（旧协议全量返回）：整体渲染 markdown
                let md = MarkdownRender()
                TuiBridge.output(indentReply(md.process(text) + md.finish()))
            }
            // 回复结束后加空行：与下一轮用户输入分隔
            TuiBridge.output("")
        }
        // Tasks 面板：Agent 任务变更时刷新快照
        agent.onTodosChanged = { =>
            tui.updateTasks(agent.getTodos())
        }
        // 回合总结条：Agent.run 结束后渲染统计
        agent.onRunComplete = { s =>
            let secs = Float64(s.durationMs) / 1000.0
            let tokensK = Float64(s.totalTokens()) / 1000.0
            let rate = s.cacheHitRate()
            // 格式：─── ✓ 2 rounds · 3 tools · 42.6s · 1.53K tokens · 99% cached ───
            let stat = "✓ ${s.rounds} rounds · ${s.toolCalls} tools · ${secs}s · ${tokensK}K tokens · ${rate}% cached"
            let (rows, cols) = TermSize.get()
            let lineW = TuiCanvas.displayWidth(stat) + 8  // ─── 两侧 ───
            var leftDash: Int64 = 3
            var rightDash: Int64 = cols - lineW - 1
            if (rightDash < 3) {
                rightDash = 3
            }
            var bar = StringBuilder()
            var i: Int64 = 0
            while (i < leftDash) {
                bar.append("─")
                i += 1
            }
            bar.append(Ansi.fg(Ansi.THEME_MUTED) + " " + Ansi.fg(Ansi.THEME_OK) + stat +
                Ansi.fg(Ansi.THEME_MUTED) + " " + Ansi.reset())
            i = 0
            while (i < rightDash) {
                bar.append("─")
                i += 1
            }
            TuiBridge.output("")  // 上空行
            TuiBridge.output(Ansi.fg(Ansi.THEME_MUTED) + bar.toString() + Ansi.reset())
            TuiBridge.output("")  // 下空行
        }

        SessionState.current = curSessionId
        // provider 配置表单提交回调：写回 settings/auth，重建 provider 热切换
        tui.onProviderSubmit = { provider, baseUrl, model, apiKey =>
            // provider 字段用于预设匹配（空则按 base_url/model 直接写）
            var label = provider
            if (label.size == 0) {
                label = model
            }
            try {
                cjhCfg.saveProvider(baseUrl, model)
                if (apiKey.size > 0) {
                    cjhCfg.saveApiKey(apiKey)
                }
                let np = makeProvider(cjhCfg)
                agent.setProvider(np)
                tui.setModel(model)
                tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已切换 provider: ${label}（model=${model}）]" + Ansi.reset())
            } catch (e: Exception) {
                tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[provider 切换失败: ${e}]" + Ansi.reset())
            }
        }
        // 主题确认回调：写回 settings.json 持久化
        tui.onThemeApply = { name =>
            cjhCfg.theme = name
            cjhCfg.saveTheme(name)
        }
        tui.onSubmit = { input =>
            // slash 命令（对齐 pi：/help /new /resume /quit /model /settings）
            if (input.startsWith("/")) {
                handleSlashCommand(input, agent, store, tui, cjhCfg)
                return
            }
            // 异步执行 agent（TUI 主循环持续渲染，避免阻塞）
            // 方案 B：setAgentRunning 锁定输入框提交，执行完自动处理队列下一条
            spawn {
                tui.setAgentRunning(true)
                var summary: RunSummary = RunSummary()
                try {
                    summary = agent.run(input)
                    if (StreamState.active) {
                        tui.appendOutput(Ansi.reset())
                        StreamState.active = false
                    }
                    // 保存会话（含首轮时创建 ID）
                    if (SessionState.current.size == 0) {
                        SessionState.current = store.save(agent.history())
                        TuiBridge.status("[saved ${SessionState.current}, --resume ${SessionState.current}]")
                    } else {
                        let _ = store.save(agent.history())
                    }
                } catch (e: Exception) {
                    TuiBridge.output(Ansi.fg(Ansi.THEME_ERR) + "错误: ${e}" + Ansi.reset())
                }
                // 先关闭 agent 运行态（动态状态栏消失，输出区恢复占满），
                // 再触发 onRunComplete 渲染回合总结条，避免总结条被收缩的输出区挤压
                tui.setAgentRunning(false)
                if (summary.rounds > 0) {
                    agent.onRunComplete(summary)
                }
                // 自动处理队列下一条（如果有）
                if (let Some(next) <- tui.dequeueInput()) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "❯ " + Ansi.reset() + next)
                    tui.appendOutput("")  // 空行：分隔用户输入与 Agent 回复
                    tui.onSubmit(next)
                }
            }
        }

        mark("TUI ready, entering event loop")
        tui.run()
        mark("TUI exited")
        Stderr.restore()
        return 0
    } catch (e: Exception) {
        Stderr.restore()
        Log.fatal("runTui 启动失败", e)
        eprintln("启动失败: ${e}")
        return 1
    } finally {
        // 兜底：任何退出路径（含异常崩溃）都恢复终端 raw 模式
        // 否则 ECHO 被清，回到 shell 后输入不显示
        match (tuiOpt) {
            case Some(t) => t.restoreTerminal()
            case None => ()
        }
    }
}

class SessionState {
    static var current: String = ""
}

/**
 * 会话在树中的深度（沿 parent 链向上计数；根=0，防环上限 32）
 */
func depthOf(id: String, store: SessionStore): Int64 {
    var depth: Int64 = 0
    var cur = id
    var guard: Int64 = 0
    while (guard < 32) {
        let p = store.parentOf(cur)
        if (p.size == 0) {
            break
        }
        depth += 1
        cur = p
        guard += 1
    }
    return depth
}

/**
 * 应用 provider 预设：写回 settings（base_url/model）+ 可选 auth（api_key），
 * 重建 provider 热切换。返回是否成功（失败时 TUI 已输出原因）。
 */
func applyProvider(cfg: CjhConfig, agent: Agent, tui: TuiApp, label: String, baseUrl: String, model: String, apiKey: String): Bool {
    try {
        cfg.saveProvider(baseUrl, model)
        if (apiKey.size > 0) {
            cfg.saveApiKey(apiKey)
        }
        let np = makeProvider(cfg)
        agent.setProvider(np)
        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已切换 provider: ${label}（model=${cfg.model}）]" + Ansi.reset())
        return true
    } catch (e: Exception) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[provider 切换失败: ${e}]" + Ansi.reset())
        return false
    }
}

/**
 * TUI slash 命令分发（对齐 pi 基础命令：/help /new /resume /quit /model /settings）
 */
func handleSlashCommand(input: String, agent: Agent, store: SessionStore, tui: TuiApp, cfg: CjhConfig): Unit {
    let cmd = input.trimAscii().split(" ", -1)[0]
    let args = input.trimAscii()
    match (cmd) {
        case "/help" =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用命令：" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /help          显示本帮助" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /new           开始新会话" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /resume [id]   恢复历史会话（无 id 时列出）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /model [id|#]  列出/切换模型" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /provider [name] [key]  切换 provider（deepseek/openai/glm）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /skills        列出技能与启用状态" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /compact       手动压缩历史（LLM 摘要早期消息）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /tree          树形列示会话分支" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /fork          从当前会话分支新会话" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /settings      查看采样参数（temp/max_tokens）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /task          任务管理（add/done/doing/clear/list）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /theme [name] TUI 主题切换（starfrost|classic）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /quit          退出" + Ansi.reset())
        case "/provider" =>
            // provider 预设切换：/provider [name] [api_key]
            // name ∈ deepseek|openai|glm（预设 base_url+model，写回 settings.json）
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                let name = parts[1]
                var key = if (parts.size > 2) { parts[2] } else { "" }
                match (name) {
                    case "deepseek" =>
                        applyProvider(cfg, agent, tui, "DeepSeek", "https://api.deepseek.com/v1/chat/completions", "deepseek-chat", key)
                    case "openai" =>
                        applyProvider(cfg, agent, tui, "OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini", key)
                    case "glm" =>
                        applyProvider(cfg, agent, tui, "GLM", "https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash", key)
                    case "ollama" =>
                        // 本地 Ollama：无需 API Key，默认 llama3.2 模型
                        // 用法：/provider ollama [model] [api_key]
                        var ollamaModel = "llama3.2"
                        // key 当前 = parts[2]；若 parts[2] 像 model 名则视为 model，
                        // parts[3] 才是 apiKey。简化：parts[2] 存在 → model；parts[3] 存在 → apiKey
                        if (parts.size > 2 && parts[2].size > 0) {
                            ollamaModel = parts[2]
                            key = if (parts.size > 3) { parts[3] } else { "" }
                        } else {
                            key = ""
                        }
                        applyProvider(cfg, agent, tui, "Ollama", "http://localhost:11434/v1", ollamaModel, key)
                    case _ =>
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知 provider: ${name}；/provider 查看预设列表]" + Ansi.reset())
                }
            } else {
                // 无参数：弹出 provider 配置表单（参考 omp sign-in 弹窗）
                tui.showProviderDialog(cfg.baseUrl, cfg.model, cfg.apiKey)
            }
        case "/model" =>
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                // /model <id|#n>：切换模型
                var target = parts[1]
                var idx: Int64 = -1
                // 支持 "#序号" 形式
                if (target.startsWith("#") && target.size > 1) {
                    try {
                        idx = Int64.parse(target[1..target.size])
                    } catch (e: Exception) {
                        idx = -1
                    }
                } else if (cfg.models.size > 0) {
                    // 按 id 匹配
                    for (i in 0..cfg.models.size) {
                        if (cfg.models[i].id == target) {
                            idx = i
                            break
                        }
                    }
                }
                if (idx >= 0 && idx < cfg.models.size) {
                    let entry = cfg.models[idx]
                    cfg.model = entry.id
                    if (entry.baseUrl.size > 0) {
                        cfg.baseUrl = entry.baseUrl
                    }
                    if (entry.apiKey.size > 0) {
                        cfg.apiKey = entry.apiKey
                    }
                    cfg.temperature = entry.temperature
                    cfg.maxTokens = entry.maxTokens
                    let mname = if (entry.name.size > 0) { entry.name } else { entry.id }
                    tui.setModel(mname)
                    // 重建 provider 并热切换（历史保留）
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已切换模型: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[切换模型失败: ${e}]" + Ansi.reset())
                    }
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知模型: ${target}；/model 查看列表]" + Ansi.reset())
                }
            } else {
                // 列出模型
                if (cfg.models.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[未配置 models 列表；当前: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用模型（/model <id|#序号> 切换）：" + Ansi.reset())
                    for (i in 0..cfg.models.size) {
                        let m = cfg.models[i]
                        let label = if (m.name.size > 0) { m.name } else { m.id }
                        let cur = if (m.id == cfg.model) { " ◀" } else { "" }
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  #${i} ${label} (${m.id})${cur}" + Ansi.reset())
                    }
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "当前: ${cfg.model} (temp=${cfg.temperature}, max_tokens=${cfg.maxTokens})" + Ansi.reset())
                }
            }
        case "/settings" =>
            // 查看/调整采样参数：/settings 或 /settings temp 0.9 /settings max_tokens 8192
            let parts = args.split(" ", -1)
            if (parts.size == 3 && parts[1] == "temp") {
                try {
                    cfg.temperature = Float64.parse(parts[2])
                    // 重建 provider 应用新参数
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[temperature = ${cfg.temperature}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else if (parts.size == 3 && parts[1] == "max_tokens") {
                try {
                    cfg.maxTokens = Int64.parse(parts[2])
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[max_tokens = ${cfg.maxTokens}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else {
                tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "采样参数（/settings temp 0.9 或 /settings max_tokens 8192 调整）：" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  model       ${cfg.model}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  temperature ${cfg.temperature}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  max_tokens  ${cfg.maxTokens}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  base_url    ${cfg.baseUrl}" + Ansi.reset())
            }
        case "/new" =>
            // 清空会话：重开 agent 历史（保留 system）
            let history = agent.history()
            while (history.size > 1) {
                history.remove(history.size - 1..history.size)
            }
            // 清理当前会话的落盘文件（工具结果截断 spill）
            if (SessionState.current.size > 0) {
                let spillSessionDir = cfg.spillDir + "/" + SessionState.current
                try {
                    removeIfExists(spillSessionDir)
                } catch (e: Exception) {
                    // 清理失败不阻塞新会话
                }
            }
            SessionState.current = ""
            tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[新会话]" + Ansi.reset())
        case "/skills" =>
            // 列示技能（~/.cjh/skills/<name>.md）与启用状态
            listSkills(cfg.skillsDir, cfg.enabledSkills, tui)
        case "/compact" =>
            // 手动触发 Compaction：强制把早期历史压成 LLM 摘要
            // 无视 compactThreshold 阈值；compact_keep 仍生效
            tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "[压缩历史中…]" + Ansi.reset())
            spawn {
                let (done, before, after) = agent.compact(true)
                if (done) {
                    TuiBridge.output(Ansi.fg(Ansi.THEME_OK) +
                        "[历史已压缩：${before} → ${after} 条消息]" + Ansi.reset())
                } else {
                    TuiBridge.output(Ansi.fg(Ansi.THEME_MUTED) +
                        "[历史较短，无需压缩（${before} 条）]" + Ansi.reset())
                }
            }
        case "/task" =>
            // /task add <content> | /task done <id> | /task doing <id> | /task rm <id> | /task clear | /task list
            let parts = args.split(" ", -1)
            if (parts.size < 2) {
                // 无参数：列出当前任务
                let todos = agent.getTodos()
                if (todos.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无任务]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "Tasks:" + Ansi.reset())
                    for (item in todos) {
                        let marker = match (item.status) {
                            case TodoStatus.Completed => "✓"
                            case TodoStatus.InProgress => "▶"
                            case TodoStatus.Pending => "☐"
                        }
                        let color = match (item.status) {
                            case TodoStatus.Completed => Ansi.fg(Ansi.THEME_OK)
                            case TodoStatus.InProgress => Ansi.fg(Ansi.THEME_WARN)
                            case TodoStatus.Pending => Ansi.fg(Ansi.THEME_MUTED)
                        }
                        tui.appendOutput(color + "  ${marker} #${item.id} ${item.content}" + Ansi.reset())
                    }
                }
            } else {
                let sub = parts[1]
                match (sub) {
                    case "add" =>
                        // /task add <content...>
                        if (parts.size > 2) {
                            var content = ""
                            for (i in 2..parts.size) {
                                if (content.size > 0) { content += " " }
                                content += parts[i]
                            }
                            let id = agent.addTask(content)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已添加任务 #${id}: ${content}]" + Ansi.reset())
                        } else {
                            tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "用法: /task add <内容>" + Ansi.reset())
                        }
                    case "done" =>
                        // /task done <id>
                        if (parts.size > 2) {
                            let id = Int64.parse(parts[2])
                            agent.updateTaskStatus(id, TodoStatus.Completed)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[任务 #${id} → completed]" + Ansi.reset())
                        }
                    case "doing" =>
                        // /task doing <id>
                        if (parts.size > 2) {
                            let id = Int64.parse(parts[2])
                            agent.updateTaskStatus(id, TodoStatus.InProgress)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[任务 #${id} → in_progress]" + Ansi.reset())
                        }
                    case "clear" =>
                        agent.clearTodos()
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[已清空任务列表]" + Ansi.reset())
                    case "list" =>
                        let todos = agent.getTodos()
                        if (todos.size == 0) {
                            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无任务]" + Ansi.reset())
                        } else {
                            for (item in todos) {
                                let marker = match (item.status) {
                                    case TodoStatus.Completed => "✓"
                                    case TodoStatus.InProgress => "▶"
                                    case TodoStatus.Pending => "☐"
                                }
                                tui.appendOutput("  ${marker} #${item.id} ${item.content}")
                            }
                        }
                    case _ =>
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知子命令: ${sub}；支持 add/done/doing/clear/list]" + Ansi.reset())
                }
            }
        case "/resume" =>
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                // /resume <id>：恢复指定会话
                let id = parts[1]
                let history = store.load(id)
                if (history.size > 0) {
                    // 清空当前历史后载入（保留 system）
                    let cur = agent.history()
                    while (cur.size > 1) {
                        cur.remove(cur.size - 1..cur.size)
                    }
                    agent.loadHistory(history)
                    SessionState.current = id
                    tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[resumed ${id} (${history.size} msgs)]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[会话 ${id} 不存在]" + Ansi.reset())
                }
            } else {
                // 列出会话
                let sessions = store.list()
                if (sessions.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无会话]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "已保存的会话（/resume <id> 恢复）：" + Ansi.reset())
                    for ((id, summary) in sessions) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  ${id}  |  ${summary}" + Ansi.reset())
                    }
                }
            }
        case "/tree" =>
            // 树形会话列示：按 parent 链展示分支（pi /tree 能力）
            let nodes = store.listTree()
            if (nodes.size == 0) {
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无会话]" + Ansi.reset())
            } else {
                tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "会话树（/resume <id> 恢复，/fork 从当前分支）：" + Ansi.reset())
                // 标记有子会话的节点（作为分支点）
                var childCount = HashMap<String, Int64>()
                for ((id, _, parent) in nodes) {
                    if (parent.size > 0) {
                        childCount.add(parent, (childCount.get(parent) ?? 0) + 1)
                    }
                }
                for ((id, summary, parent) in nodes) {
                    let depth = depthOf(id, store)
                    var indent = ""
                    for (_ in 0..depth) {
                        indent += "  "
                    }
                    let isFork = if (parent.size > 0) { " ↳" } else { "" }
                    let hasChild = if ((childCount.get(id) ?? 0) > 0) { " ◆" } else { "" }
                    var line = "  ${indent}${isFork} ${id}${hasChild}"
                    if (summary.size > 0) {
                        line += "  |  ${summary}"
                    }
                    if (SessionState.current == id) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + line + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + " ◀" + Ansi.reset())
                    } else {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + line + Ansi.reset())
                    }
                }
            }
        case "/fork" =>
            // 分支：把当前历史保存为新会话，parent = 当前会话（或根）
            let curId = SessionState.current
            let history = agent.history()
            let newId = store.saveFork(history, curId)
            SessionState.current = newId
            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已分支为 ${newId}（parent=${curId}）]" + Ansi.reset())
        case "/quit" =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[再见]" + Ansi.reset())
            // 退出由主循环处理；先短暂刷新再退出
            spawn { tui.quit() }
        case "/theme" =>
            // /theme [name]：切换 TUI 主题（starfrost|classic）；无参数弹出交互式 picker
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                let applied = Theme.apply(parts[1])
                // 写回 settings.json 持久化
                cfg.theme = applied
                cfg.saveTheme(applied)
                tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[主题已切换: ${applied}]" + Ansi.reset())
                tui.markDirty()
            } else {
                // 无参数：弹出交互式主题选择 picker（上下键选择，Enter 确认）
                tui.showThemePicker(Theme.list(), Theme.current())
            }
        case _ =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "未知命令: ${cmd}（输入 /help 查看）" + Ansi.reset())
    }
}

class StreamState {
    static var active: Bool = false
    static var md: MarkdownRender = MarkdownRender()
}

/**
 * TUI 跨线程桥：agent 在 spawn 线程运行，经静态引用访问 TUI（避免闭包捕获跨线程问题）
 */
class TuiBridge {
    static var app: Option<TuiApp> = None

    public static func output(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.appendOutput(text)
        }
    }

    /**
     * 确保输出以换行结尾（工具调用提示前调用，避免拼到流式文字后面）
     */
    public static func ensureNewline(): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.ensureNewline()
        }
    }

    public static func delta(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.appendDelta(text)
        }
    }

    /**
     * 流式结束：用最终完整文本替换流式段（整体修复 mojibake 后重绘）
     */
    public static func endStream(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.endStream(text)
        }
    }

    public static func status(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.setStatus(text)
        }
    }

    /**
     * 请求人工审批（agent 线程调用；阻塞直到用户在 TUI 按 y/n）
     */
    public static func requestApproval(prompt: String): Bool {
        if (let Some(a) <- TuiBridge.app) {
            return a.requestApproval(prompt)
        }
        return false
    }
}

/**
 * 列出已保存的会话
 */
func listSessions(): Int64 {
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    let store = SessionStore(cjhCfg.sessionsDir)
    let sessions = store.list()
    if (sessions.size == 0) {
        println("暂无会话。运行 cjh 开始新会话，退出后自动保存。")
        return 0
    }
    println("已保存的会话（${sessions.size} 个）：")
    println("--------------------------------")
    for ((id, summary) in sessions) {
        println("  ${id}  |  ${summary}")
    }
    println("--------------------------------")
    println("恢复: cjh --resume <会话ID>")
    return 0
}
