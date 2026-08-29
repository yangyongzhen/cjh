package cjh

/**
 * 入口编排：各运行模式（Web/CLI/JSON/TUI）的装配与主循环
 *
 * 从 main.cj 抽出。main.cj 只保留 main() 入口分发与共享状态类。
 * 每个入口函数职责单一：构造 ToolRegistry → 加载配置 → 建 Provider/Agent
 * → 绑定事件回调 → 进入模式主循环。
 */

import std.collection.*
import std.console.*
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())
    registerWebTools(cjhCfg, registry)
    loadSkillTools(cjhCfg.skillsDir, registry, cjhCfg.enabledSkills)
    let pluginManager = loadPlugins(cjhCfg.pluginsDir, registry, cjhCfg.enabledPlugins, cjhCfg.requireSignature)
    let mcpManager = loadMcpServers(cjhCfg.mcpServers, registry)

    let provider = makeProvider(cjhCfg)

    // 启动 Web 服务器
    let server = WebServer(cjhCfg, provider, registry)
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
        let stdin = Console.stdIn
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())

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

        // TaskTool：派发子代理执行独立任务（spawnFn 回调注入）
        registry.register(TaskTool({ description, prompt, subagentType =>
            spawnSubagent(provider, registry, config, description, prompt, subagentType)
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
    registry.register(GlobTool())
    registry.register(EditTool())
    registry.register(AstGrepTool())
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
        // TaskTool：派发子代理执行独立任务（spawnFn 回调注入）
        registry.register(TaskTool({ description, prompt, subagentType =>
            spawnSubagent(provider, registry, config, description, prompt, subagentType)
        }))

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
                // 正式 content 开始：清空思考窗口，让它消失
                tui.clearReasoning()
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
        agent.onReasoning = { r =>
            if (r.size > 0) {
                tui.appendReasoning(r)
            }
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
            let rate = s.cacheHitRate()
            // 单复数 + 1 位小数格式化（整数运算避免浮点精度噪声）
            let roundWord = if (s.rounds == 1) { "round" } else { "rounds" }
            let toolWord = if (s.toolCalls == 1) { "tool" } else { "tools" }
            // 耗时：ms → 秒.十分位（42.6s）
            let secInt = s.durationMs / 1000
            let secTenths = (s.durationMs % 1000) / 100
            // tokens → K.十分位（1.5K tokens）
            let tokTotal = s.totalTokens()
            let kInt = tokTotal / 1000
            let kTenths = (tokTotal % 1000) / 100
            // 格式：─── ✓ 2 rounds · 3 tools · 42.6s · 1.5K tokens · 99% cached ───
            // 整行统一灰色（THEME_MUTED），居中：左右横线等分
            let stat = "✓ ${s.rounds} ${roundWord} · ${s.toolCalls} ${toolWord} · ${secInt}.${secTenths}s · ${kInt}.${kTenths}K tokens · ${rate}% cached"
            let (rows, cols) = TermSize.get()
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
            var bar = StringBuilder()
            bar.append(Ansi.fg(Ansi.THEME_MUTED))
            var i: Int64 = 0
            while (i < leftDash) {
                bar.append("─")
                i += 1
            }
            bar.append(" " + stat + " ")
            i = 0
            while (i < rightDash) {
                bar.append("─")
                i += 1
            }
            bar.append(Ansi.reset())
            TuiBridge.output("")  // 上空行
            TuiBridge.output(bar.toString())
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
        match (tuiOpt) {
            case Some(t) => t.restoreTerminal()
            case None => ()
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
 * 派发子代理执行独立任务
 *
 * 创建一个临时 Agent，用相同 provider 和 tools，跑一轮独立对话，返回结果。
 * 子代理有独立的 messages 历史，不影响主对话。
 * 子代理 max_iterations 限制为 5（避免失控）。
 *
 * @param provider 父 Agent 的 provider（复用连接）
 * @param registry 父 Agent 的工具注册表（复用工具）
 * @param config 父 Agent 的配置（复用 system prompt）
 * @param description 3-5 词任务标签
 * @param prompt 完整任务指令
 * @param subagentType "explore"（只读）或 "worker"（可写）
 * @return TaskSpawnResult 子代理执行结果
 */
func spawnSubagent(provider: LlmProvider, registry: ToolRegistry, config: AgentConfig,
    description: String, prompt: String, subagentType: String): TaskSpawnResult {
    // 构造子代理 system prompt
    let systemPrompt = buildSubagentPrompt(subagentType)

    // 创建子 Agent：复用父 Agent 的 provider 和 tools，max_iterations 限制为 5
    let subConfig = AgentConfig(systemPrompt, 5)
    let subAgent = Agent(provider, registry, subConfig)

    // 子代理不需要 TUI 回调，默认空回调即可
    // 运行子代理
    let summary = subAgent.run(prompt)

    // 提取子代理的最终回复文本
    let resultText = extractSubagentResult(subAgent)

    return TaskSpawnResult(resultText, summary.rounds,
        summary.promptTokens, summary.completionTokens)
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
            sb.append("- 执行只读命令 (bash 里只读操作)\n")
            sb.append("- 搜索代码结构\n\n")
            sb.append("你不能:\n")
            sb.append("- 修改任何文件 (write_file, edit, append_file, hashline_edit 禁用)\n")
            sb.append("- 执行有副作用的命令 (git commit, rm, etc.)\n\n")
            sb.append("完成后汇报你的发现, 不要做任何修改.\n")
        case "worker" =>
            sb.append("你的职责是完成指定任务. 你可以:\n")
            sb.append("- 读取和修改文件\n")
            sb.append("- 执行命令\n")
            sb.append("- 使用所有可用工具\n\n")
            sb.append("完成任务后汇报你做了什么.\n")
        case _ =>
            sb.append("完成指定任务并汇报结果.\n")
    }
    sb.append("\n注意:\n")
    sb.append("- 你有独立的对话历史, 看不到主会话的上下文\n")
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
