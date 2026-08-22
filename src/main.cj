package cjh

import std.collection.*
import std.env.*
import std.fs.*
import std.convert.Parsable
import cjllm.*
import cjh.agent.*
import cjh.tools.*
import cjllm.*
import cjh.tui.*
import cjterm.*
import cjcfg.*

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
    registry.register(GrepTool())
    registry.register(ListDirTool())

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
    let answer = agent.run("请读取 /tmp/cjh_verify.txt 并统计行数")
    println("=== 最终答复 ===")
    println(answer)

    if (VerifyState.toolCalls == 3 && answer.contains("验证完成")) {
        println("\n✅ 验证通过：工具调用链完整（read_file → grep → list_dir → 最终答复）")
        return 0
    } else {
        println("\n❌ 验证失败：工具调用=${VerifyState.toolCalls}（期望 3）")
        return 1
    }
}


/**
 * 由配置生成 LLM provider（业务装配，不属于 cjcfg 通用库）
 * 提供商选择：CJH_PROVIDER=anthropic 用 Anthropic，默认 OpenAI 兼容
 */
func makeProvider(cfg: CjhConfig): LlmProvider {
    if (cfg.apiKey.size == 0) {
        throw LlmException(
            "未配置 API Key。请在 ${cfg.authPath} 的 api_key 字段填写，或设置 OPENAI_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY 环境变量")
    }
    // provider 选择：显式 CJH_PROVIDER=anthropic 才用 Anthropic
    // （auth.json 的 key 优先；env 变量可覆盖。绝不自动劫持到 Anthropic）
    let providerName = readEnv("CJH_PROVIDER") ?? ""
    var p: LlmProvider
    if (providerName == "anthropic") {
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
        var line = String.fromUtf8(buf[0..n])
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

main(args: Array<String>): Int64 {
    if (args.size > 0 && args[0] == "--mock") {
        return runMockVerify()
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
    return runTui("")
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
    registry.register(GrepTool())
    registry.register(ListDirTool())

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()

    let config = AgentConfig(
        cjhCfg.systemPrompt,
        cjhCfg.maxIterations,
        cjhCfg.capability)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = makeProvider(cjhCfg)
        }
        let agent = Agent(provider, registry, config)
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
 * TUI 交互模式（默认）
 */
func runTui(sessionId: String): Int64 {
    // TUI 全屏模式：立即屏蔽 stderr（配置生成等提示不污染屏幕）
    Stderr.suppress()
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()

    let config = AgentConfig(
        cjhCfg.systemPrompt,
        cjhCfg.maxIterations,
        cjhCfg.capability)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = makeProvider(cjhCfg)
        }
        let agent = Agent(provider, registry, config)

        // 线程安全的输出队列（agent 在调用线程运行，输出经队列到 TUI）
        let tui = TuiApp()
        tui.setModel(cjhCfg.model)

        // 会话：恢复历史 / 新会话
        let store = SessionStore(cjhCfg.sessionsDir)
        var curSessionId = sessionId
        if (curSessionId.size > 0) {
            let history = store.load(curSessionId)
            if (history.size > 0) {
                agent.loadHistory(history)
                tui.appendOutput(Ansi.fg(Ansi.COLOR_BLUE) + "[resumed ${curSessionId} (${history.size} msgs)]" + Ansi.reset())
            } else {
                tui.appendOutput(Ansi.fg(Ansi.COLOR_YELLOW) + "[session ${curSessionId} not found, new session]" + Ansi.reset())
                curSessionId = ""
            }
        }

        StreamState.active = false
        StreamState.md = MarkdownRender()
        TuiBridge.app = tui
        agent.onDelta = { d =>
            if (d.size > 0) {
                if (!StreamState.active) {
                    TuiBridge.delta("")
                    StreamState.active = true
                }
                TuiBridge.delta(StreamState.md.process(d))
            }
        }
        agent.onToolStart = { name, args =>
            if (StreamState.active) {
                TuiBridge.output("")
                StreamState.active = false
            }
            TuiBridge.output(Ansi.fg(Ansi.COLOR_GREEN) + "▶ ${name} " + Ansi.reset() + Ansi.fg(Ansi.COLOR_GRAY) + "${args.toJsonString()}" + Ansi.reset())
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            if (preview.size > 200) {
                preview = truncateUtf8(preview, 200) + "…"
            }
            TuiBridge.output(Ansi.fg(Ansi.COLOR_GRAY) + "  ↳ ${name}: ${preview}" + Ansi.reset())
        }
        // 审批链：危险操作需人工确认时，在 TUI 内嵌审批（y/n）
        agent.onApproval = { name, args, reason =>
            TuiBridge.output(Ansi.fg(Ansi.COLOR_YELLOW) + "⚠ 需人工确认: ${name} ${args.toJsonString()}" + Ansi.reset())
            TuiBridge.requestApproval(reason)
        }
        agent.onAssistantText = { text =>
            if (StreamState.active) {
                // 流式结束：用最终完整文本（已整体修复 mojibake）整体渲染并重绘替换流式段
                let md = MarkdownRender()
                TuiBridge.endStream(md.process(text) + md.finish())
                StreamState.active = false
            } else {
                // 非流式（旧协议全量返回）：整体渲染 markdown
                let md = MarkdownRender()
                TuiBridge.output(md.process(text) + md.finish())
            }
        }

        SessionState.current = curSessionId
        tui.onSubmit = { input =>
            // slash 命令（对齐 pi：/help /new /resume /quit /model /settings）
            if (input.startsWith("/")) {
                handleSlashCommand(input, agent, store, tui, cjhCfg)
                return
            }
            // 异步执行 agent（TUI 主循环持续渲染，避免阻塞）
            spawn {
                try {
                    let _ = agent.run(input)
                    if (StreamState.active) {
                        tui.appendOutput(Ansi.reset())
                        StreamState.active = false
                    }
                    // 会话分隔线
                    let (rows, cols) = TermSize.get()
                    tui.appendDivider(cols)
                    // 保存会话（含首轮时创建 ID）
                    if (SessionState.current.size == 0) {
                        SessionState.current = store.save(agent.history())
                        TuiBridge.status("[saved ${SessionState.current}, --resume ${SessionState.current}]")
                    } else {
                        let _ = store.save(agent.history())
                    }
                } catch (e: Exception) {
                    TuiBridge.output(Ansi.fg(Ansi.COLOR_RED) + "错误: ${e}" + Ansi.reset())
                }
            }
        }

        tui.run()
        Stderr.restore()
        return 0
    } catch (e: Exception) {
        Stderr.restore()
        eprintln("启动失败: ${e}")
        return 1
    }
}

class SessionState {
    static var current: String = ""
}

/**
 * TUI slash 命令分发（对齐 pi 基础命令：/help /new /resume /quit /model /settings）
 */
func handleSlashCommand(input: String, agent: Agent, store: SessionStore, tui: TuiApp, cfg: CjhConfig): Unit {
    let cmd = input.trimAscii().split(" ", -1)[0]
    let args = input.trimAscii()
    match (cmd) {
        case "/help" =>
            tui.appendOutput(Ansi.fg(Ansi.COLOR_CYAN) + "可用命令：" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /help          显示本帮助" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /new           开始新会话" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /resume [id]   恢复历史会话（无 id 时列出）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /model [id|#]  列出/切换模型" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /settings      查看采样参数（temp/max_tokens）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  /quit          退出" + Ansi.reset())
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
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + "[已切换模型: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[切换模型失败: ${e}]" + Ansi.reset())
                    }
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[未知模型: ${target}；/model 查看列表]" + Ansi.reset())
                }
            } else {
                // 列出模型
                if (cfg.models.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "[未配置 models 列表；当前: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_CYAN) + "可用模型（/model <id|#序号> 切换）：" + Ansi.reset())
                    for (i in 0..cfg.models.size) {
                        let m = cfg.models[i]
                        let label = if (m.name.size > 0) { m.name } else { m.id }
                        let cur = if (m.id == cfg.model) { " ◀" } else { "" }
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  #${i} ${label} (${m.id})${cur}" + Ansi.reset())
                    }
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "当前: ${cfg.model} (temp=${cfg.temperature}, max_tokens=${cfg.maxTokens})" + Ansi.reset())
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
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + "[temperature = ${cfg.temperature}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else if (parts.size == 3 && parts[1] == "max_tokens") {
                try {
                    cfg.maxTokens = Int64.parse(parts[2])
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + "[max_tokens = ${cfg.maxTokens}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else {
                tui.appendOutput(Ansi.fg(Ansi.COLOR_CYAN) + "采样参数（/settings temp 0.9 或 /settings max_tokens 8192 调整）：" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  model       ${cfg.model}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  temperature ${cfg.temperature}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  max_tokens  ${cfg.maxTokens}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  base_url    ${cfg.baseUrl}" + Ansi.reset())
            }
        case "/new" =>
            // 清空会话：重开 agent 历史（保留 system）
            let history = agent.history()
            while (history.size > 1) {
                history.remove(history.size - 1..history.size)
            }
            SessionState.current = ""
            tui.appendOutput(Ansi.fg(Ansi.COLOR_YELLOW) + "[新会话]" + Ansi.reset())
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
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_BLUE) + "[resumed ${id} (${history.size} msgs)]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "[会话 ${id} 不存在]" + Ansi.reset())
                }
            } else {
                // 列出会话
                let sessions = store.list()
                if (sessions.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "[暂无会话]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_CYAN) + "已保存的会话（/resume <id> 恢复）：" + Ansi.reset())
                    for ((id, summary) in sessions) {
                        tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  ${id}  |  ${summary}" + Ansi.reset())
                    }
                }
            }
        case "/quit" =>
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "[再见]" + Ansi.reset())
            // 退出由主循环处理；先短暂刷新再退出
            spawn { tui.quit() }
        case _ =>
            tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "未知命令: ${cmd}（输入 /help 查看）" + Ansi.reset())
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
