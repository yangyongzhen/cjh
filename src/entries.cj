package cjh

/**
 * 入口编排：各运行模式（Web/CLI/JSON/TUI）的装配与主循环
 *
 * 从 main.cj 抽出。main.cj 只保留 main() 入口分发与共享状态类。
 * 每个入口函数职责单一：构造 ToolRegistry → 加载配置 → 建 Provider/Agent
 * → 绑定事件回调 → 进入模式主循环。
 */

import std.collection.*
import cjlog.*
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
import cjh.gateway.*
import cjterm.*
import cjcfg.*
import cjutil.*

/**
 * ProviderFactory 实现（装配层）
 *
 * 为什么由根包实现而不是网关自己建 provider：provider 选择（OpenAI/Anthropic/Ollama/Mock）、
 * 协议判定、环境变量与配置解析都是**装配知识**，属于根包；网关只经 ProviderFactory 接口
 * 回调使用，依赖保持单向（cjh.web / cjh.gateway ← 根包装配），网关不必反向依赖根包。
 */
public class ModelProviderFactory <: ProviderFactory {
    private let cfg: CjhConfig

    public init(cfg: CjhConfig) {
        this.cfg = cfg
    }

    /**
     * 解析模型目标：显式 baseUrl/apiKey 优先，缺省按 model 从配置模型列表补齐
     * （对齐配置页「模型与端点成对设置」的语义），再缺省回落全局配置。
     */
    public func resolve(model: String, baseUrl: String, apiKey: String): ModelTarget {
        let target = ModelTarget()
        target.model = if (model.size > 0) { model } else { this.cfg.model }
        var entryBase = ""
        var entryKey = ""
        for (i in 0..this.cfg.models.size) {
            let entry = this.cfg.models[i]
            if (entry.id == target.model) {
                entryBase = entry.baseUrl
                entryKey = entry.apiKey
                break
            }
        }
        target.baseUrl = if (baseUrl.size > 0) {
            baseUrl
        } else if (entryBase.size > 0) {
            entryBase
        } else {
            this.cfg.baseUrl
        }
        target.apiKey = if (apiKey.size > 0) {
            apiKey
        } else if (entryKey.size > 0) {
            entryKey
        } else {
            this.cfg.apiKey
        }
        if (target.model.size == 0) {
            target.error = "未指定模型，且当前配置没有默认模型"
        } else if (target.baseUrl.size == 0) {
            target.error = "模型 ${target.model} 没有可用端点：请求未带 base_url，配置里也没有该模型或全局 base_url"
        }
        return target
    }

    /**
     * 按解析结果构造 provider（选择逻辑与 makeProvider 一致，只是按 target 参数化）
     */
    public func create(target: ModelTarget): LlmProvider {
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            return MockProvider("/tmp/cjh_verify.txt")
        }
        let providerName = readEnv("CJH_PROVIDER") ?? ""
        let protocol = if (providerName.size > 0) { providerName } else { this.cfg.providerProtocol }
        let isOllama = (providerName == "ollama") || target.baseUrl.contains("localhost") ||
            target.baseUrl.contains("127.0.0.1")
        var p: LlmProvider
        if (isOllama) {
            p = OllamaProvider(target.baseUrl, target.apiKey, target.model)
        } else if (protocol == "anthropic") {
            p = AnthropicProvider(target.baseUrl, target.apiKey, target.model)
        } else {
            let oa = OpenAiProvider(target.baseUrl, target.apiKey, target.model)
            applyFallbackKeys(oa, this.cfg)
            p = oa
        }
        // 采样参数沿用配置（切模型不改采样：采样是配置页的事）
        match (p) {
            case oa: OpenAiProvider => oa.setSampling(this.cfg.temperature, this.cfg.maxTokens, this.cfg.reasoningEffort)
            case ap: AnthropicProvider => ap.setSampling(this.cfg.temperature, this.cfg.maxTokens, this.cfg.reasoningEffort)
            case op: OllamaProvider => op.setSampling(this.cfg.temperature, this.cfg.maxTokens, this.cfg.reasoningEffort)
            case _ => ()
        }
        return p
    }
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
    warnCapabilitySilent(cjhCfg)

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

    // 安全检查：远程绑定但无鉴权 token → 拒绝启动（不再只警告）
    let bindReject = webBindRejection(cjhCfg.webBindAddr, cjhCfg.webAuthToken)
    if (bindReject.size > 0) {
        println("✗ ${bindReject}")
        return 1
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())
    registerWebTools(cjhCfg, registry)
    registerKnowledgeTools(cjhCfg, registry)
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    let _ = loadPlugins(cjhCfg.pluginsDir, cjhCfg.configDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    let _ = loadMcpServers(cjhCfg.mcpServers, registry)

    let provider = makeProvider(cjhCfg)

    // 启动 Web 服务器（注入模型工厂：会话级切模型 / 单次模型覆盖可用）
    let server = WebServer(cjhCfg, provider, registry, Some(ModelProviderFactory(cjhCfg)))
    return server.serve()
}

/**
 * CLI 交互模式（cjh --cli）
 */
class CliSession {
    static var id: String = ""
}

/**
 * 从标准输入读取一行（CLI 模式审批/交互输入用）
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    // 注册仓颉知识层检索（语料未安装时自动不注册）
    registerKnowledgeTools(cjhCfg, registry)
    // 注册技能携带的声明式工具（Skill 自定义工具）
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, cjhCfg.configDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let _ = loadMcpServers(cjhCfg.mcpServers, registry)

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }

    // system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills, cjhCfg.memoryDir),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactTokenThreshold,
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
        match (makeSummaryProvider(cjhCfg)) {
            case Some(sp) => agent.setSummaryProvider(sp)
            case None => ()
        }
        // S4：子代理调度器（面板数据源 + 边界闸门：并发/每回合/token 预算/墙钟超时）
        let scheduler = SubagentScheduler(cjhCfg.maxSubagents, cjhCfg.maxTasksPerTurn,
            cjhCfg.subagentTokenBudget, cjhCfg.subagentTimeoutMs)
        agent.subagentScheduler = Some(scheduler)
        // S5：路由模式（settings subagent_mode；运行时 /parallel 切换）
        SubagentRouting.set(cjhCfg.subagentMode)
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
        agent.onDelta = { _ => () }  // 流式增量：TUI 显示，CLI 由 onAssistantText 汇总
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())

    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    warnCapabilitySilent(cjhCfg)
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    // 注册仓颉知识层检索（语料未安装时自动不注册）
    registerKnowledgeTools(cjhCfg, registry)
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, cjhCfg.configDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let _ = loadMcpServers(cjhCfg.mcpServers, registry)

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }

    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills, cjhCfg.memoryDir),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactTokenThreshold,
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
        match (makeSummaryProvider(cjhCfg)) {
            case Some(sp) => agent.setSummaryProvider(sp)
            case None => ()
        }
        // S4：子代理调度器（面板数据源 + 边界闸门：并发/每回合/token 预算/墙钟超时）
        let scheduler = SubagentScheduler(cjhCfg.maxSubagents, cjhCfg.maxTasksPerTurn,
            cjhCfg.subagentTokenBudget, cjhCfg.subagentTimeoutMs)
        agent.subagentScheduler = Some(scheduler)
        // S5：路由模式（settings subagent_mode；运行时 /parallel 切换）
        SubagentRouting.set(cjhCfg.subagentMode)
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

        // TaskTool：派发子代理执行独立任务（spawnFn 回调注入；父 agent 用于简报上下文块）
        // S2：子代理 provider 每次派生新建实例，避免共享单槽 transport 的 abort 串台（P0-2）
        registry.register(TaskTool({ description, prompt, subagentType, scope =>
            spawnSubagent(makeSubagentProvider(cjhCfg), registry, agent, config, description, prompt, subagentType, scope)
        }))

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
        agent.onDelta = { _ => () }
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
        agent.onApproval = { _, _, _ => false }  // 无头模式默认拒绝危险操作
        agent.onAssistantText = { _ => () }

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
    // 按键追踪诊断面包屑（CJH_TRACE_KEYS）：把实际落点写进 cjh.log，
    // 用户不必猜文件在哪（曾经"设了环境变量却找不到文件"）
    let traceNote = KeyTrace.describe()
    if (traceNote.size > 0) {
        Log.warn("按键追踪 ${traceNote}")
    }
    // 在屏蔽 stderr 前先缓存终端尺寸（suppress 后 ioctl(STDERR) 失效）
    let (_, _) = TermSize.get()
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())
    mark("builtin tools registered")

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    warnCapabilitySilent(cjhCfg)
    mark("CjhConfig loaded")
    // 应用 TUI 主题（settings.json "theme" 字段；默认 starfrost 星霜青）
    Theme.apply(cjhCfg.theme)
    mark("theme applied")
    // 注册 web_search + web_fetch 工具
    registerWebTools(cjhCfg, registry)
    // 注册仓颉知识层检索（语料未安装时自动不注册）
    registerKnowledgeTools(cjhCfg, registry)
    // 注册技能携带的声明式工具（Skill 自定义工具）
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    mark("skill tools loaded")
    // 加载插件（V2b Step 1：plugin.json + shell 工具）
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, cjhCfg.configDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    mark("plugins loaded")
    // 连接 MCP 服务器（V2b 扩展点：stdio 传输 + JSON-RPC）
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)
    mark("mcp servers loaded")

    // 预生成会话 ID（工具结果截断落盘需要会话 ID 隔离）
    let effectiveSessionId = if (sessionId.size > 0) { sessionId } else { SessionStore(cjhCfg.sessionsDir).newSessionId() }
    mark("session id generated")

    // system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
    let config = AgentConfig(
        buildSystemPrompt(cjhCfg.systemPrompt, cjhCfg.skillsDir, cjhCfg.enabledSkills, cjhCfg.memoryDir),
        cjhCfg.maxIterations,
        cjhCfg.capability,
        cjhCfg.compactThreshold,
        cjhCfg.compactTokenThreshold,
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
        match (makeSummaryProvider(cjhCfg)) {
            case Some(sp) => agent.setSummaryProvider(sp)
            case None => ()
        }
        // S4：子代理调度器（面板数据源 + 边界闸门：并发/每回合/token 预算/墙钟超时）
        let scheduler = SubagentScheduler(cjhCfg.maxSubagents, cjhCfg.maxTasksPerTurn,
            cjhCfg.subagentTokenBudget, cjhCfg.subagentTimeoutMs)
        agent.subagentScheduler = Some(scheduler)
        // S5：路由模式（settings subagent_mode；运行时 /parallel 切换）
        SubagentRouting.set(cjhCfg.subagentMode)
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
        // TaskTool：派发子代理执行独立任务（spawnFn 回调注入；父 agent 用于简报上下文块）
        // S2：子代理 provider 每次派生新建实例，避免共享单槽 transport 的 abort 串台（P0-2）
        registry.register(TaskTool({ description, prompt, subagentType, scope =>
            spawnSubagent(makeSubagentProvider(cjhCfg), registry, agent, config, description, prompt, subagentType, scope)
        }))

        // 线程安全的输出队列（agent 在调用线程运行，输出经队列到 TUI）
        let tui = TuiApp()
        tuiOpt = Some(tui)
        tui.setModel(cjhCfg.model)

        // S3d：Agents 面板数据源（scheduler 变更 → 深拷贝快照 → TUI）+ 焦点行事件转发
        scheduler.onChanged({ =>
            tui.refreshAgents(scheduler.snapshot())
        })
        agent.onSubagentEvent = { id, _, text =>
            tui.appendSubagentEvent(id, text)
        }
        // G-A：TUI 审批超时与服务端同源（subagent_timeout_ms；0=不限）——
        // 用户离开终端时审批到点按拒绝收场，父回合不永久卡死
        tui.approvalTimeoutMs = cjhCfg.subagentTimeoutMs

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
        TuiBridge.app = tui
        agent.onDelta = { d =>
            if (d.size > 0) {
                // 正式 content 开始：清空思考窗口，让它消失
                tui.clearReasoning()
                try {
                    if (!StreamState.active) {
                        TuiBridge.delta("")
                        StreamState.active = true
                    }
                    // 流式期间直出原始文本（不做增量 markdown 渲染）：
                    // **粗体**/代码块/表格跨帧分片时增量渲染的中间态是残缺 ANSI
                    // （闪烁 + 显示 `**` 原文），结束再由 onAssistantText 整体
                    // markdown 渲染替换（endStream），对齐 omp 的流式体验
                    TuiBridge.delta(d)
                } catch (e: Exception) {
                    // 流式增量含非法 UTF-8 字节：跳过本帧，不崩 TUI
                }
            }
            tui.setAgentState("Streaming…")
            tui.markAgentActivity()
        }
        agent.onReasoning = { r =>
            if (r.size > 0) {
                tui.appendReasoning(r)
                tui.markAgentActivity()
            }
        }
        agent.onThinking = { =>
            tui.resetAgentTimer()
            // 关键：重置空闲看门狗锚点。agentLastActivity 只被 onDelta/onReasoning
            // 更新、跨轮不重置——上一轮结束后锚点停在旧帧，新一轮"建连+前思考期"
            // （推理模型大 prompt 可 60-180s 无首帧）从陈旧锚点累计超 61s 即误杀
            // 正在思考的模型（实测 61s/127s/282s 反复打断）。onThinking 每轮
            // chatStream 前回调，此处重置让前思考期从本轮开始计。
            tui.markAgentActivity()
            // 重置 token 计数：setAgentTokenEstimate 只增不减，跨轮不清零会让
            // 上一轮估算残留（状态条 0.0K 或陈旧值），每轮从零重新估算
            tui.resetAgentTokens()
            tui.setAgentState("Thinking…")
        }
        // 排队输入拉取（atomcode 式 steer）：Agent 每轮 LLM 请求前调用，
        // 从 TUI 输入队列 FIFO 取一条；无则 None（回合边界不打断当前任务）。
        // 在 agent spawn 线程执行，TuiApp 队列自带锁，无死锁风险。
        agent.onRequestPendingInput = { => tui.dequeueInput() }
        agent.onTokens = { tokens =>
            tui.addAgentTokens(tokens)
        }
        // 流式逐帧 token 估算：思考过程中实时更新动态状态栏 token 数。
        // 注意：不标记"活动"——代理 keep-alive 帧（无 content/reasoning）
        // 也会触发估算回调（feed 每帧 estimateAndNotify），若算活动会维持
        // agentLastActivity 导致看门狗永不触发 → Streaming 无限持续
        // （用户实测 6341s 卡死 + 排队积压）。真实活动仅看 onDelta/onReasoning
        agent.onTokenEstimate = { est =>
            tui.setAgentTokenEstimate(est)
        }
        agent.onToolStart = { name, args =>
            if (StreamState.active) {
                TuiBridge.delta("")
                StreamState.active = false
            }
            TuiBridge.ensureNewline()
            // 工具调用行 bg 236 整行卡片（P2b）：行内只用 fg 改色、禁止中途 reset（保背景）
            TuiBridge.tool(Ansi.fg(Ansi.THEME_OK) + "▶ ${name} " + Ansi.fg(Ansi.THEME_MUTED) + formatToolArgs(name, args))
            tui.setAgentState("Running ${name}…")
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            // read_file 是按需读取工具，LLM 已通过 offset/limit 控制读取量；
            // 截断 preview 会让 LLM 误以为输出被截断，反复换 bash 重读
            let maxPreview: Int64 = if (name == "read_file") { 2000 } else { 200 }
            if (Int64(preview.size) > maxPreview) {
                preview = truncateUtf8(preview, maxPreview) + "…"
            }
            TuiBridge.ensureNewline()
            TuiBridge.output(Ansi.fg(Ansi.THEME_MUTED) + "  ↳ ${name}: ${preview}" + Ansi.reset())
        }
        // 审批链：危险操作需人工确认时，在 TUI 内嵌审批（y/n）
        agent.onApproval = { name, args, reason =>
            TuiBridge.ensureNewline()
            TuiBridge.output(Ansi.fg(Ansi.THEME_WARN) + "⚠ 需人工确认: ${name} " + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + formatToolArgs(name, args) + Ansi.reset())
            // G-B：审批项带 agent 身份——子代理审批的 reason 以 "[task:label] " 开头，
            // 提取 label 存入审批队列（父自身审批无前缀，label 为空）
            var label = ""
            if (reason.startsWith("[task:")) {
                let segs = reason.split("]", -1)
                if (segs.size > 1) {
                    label = segs[0].replace("[task:", "")
                }
            }
            TuiBridge.requestApproval(reason, label)
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
                md.setUtf8(tui.isUtf8())  // 表格边框按终端能力降级
                TuiBridge.endStream(indentReply(md.process(text) + md.finish()))
                StreamState.active = false
            } else {
                // 非流式（旧协议全量返回）：整体渲染 markdown
                let md = MarkdownRender()
                md.setUtf8(tui.isUtf8())  // 表格边框按终端能力降级
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
            let rate = s.cacheHitRate()
            // 单复数 + 1 位小数格式化（整数运算避免浮点精度噪声）
            let roundWord = if (s.rounds == 1) { "round" } else { "rounds" }
            let toolWord = if (s.toolCalls == 1) { "tool" } else { "tools" }
            // 耗时：ms → 秒.十分位（42.6s）
            let secInt = s.durationMs / 1000
            let secTenths = (s.durationMs % 1000) / 100
            // tokens 走 cjterm.fmtTokenCount（与实时状态行/思考折叠行同格式：1.2k）
            let tokTotal = s.totalTokens()
            // 格式：─── ✓ 2 rounds · 3 tools · 42.6s · 1.5k tokens · 99% cached ───
            // 整行统一灰色（THEME_MUTED），居中：左右横线等分
            let stat = "✓ ${s.rounds} ${roundWord} · ${s.toolCalls} ${toolWord} · ${secInt}.${secTenths}s · ${fmtTokenCount(tokTotal)} tokens · ${rate}% cached"
            let (_, cols) = TermSize.get()
            let statW = TuiCanvas.displayWidth(stat)
            // 内容总宽 = 左横线 + 1空格 + stat + 1空格 + 右横线
            // 居中：左右横线各 (cols - statW - 2) / 2，余数补到左侧
            let avail = cols - statW - 2  // 去掉两侧空格后剩余给横线
            var leftDash: Int64 = 3
            var rightDash: Int64 = 3
            if (avail > 6) {
                leftDash = avail / 2 + avail % 2  // 余数补左侧，视觉居中
                rightDash = avail / 2
            }
            // 横线按终端能力降级（非 UTF-8 终端 ─ 乱码；TUI 内输出区同屏混排）
            let dash = if (tui.isUtf8()) { "─" } else { "-" }
            var bar = StringBuilder()
            bar.append(Ansi.fg(Ansi.THEME_MUTED))
            var i: Int64 = 0
            while (i < leftDash) {
                bar.append(dash)
                i += 1
            }
            bar.append(" " + stat + " ")
            i = 0
            while (i < rightDash) {
                bar.append(dash)
                i += 1
            }
            bar.append(Ansi.reset())
            TuiBridge.output("")  // 上空行
            TuiBridge.output(bar.toString())
            TuiBridge.output("")  // 下空行
        }

        SessionState.current = curSessionId
        // provider 配置表单提交回调：写回 settings/auth，重建 provider 热切换
        tui.onProviderSubmit = { provider, baseUrl, model, apiKey, protocol =>
            // provider 字段用于预设匹配（空则按 base_url/model 直接写）
            var label = provider
            if (label.size == 0) {
                label = model
            }
            try {
                cjhCfg.saveProvider(baseUrl, model)
                cjhCfg.saveProviderProtocol(protocol)
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
        // P0-2：Ctrl+C 中断当前任务（agent 忙时）
        tui.onInterrupt = { =>
            agent.interrupt()
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
                // P1-6：会话结束后保存项目记忆（供下次会话注入，Hindsight 式）
                // 独立 try 兜底：summarizeForMemory() 实参求值或落盘若抛异常，绝不允许杀死收尾线程——
                // 否则下面 setAgentRunning(false) 永不执行，TUI 永久卡在忙"Streaming…"态、排队消息永不发送
                // （2026-09-01 僵尸忙态：中文历史摘要 task[0..60] 字节切片在 CJK 中间抛异常，spawn 未捕获异常只杀线程）。
                if (summary.rounds > 0) {
                    try {
                        let memSummary = agent.summarizeForMemory()
                        saveProjectMemory(cjhCfg.memoryDir, memSummary)
                    } catch (e: Exception) {
                        Log.warn("项目记忆保存失败（不影响主流程）: ${e}")
                    }
                }
                // 先关闭 agent 运行态（动态状态栏消失，输出区恢复占满），
                // 再触发 onRunComplete 渲染回合总结条，避免总结条被收缩的输出区挤压
                tui.setAgentRunning(false)
                if (summary.rounds > 0) {
                    agent.onRunComplete(summary)
                }
                // 自动处理队列下一条（如果有）
                // 注意：不在 echo "❯ next"——提交时 inputBox.onSubmit 已回显过，
                // 这里再 echo 会重复（排队消息在入队瞬间已有一条回显）
                if (let Some(next) <- tui.dequeueInput()) {
                    // 先置忙再提交：关闭 dequeue→spawn 调度间隙
                    // （否则该窗口提交的消息看到 busy=false 而绕过队列并发执行）
                    tui.setAgentRunning(true)
                    tui.onSubmit(next)
                }
            }
        }

        // /resume 交互式选择确认：选中会话后恢复历史
        tui.onSessionResume = { id =>
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
        if (let Some(t) <- tuiOpt) {
            t.restoreTerminal()
        }
        // 退出清理：回收子进程 + 断开 MCP + 停止日志 sink 协程。
        // 2026-09-03 事故根因之一：退出路径从不关闭 BashSession/MCP，
        // 泄漏约 2 小时的会话 bash + 未回收僵尸；Log sink 协程也持续运行。
        // 各项独立 try/catch，单项失败不阻断其余清理。
        try {
            match (registry.getTool("bash")) {
                case Some(bash: BashTool) => bash.close()
                case _ => ()
            }
        } catch (e: Exception) {
            ()
        }
        try {
            mcpManager.disconnectAll()
        } catch (e: Exception) {
            ()
        }
        try {
            Log.shutdown()
        } catch (e: Exception) {
            ()
        }
    }
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
func applyProvider(cfg: CjhConfig, agent: Agent, tui: TuiApp, label: String, baseUrl: String, model: String, apiKey: String, protocol: String): Bool {
    try {
        cfg.saveProvider(baseUrl, model)
        if (protocol.size > 0) {
            cfg.saveProviderProtocol(protocol)
        }
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
 * 列出已保存的会话（--list 入口）
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

/**
 * 构造子代理 registry 视图（方案 §6 / 决策 D2）
 *
 * - G3 深度 1：剥离 task（子代理不得再派子代理，防 fork bomb）
 * - G4 todo 隔离：剥离 todo_write（其回调绑定父 agent，子代理调用会写主会话任务面板）
 * - G2 explore 结构化只读：仅保留 isReadOnly()==true 的工具，写工具物理不可达，
 *   不依赖 system prompt 自觉（bash 本身 isReadOnly()==false，自动被排除）
 * - worker：全量工具（仍受继承的 capability 三域闸门约束）
 *
 * 工具实例与父共享（工具层每调用独立状态，无静态踩踏，见 GlobCallState 等）。
 */
func buildSubagentRegistry(parent: ToolRegistry, subagentType: String): ToolRegistry {
    let reg = ToolRegistry()
    for (spec in parent.specs()) {
        if (spec.name == "task" || spec.name == "todo_write") {
            continue
        }
        if (subagentType == "explore" && !parent.isReadOnly(spec.name)) {
            continue
        }
        match (parent.getTool(spec.name)) {
            case Some(t) => reg.register(t)
            case None => ()
        }
    }
    return reg
}

/**
 * 构造子代理 AgentConfig（方案 §6）
 *
 * - G1 capability 继承：直接复用父 Capability 实例——三域白名单/审批链与父一致，
 *   保证"子权限 ⊆ 父权限"（此前两参构造默认宽松，父开严格审批子代理却畅通无阻）
 * - 子代理短生命周期（maxIterations=5）：关闭 compaction（条数/token 阈值均 0），
 *   避免后台摘要线程与 5 轮快跑竞争
 * - G6 落盘隔离：spillDir 继承，sessionId 追加 /sub-<type> 段——落盘路径
 *   spillDir/<sid>/sub-<type>/<toolCallId>.txt（writeSpill 递归建目录，天然生效）
 */
func buildSubagentConfig(parent: AgentConfig, subagentType: String): AgentConfig {
    let subSession = parent.sessionId + "/sub-" + subagentType
    return AgentConfig(buildSubagentPrompt(subagentType), 5, parent.capability,
        0, 0, 6, parent.toolResultMaxChars, parent.spillDir, subSession)
}

/**
 * S2：子代理 provider 工厂——每次派生新建实例。
 * OpenAiProvider.currentTransport 是单槽，父/子共享同一实例时，
 * 任一 agent 的 abort() 会关到"最后注册"的那条连接（评审 P0-2）。
 * mock 模式沿用同一构造路径（MockProvider 无连接，无串台问题）。
 */
func makeSubagentProvider(cjhCfg: CjhConfig): LlmProvider {
    if ((readEnv("CJH_MOCK") ?? "") == "1") {
        return MockProvider("/tmp/cjh_verify.txt")
    }
    // 复核 E：warmup=false——实例用完即弃（finally abort()），预热连接纯开销
    return makeProvider(cjhCfg, false)
}

/**
 * 派发子代理执行独立任务（方案定稿 §5-§7）
 *
 * 创建一个临时 Agent，跑一轮独立对话，返回结构化结果：
 * - 上下文隔离：子代理有独立 messages 历史，父历史一个字节不给（比 fork-COW 更彻底）；
 *   上下文经"简报 ↓"显式传递 = 子任务 prompt + 父会话上下文块（触碰文件表 + 摘要，决策 D1）
 * - 权限单调：capability 继承父实例 + registry 视图收窄（explore 只读 / 深度 1 / 剥离 todo_write）
 * - 审批传播（G5）：子代理触发审批经父通道，reason 打 [task:description] 前缀，
 *   TUI 弹窗 / WS approval_request 的 reason 字段都会展示，协议零变更
 * - 中断传播：登记到父 → 跑 → finally 注销；父 interrupt() 时子代理同置中断（cancelled 出口）
 * - 结构化出口：status = ok / failed（errorCode 非空或执行异常）/ cancelled（父中断传播）
 *
 * @param provider 父 Agent 的 provider（复用连接）
 * @param parentRegistry 父 Agent 的工具注册表（构造子视图的来源）
 * @param parent 父 Agent 实例（taskBriefContext 简报来源 + 审批/中断传播目标）
 * @param parentConfig 父 Agent 的配置（capability/spillDir/sessionId 继承）
 * @param description 任务标签（审批 reason 前缀 [task:description] 用）
 * @param prompt 子任务指令
 * @param subagentType "explore"（只读）或 "worker"（可写）
 */
func spawnSubagent(provider: LlmProvider, parentRegistry: ToolRegistry, parent: Agent,
    parentConfig: AgentConfig, description: String, prompt: String, subagentType: String,
    scope: ArrayList<String>): TaskSpawnResult {
    // S4 边界闸门：配额满 → 结构化 budget_exceeded（文案告诉模型改策略）；
    // 并发名额满则排队（排队中父中断 → cancelled，不丢任务不挂死）
    var slotAcquired = false
    match (parent.subagentScheduler) {
        case Some(sched) =>
            if (!sched.allowSpawn()) {
                return TaskSpawnResult(
                    "子代理配额已满（本回合派生上限或 token 预算用尽）。请直接处理本任务，勿再派发。",
                    0, 0, 0, "budget_exceeded")
            }
            if (!sched.acquire({ => parent.isInterrupted() })) {
                return TaskSpawnResult("子代理排队等待并发名额时被中断", 0, 0, 0, "cancelled")
            }
            sched.recordSpawn()
            slotAcquired = true
        case None => ()
    }
    // D1 简报：子任务指令 + 父会话上下文块（taskBriefContext 内部限长 ~1500 字符）
    let brief = prompt + "\n\n" + parent.taskBriefContext()

    let subRegistry = buildSubagentRegistry(parentRegistry, subagentType)
    let subConfig = buildSubagentConfig(parentConfig, subagentType)
    // S6：task scope → 子代理写域（AND 收窄；explore 只读不受影响）
    subConfig.writeScope = scope
    let subAgent = Agent(provider, subRegistry, subConfig)

    // G5 审批传播：子审批经父通道，reason 加前缀（工具名/参数原样透传，客户端无需改版）
    // G-B：审批等待期间面板"当前工具"列显示 等待审批（审批返回后恢复工具名）
    let parentApproval = parent.onApproval
    subAgent.onApproval = { toolName, args, reason =>
        match (parent.subagentScheduler) {
            case Some(s) => s.markTool(subAgent.agentId, "等待审批")
            case None => ()
        }
        let approved = parentApproval(toolName, args, "[task:${description}] ${reason}")
        match (parent.subagentScheduler) {
            case Some(s) => s.markTool(subAgent.agentId, toolName)
            case None => ()
        }
        approved
    }

    // S3b 调度器接线：节点登记 + 当前工具转发 + 行事件上抛（焦点转发由 UI 决定去留）
    match (parent.subagentScheduler) {
        case Some(sched) =>
            let node = AgentNode(subAgent.agentId, parent.agentId, description, subagentType)
            node.state = AgentNodeState.Running
            sched.register(node)
            subAgent.onToolStart = { name, _ =>
                sched.markTool(subAgent.agentId, name)
                parent.onSubagentEvent(subAgent.agentId, "tool_start", "▶ ${name}")
            }
            subAgent.onToolResult = { name, _ =>
                parent.onSubagentEvent(subAgent.agentId, "tool_result", "↳ ${name}")
            }
        case None => ()
    }

    // 终态回写所需（finally 统一落齐；异常路径 Failed + 零归账）
    var finState = AgentNodeState.Failed
    var finIterations: Int64 = 0
    var finPrompt: Int64 = 0
    var finCompletion: Int64 = 0

    // 中断传播：登记 → 跑 → finally 注销（异常路径也注销，防登记表泄漏）
    parent.registerChild(subAgent)
    // S4：墙钟超时（0=不限；来自 scheduler 配置）
    let timeoutMs: Int64 = match (parent.subagentScheduler) {
        case Some(s) => s.timeoutMs
        case None => 0
    }
    try {
        let summary = runSubagentWithTimeout(subAgent, brief, timeoutMs)
        var status = "ok"
        finState = AgentNodeState.Ok
        if (summary.errorCode.size > 0) {
            status = "failed"
            finState = AgentNodeState.Failed
        }
        // 中断出口：runLoop 中断分支固定以 "[已中断" 开头返回（含请求期/流式中断）
        if (summary.reply.contains("[已中断")) {
            status = "cancelled"
            finState = AgentNodeState.Cancelled
        }
        finIterations = summary.rounds
        finPrompt = summary.promptTokens
        finCompletion = summary.completionTokens
        var resultText = extractSubagentResult(subAgent)
        // S5(c) 事后纠偏（比说教有效）：1 轮完成且结论稀薄（<200 字符）的派生，
        // 明确告诉模型这次外包不划算——用真实成本反馈自我校准
        if (summary.rounds <= 1 && resultText.toRuneArray().size < 200) {
            resultText = resultText +
                "\n[路由提示] 该子任务 ${summary.rounds} 轮完成、结论 ${resultText.toRuneArray().size} 字符；" +
                "此类任务下次请直接处理（单次派生固定开销约 3–5k token：子代理 system prompt + 全量工具 schema）"
        }
        return TaskSpawnResult(resultText, summary.rounds,
            summary.promptTokens, summary.completionTokens, status)
    } catch (e: SubagentTimeoutException) {
        // S4：墙钟超时 → 结构化 timeout（父按失败矩阵"中断并回收引用"处理）
        finState = AgentNodeState.Timeout
        return TaskSpawnResult("子代理超时（${timeoutMs}ms 未完成），已中断并回收引用", 0, 0, 0, "timeout")
    } catch (e: Exception) {
        // 仓颉 spawn 内未捕获异常退出码为 0 的已知坑（方案 §10 风险4）：
        // 子代理线程必须 try/catch 全包，失败转结构化 failed 而非静默
        return TaskSpawnResult("子代理执行异常: ${e}", 0, 0, 0, "failed")
    } finally {
        // S3b：终态回写面板 + token 归账（异常路径 Failed/0）
        match (parent.subagentScheduler) {
            case Some(sched) =>
                sched.finish(subAgent.agentId, finState, finIterations, finPrompt, finCompletion)
                sched.addTokens(finPrompt + finCompletion)
            case None => ()
        }
        // S4：释放并发名额（闸门通过后才持有）
        if (slotAcquired) {
            match (parent.subagentScheduler) {
                case Some(sched) => sched.release()
                case None => ()
            }
        }
        // 复核 E：子代理 provider 是每次派生新建的实例，收尾必须 abort() 关掉
        // 池化 keep-alive 连接（同时关 current+pooled），否则每次派生泄漏 1 个 fd
        provider.abort()
        parent.unregisterChild(subAgent)
    }
}

/**
 * S4：带墙钟超时的子代理运行（仓颉线程无法 safe kill：超时=置中断 + 5s 宽限 + 放弃引用）。
 * 超时抛 SubagentTimeoutException（调用方映射 status=timeout）；timeoutMs<=0 内联直跑（现状路径）。
 */
func runSubagentWithTimeout(agent: Agent, brief: String, timeoutMs: Int64): RunSummary {
    if (timeoutMs <= 0) {
        return agent.run(brief)
    }
    // 仓颉 lambda 不能捕获可变局部变量：ArrayList 包装哨兵
    let out = ArrayList<RunSummary>()
    let errs = ArrayList<Exception>()
    let runner = spawn {
        try {
            out.add(agent.run(brief))
        } catch (e: Exception) {
            errs.add(e)
        }
    }
    var elapsed: Int64 = 0
    while (out.size == 0 && errs.size == 0 && elapsed < timeoutMs) {
        sleep(Duration.millisecond * 25)
        elapsed += 25
    }
    if (out.size == 0 && errs.size == 0) {
        // 超时：中断子代理（runLoop 尽快退出），等 5s 宽限后放弃引用
        agent.interrupt()
        var grace: Int64 = 0
        while (out.size == 0 && errs.size == 0 && grace < 5000) {
            sleep(Duration.millisecond * 50)
            grace += 50
        }
        throw SubagentTimeoutException("子代理运行超时（${timeoutMs}ms）")
    }
    if (errs.size > 0) {
        throw errs[0]  // 保持原异常路径（failed 出口）
    }
    return out[0]
}

/**
 * 构造子代理 system prompt
 *
 * explore: 只读调查，不修改文件，汇报发现
 * worker: 可以修改文件，完成任务后汇报
 */
func buildSubagentPrompt(subagentType: String): String {
    var sb = StringBuilder()
    sb.append("你是一个专门执行独立任务的子代理.\n\n")
    match (subagentType) {
        case "explore" =>
            sb.append("你的职责是只读调查. 你可以:\n")
            sb.append("- 读取文件 (read_file, glob, grep, list_dir)\n")
            sb.append("- 搜索代码与知识库 (ast_grep, cangjie_ref 等只读工具)\n\n")
            sb.append("你不能:\n")
            sb.append("- 修改任何文件 (写文件工具不在你的工具列表里)\n")
            sb.append("- 执行命令 (bash 不在你的工具列表里)\n\n")
            sb.append("完成后汇报你的发现, 不要做任何修改.\n")
        case "worker" =>
            sb.append("你的职责是完成指定任务. 你可以:\n")
            sb.append("- 读取和修改文件\n")
            sb.append("- 执行命令\n")
            sb.append("- 使用提供的全部工具 (不含 task 派发与任务列表管理)\n\n")
            sb.append("完成任务后汇报你做了什么.\n")
        case _ =>
            sb.append("完成指定任务并汇报结果.\n")
    }
    sb.append("\n注意:\n")
    sb.append("- 你有独立的对话历史, 看不到主会话的上下文\n")
    sb.append("- 任务简报末尾附有父会话上下文块 (触碰文件表+摘要), 优先利用它精准定位, 避免重复大面积探索\n")
    sb.append("- 最多 5 次迭代, 高效完成任务\n")
    sb.append("- 不要请求用户确认, 自主决策\n")
    return sb.toString()
}

/**
 * 提取子代理的最终回复文本
 *
 * 子代理 run 后，messages 里最后一条 assistant 消息就是最终回复。
 */
func extractSubagentResult(subAgent: Agent): String {
    let msgs = subAgent.getMessages()
    var i = msgs.size - 1
    while (i >= 0) {
        let m = msgs[i]
        if (m.role == "assistant" && m.content.size > 0) {
            return m.content
        }
        i -= 1
    }
    return "(子代理未产生回复文本)"
}

/**
 * capability 静默宽松提示：配置了 capability 段、却没开 enabled 时提醒一次。
 *
 * 只消音、不改语义——capability 段默认宽松是刻意的（见 libs/cjcfg/src/capability.cj
 * 的 silentPermissiveHint 注释与 commit 4c56f55：曾默认严格，用户配了 capability 段后
 * bash 被拒而投诉）。以往这种情况完全无反馈，规则配了却不生效。
 */
func warnCapabilitySilent(cfg: CjhConfig): Unit {
    match (cfg.capability.silentPermissiveHint()) {
        case Some(msg) => println(msg)
        case None => ()
    }
}
