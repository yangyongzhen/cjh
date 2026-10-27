package cjh.agent

import std.collection.*
import cjlog.*
import stdx.encoding.json.*
import std.time.*
import cjllm.*
import cjh.tools.*
import cjllm.*
import cjcfg.*
import cjutil.*
import std.sync.*

/**
 * Agent 生命周期事件钩子（Claude Code 式，统一事件化）
 *
 * 事件触发点（Agent.run 内部）：
 *   - PreToolUse   工具执行前（payload: {tool, args}）
 *   - PostToolUse  工具执行后（payload: {tool, result}）
 *   - ChatDelta    流式文本增量（payload: {delta}）
 *   - Reasoning    思考增量（payload: {delta}）
 *   - Stop         回合完成（payload: {rounds, toolCalls, durationMs, reply}）
 *   - Interrupt    用户中断（payload: {}）
 *
 * 注册：agent.addHook(AgentHook.PreToolUse, { payload => ... })
 * 本阶段为通知型钩子（观察/联动）；阻断/改参由 onApproval 审批链承担。
 */
public enum AgentHook {
    | PreToolUse
    | PostToolUse
    | ChatDelta
    | Reasoning
    | Stop
    | Interrupt
}

/**
 * 事件名（注册表键）
 */
public func hookName(hook: AgentHook): String {
    match (hook) {
        case AgentHook.PreToolUse => return "PreToolUse"
        case AgentHook.PostToolUse => return "PostToolUse"
        case AgentHook.ChatDelta => return "ChatDelta"
        case AgentHook.Reasoning => return "Reasoning"
        case AgentHook.Stop => return "Stop"
        case AgentHook.Interrupt => return "Interrupt"
    }
}

/**
 * Agent 回合状态机：统一生命周期管理，消除状态残留 bug
 *
 * 状态转换：
 *   Idle → Running    run() 开始（beginRound 重置一切残留）
 *   Running → Interrupted  interrupt()（用户中断）
 *   Running/Interrupted → Idle  run() 结束（endRound，含异常路径 finally 兜底）
 *   Done 为回合完成标记（Interrupted 用于中断，Done 用于正常完成）
 *
 * run() 开头 beginRound / 结尾 finally endRound——所有出口（正常/中断/异常）
 * 统一清理，杜绝"interruptFlag 残留导致永不回复"类 bug。
 */
public enum RoundState {
    | Idle
    | Running
    | Interrupted
    | Done
}

/**
 * Agent 配置
 */
public class AgentConfig {
    public let systemPrompt: String
    public let maxIterations: Int64
    // 三域 capability 安全模型（未配置=宽松模式，全部允许）
    public let capability: Capability
    // S6 写域收窄（task scope 传入；空=不限）：executeGuarded 在 capability 之后
    // 追加 AND 判定——只收窄、绝不放宽；红线：不触碰 Capability 默认宽松语义
    public var writeScope: ArrayList<String> = ArrayList<String>()
    // Compaction 阈值：消息条数超过该值触发历史摘要压缩（0=禁用，对齐 pi）
    public let compactThreshold: Int64
    // Compaction token 阈值：估算 prompt token 超过该值也触发压缩（0=禁用）
    // 消息条数阈值对长 tool_result 不敏感，token 估算兜底避免 prompt 膨胀
    public let compactTokenThreshold: Int64
    // 压缩时保留的最近消息条数
    public let compactKeep: Int64
    // 工具结果截断阈值（字符数，0 或负数=禁用截断）
    public let toolResultMaxChars: Int64
    // 落盘根目录：工具结果超长时完整内容写到此目录下 <sessionId>/<toolCallId>.txt
    public let spillDir: String
    // 当前会话 ID（用于落盘文件按会话隔离）
    public let sessionId: String

    public init(systemPrompt: String, maxIterations: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = Capability()
        this.compactThreshold = 0
        this.compactTokenThreshold = 8000
        this.compactKeep = 6
        this.toolResultMaxChars = 6000
        this.spillDir = ""
        this.sessionId = ""
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = 0
        this.compactTokenThreshold = 8000
        this.compactKeep = 6
        this.toolResultMaxChars = 6000
        this.spillDir = ""
        this.sessionId = ""
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability,
        compactThreshold: Int64, compactKeep: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = compactThreshold
        this.compactTokenThreshold = 8000
        this.compactKeep = compactKeep
        this.toolResultMaxChars = 6000
        this.spillDir = ""
        this.sessionId = ""
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability,
        compactThreshold: Int64, compactKeep: Int64,
        toolResultMaxChars: Int64, spillDir: String, sessionId: String) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = compactThreshold
        this.compactTokenThreshold = 8000
        this.compactKeep = compactKeep
        this.toolResultMaxChars = toolResultMaxChars
        this.spillDir = spillDir
        this.sessionId = sessionId
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability,
        compactThreshold: Int64, compactTokenThreshold: Int64, compactKeep: Int64,
        toolResultMaxChars: Int64, spillDir: String, sessionId: String) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = compactThreshold
        this.compactTokenThreshold = compactTokenThreshold
        this.compactKeep = compactKeep
        this.toolResultMaxChars = toolResultMaxChars
        this.spillDir = spillDir
        this.sessionId = sessionId
    }
}

/**
 * 任务状态
 */
public enum TodoStatus {
    | Pending    // 待处理
    | InProgress // 进行中
    | Completed  // 已完成
}

/**
 * 任务项（Agent 内置任务管理，对齐 Claude Code TodoWrite）
 */
public class TodoItem {
    public let id: Int64
    public var content: String
    public var status: TodoStatus

    public init(id: Int64, content: String) {
        this.id = id
        this.content = content
        this.status = TodoStatus.Pending
    }
}

/**
 * 单次 Agent.run 的统计摘要（回合总结条数据源）
 */
public class RunSummary {
    public var rounds: Int64 = 0           // LLM 调用轮数
    public var toolCalls: Int64 = 0        // 工具调用总数
    public var durationMs: Int64 = 0       // 总耗时（毫秒）
    public var promptTokens: Int64 = 0     // 输入 token 累计
    public var completionTokens: Int64 = 0 // 输出 token 累计
    public var cachedTokens: Int64 = 0     // 缓存命中 token 累计
    public var reply: String = ""          // 最终文本答复
    // 失败信号（失败必须有结构化出口：渠道据此推 error 帧，而不是只发一个空 done）
    public var errorCode: String = ""      // 空 = 本回合没有失败
    public var errorMessage: String = ""   // 人能读的说明（不含密钥）
    public var errorRetryable: Bool = false // 原样重试是否有意义
    // 最终文本回复是否被上游 max_tokens 截断（对外信号：done 帧可选键 truncated）
    public var truncated: Bool = false
    // V2d 并发性能基线
    public var parallelBatches: Int64 = 0  // 并发执行的批次数
    public var parallelSavedMs: Int64 = 0  // 并发相比串行节省的毫秒数
    public var maxParallelism: Int64 = 0   // 最大并发度（单组最多工具数）

    public init() {}

    /**
     * 缓存命中率（0-100，prompt_tokens=0 时返回 0）
     */
    public func cacheHitRate(): Int64 {
        if (this.promptTokens == 0) {
            return 0
        }
        return this.cachedTokens * 100 / this.promptTokens
    }

    /**
     * 总 token 用量
     */
    public func totalTokens(): Int64 {
        return this.promptTokens + this.completionTokens
    }
}

/**
 * Agent 主循环：消息历史 → LLM → 工具调用 → 结果回填 → 循环
 *
 * 流程：
 * 1. 把 messages + 工具 schema 发给 LLM
 * 2. 若响应含工具调用：执行工具，把结果作为 tool 消息回填，继续循环
 * 3. 若响应为纯文本：作为最终答复返回
 */
public class Agent {
    // 实例 ID（fork 树语义）：注销子代理按 ID 匹配（仓颉无 === 引用相等），
    // 后续 Web 协议树状呈现（agent_id）也用它
    private static var agentIdCounter: Int64 = 0
    private static let agentIdLock: Mutex = Mutex()
    public let agentId: Int64
    private var provider: LlmProvider
    private let tools: ToolRegistry
    private let config: AgentConfig
    private var messages: ArrayList<ChatMessage>

    public init(provider: LlmProvider, tools: ToolRegistry, config: AgentConfig) {
        Agent.agentIdLock.lock()
        try {
            Agent.agentIdCounter += 1
            this.agentId = Agent.agentIdCounter
        } finally {
            Agent.agentIdLock.unlock()
        }
        this.provider = provider
        this.tools = tools
        this.config = config
        this.messages = ArrayList<ChatMessage>()
        this.messages.add(ChatMessage("system", config.systemPrompt))
    }
    // 上一轮 LLM 响应的真实 prompt token（usage.promptTokens）。
    // 压缩触发用它而非字符估算——估算对中文/JSON 开销严重低估（实测 6.5x 偏差），
    // 真实用量是 provider 已返回的精确值。0=尚未有测量（首轮前）。
    private var lastPromptTokens: Int64 = 0
    // 中断标志（P0-2）：用户 Ctrl+C 请求中断当前任务轮次。
    // 线程安全（主线程 handleKey 设置，agent 线程轮询检查）。
    private var interruptFlag: Bool = false
    private var interruptLock: Mutex = Mutex()
    // P1b：messages 换装锁——后台摘要任务持锁做"快照 → 换装"，
    // 主循环 loadHistory/换装同样持锁，保证快照与换装的原子性（避免换装旧列表）
    private var compactLock: Mutex = Mutex()
    // P1b 后台压缩状态：pending 摘要任务（None=无）；auto 模式（None/SyncFallback）
    private var pendingCompact: Option<Future<String>> = None
    private var autoCompactMode: String = "None"
    // P1b 模式终态标记：本 run 是否触发过后台摘要 / 是否完成过一次换装
    // （mode 推导：pending 在=Async；否则曾换装=AsyncApplied；否则 SyncFallback/None）
    private var compactTriggeredOnce: Bool = false
    private var compactAppliedOnce: Bool = false
    // 回合状态（状态机：Idle/Running/Interrupted/Done）
    private var roundState: RoundState = RoundState.Idle
    // 已完成的轮次数（异常出口时记录，供 summary 展示）
    private var roundsCompleted: Int64 = 0
    // 摘要专用快模型（P1-5 模型路由）：compaction 摘要走快模型，None=复用主 provider
    private var summaryProvider: Option<LlmProvider> = None
    // 内置任务列表（对齐 Claude Code TodoWrite，TUI Tasks 面板数据源）
    private var todos: ArrayList<TodoItem> = ArrayList<TodoItem>()
    private var nextTodoId: Int64 = 1
    // 插件管理器（V2b Step 2：事件钩子；None 时跳过钩子调用）
    private var pluginManager: ?PluginManager = None
    // 任务简报上下文（方案 §5）：本会话触碰过的文件路径（工具调用时提取），
    // 供 task 子代理简报使用；touchedLock 保护（并发子代理线程读取）
    private var touchedFiles: HashSet<String> = HashSet<String>()
    private var touchedLock: Mutex = Mutex()
    // 子代理登记（中断传播，方案 §7）：父 interrupt() 下传所有登记中的子代理，
    // spawnSubagent fork 时登记、finally 注销；childLock 保护（并发 task 线程读写）
    private var childAgents: ArrayList<Agent> = ArrayList<Agent>()
    private var childLock: Mutex = Mutex()

    // 事件回调（供 TUI/CLI 展示）
    public var onDelta: (String) -> Unit = { _ => }
    public var onReasoning: (String) -> Unit = { _ => }
    public var onToolStart: (String, JsonObject) -> Unit = { _, _ => }
    public var onToolResult: (String, ToolResult) -> Unit = { _, _ => }
    public var onAssistantText: (String) -> Unit = { _ => }
    // 状态回调（TUI 实时状态行用）
    public var onThinking: () -> Unit = { => }
    public var onTokens: (Int64) -> Unit = { _ => }
    // 流式逐帧 token 估算回调（思考过程中实时更新动态状态栏）
    public var onTokenEstimate: (Int64) -> Unit = { _ => }
    // 审批回调：危险操作需人工确认时调用，返回 true=同意执行（默认拒绝）
    public var onApproval: (String, JsonObject, String) -> Bool = { _, _, _ => false }
    // 任务变更回调（TUI Tasks 面板实时刷新）
    public var onTodosChanged: () -> Unit = { => }
    // 子代理调度器（S3：TUI Agents 面板数据源；S4 并发/预算闸门载体）——
    // 由装配层（entries）创建后注入；None = 无调度（测试直连场景）
    public var subagentScheduler: Option<SubagentScheduler> = None
    // 子代理行事件回调（S3d 焦点转发用）：(agentId, kind: tool_start|tool_result, text)
    // 硬规则：子代理 onDelta 绝不转发（OutputView 单流会撕行），只转发整行事件
    public var onSubagentEvent: (Int64, String, String) -> Unit = { _, _, _ => }
    // 每轮一次的轮次/用量回调（S3 修实测卡死）：(rounds, promptTokens, completionTokens)。
    // 面板刷新必须挂这里（每轮一次、provider 无关），不能挂 onTokenEstimate（每 SSE chunk 一次）
    public var onRoundTick: (Int64, Int64, Int64) -> Unit = { _, _, _ => }
    // 回合结束回调（渲染回合总结条：轮数/工具数/耗时/token用量/缓存命中率）
    public var onRunComplete: (RunSummary) -> Unit = { _ => }
    // 排队输入拉取回调（atomcode 式"steer"：TUI 忙时提交只入队不打断，
    // 每轮 LLM 请求前由 Agent 拉取——即"上一次工具调用完成后"的边界。
    // None=当前回合无排队输入；非 None 注入为 user 消息让模型感知新指令。
    // 注意：必须在 runLoop 循环内、interrupt 检查之后调用——用户 Esc 中断
    // 时当前 turn 提前退出，剩余排队消息由 TUI 在 run 结束后作为新 turn 发送。
    public var onRequestPendingInput: () -> Option<String> = { => None }

    // ==================== Agent 事件钩子（Claude Code 式，统一事件化 + 外部扩展）====================
    // 内部回调（onX）负责 UI 展示；hook 是外部注册点（插件/工具/宿主代码），
    // 事件触发时两者都会执行（hook 广播在内部回调之后）。
    // 事件 payload 统一为 JsonObject，便于外部处理与未来脚本化。
    // 说明：本阶段为通知型钩子（观察/记录/联动）；阻断/改参能力（Claude Code
    // PreToolUse 可拒绝）由 onApproval 审批链承担，二期可扩展返回值传播。
    public var hookHandlers: HashMap<String, ArrayList<(JsonObject) -> Unit>> = HashMap<String, ArrayList<(JsonObject) -> Unit>>()

    /**
     * 注册事件钩子（可多 handler，按注册顺序触发）
     */
    public func addHook(hook: AgentHook, handler: (JsonObject) -> Unit): Unit {
        let key = hookName(hook)
        if (this.hookHandlers.contains(key)) {
            this.hookHandlers.get(key).getOrThrow().add(handler)
        } else {
            var list = ArrayList<(JsonObject) -> Unit>()
            list.add(handler)
            this.hookHandlers.add(key, list)
        }
    }

    /**
     * 广播事件钩子（通知型）：遍历注册的 handler，异常隔离（单个 handler 失败不影响其他）
     */
    private func fireHooks(hook: AgentHook, payload: JsonObject): Unit {
        let key = hookName(hook)
        if (!this.hookHandlers.contains(key)) {
            return
        }
        let handlers = this.hookHandlers.get(key).getOrThrow()
        for (h in handlers) {
            try {
                h(payload)
            } catch (e: Exception) {
                Log.error("Agent hook ${hookName(hook)} handler 异常: ${e}", e)
            }
        }
    }

    /**
     * 请求中断当前任务（P0-2）：设置中断标志，agent 在轮次间/工具执行后
     * 检查并停止循环，保留已完成的工作。线程安全。
     */
    public func interrupt(): Unit {
        this.interruptLock.lock()
        try {
            this.interruptFlag = true
            // 状态联动：运行中中断 → Interrupted
            match (this.roundState) {
                case RoundState.Running => this.roundState = RoundState.Interrupted
                case _ => ()
            }
        } finally {
            this.interruptLock.unlock()
        }
        // 主动关闭当前 LLM 流连接：打断阻塞的流读取（否则中断要等 readTimeout
        // 才生效，用户看到"正在停止…"一直挂着、消息排队僵持）
        try {
            this.provider.abort()
        } catch (e: Exception) {
            Log.warn("Agent.interrupt abort provider 异常: ${e}")
        }
        // 诊断：确认中断请求到达 agent 层（排查"中断发出但回合不结束"）
        Log.warn("Agent.interrupt 已请求：interruptFlag=true + abort() 已调用")
        // 中断传播（方案 §7）：Ctrl+C / Web cancel 杀整棵树——
        // 登记中的子代理同置中断标志并 abort（异常隔离：单个子代理失败不影响其余）
        this.childLock.lock()
        try {
            for (c in this.childAgents) {
                try {
                    c.interrupt()
                } catch (e: Exception) {
                    Log.warn("子代理中断传播异常: ${e}")
                }
            }
        } finally {
            this.childLock.unlock()
        }
    }

    /**
     * 回合开始：统一重置状态（清除中断残留，状态 Running）
     */
    private func beginRound(): Unit {
        this.interruptLock.lock()
        try {
            this.interruptFlag = false
            this.roundState = RoundState.Running
            this.roundsCompleted = 0
        } finally {
            this.interruptLock.unlock()
        }
        // S4：回合级 token 归账清零（预算闸门按回合计）
        match (this.subagentScheduler) {
            case Some(s) => s.resetTurn()
            case None => ()
        }
    }

    /**
     * 当前已完成轮次（只读展示用；面板按轮刷新数据源）。
     * 故意不加锁：轮次是单调计数，展示竞态无害（最多旧一轮）。
     */
    public func currentRounds(): Int64 {
        return this.roundsCompleted
    }

    /**
     * 回合结束：统一清理（正常/中断/异常所有出口，状态回 Idle）
     */
    private func endRound(): Unit {
        this.interruptLock.lock()
        try {
            this.interruptFlag = false
            // 记录最终状态（Done/Interrupted），随后回 Idle 供下一轮
            match (this.roundState) {
                case RoundState.Running => this.roundState = RoundState.Done
                case _ => ()
            }
            this.roundState = RoundState.Idle
        } finally {
            this.interruptLock.unlock()
        }
    }

    /**
     * 当前回合状态（测试/诊断用）
     */
    public func getRoundState(): RoundState {
        this.interruptLock.lock()
        try {
            return this.roundState
        } finally {
            this.interruptLock.unlock()
        }
    }

    /**
     * 是否已请求中断（agent 循环轮询）
     */
    public func isInterrupted(): Bool {
        this.interruptLock.lock()
        try {
            return this.interruptFlag
        } finally {
            this.interruptLock.unlock()
        }
    }

    /**
     * 登记在跑子代理（中断传播用；spawnSubagent fork 时登记，finally 注销）
     */
    public func registerChild(child: Agent): Unit {
        this.childLock.lock()
        try {
            this.childAgents.add(child)
        } finally {
            this.childLock.unlock()
        }
    }

    /**
     * 注销子代理（按 agentId 匹配；重建列表避免依赖 ArrayList.remove 的重载差异）
     */
    public func unregisterChild(child: Agent): Unit {
        this.childLock.lock()
        try {
            var kept = ArrayList<Agent>()
            for (c in this.childAgents) {
                if (c.agentId != child.agentId) {
                    kept.add(c)
                }
            }
            this.childAgents = kept
        } finally {
            this.childLock.unlock()
        }
    }

    /**
     * 钩子豁免白名单：这些工具的结果不应被 on_tool_result 钩子（log-pruner）裁剪
     * - web_fetch/web_search：结构化抓取正文需完整传给 LLM
     * - read_file：按需读取（offset/limit 控制量），截断导致反复重读
     */
    public static func isHookExempt(toolName: String): Bool {
        return toolName == "web_fetch" || toolName == "web_search" ||
            toolName == "read_file"
    }

    /**
     * 运行时切换 provider（/model 命令；历史保留）
     */
    public func setProvider(p: LlmProvider): Unit {
        this.provider = p
    }

    /**
     * 设置摘要专用快模型（P1-5）：compaction 摘要/子代理摘要走快模型，
     * 降低摘要调用耗时（实测主模型摘要 10-100s）
     */
    public func setSummaryProvider(p: LlmProvider): Unit {
        this.summaryProvider = Some(p)
    }

    /**
     * 获取 provider（子代理派发用）
     */
    public func getProvider(): LlmProvider {
        return this.provider
    }

    /**
     * 获取工具注册表（子代理派发用）
     */
    public func getTools(): ToolRegistry {
        return this.tools
    }

    /**
     * 获取消息历史（子代理结果提取用）
     */
    public func getMessages(): ArrayList<ChatMessage> {
        return this.messages
    }

    /**
     * 触碰文件快照（S7 归账：子代理结束时经 filesTouched 导出给父）
     */
    public func getTouchedFiles(): ArrayList<String> {
        this.touchedLock.lock()
        let out = ArrayList<String>()
        for (f in this.touchedFiles) {
            out.add(f)
        }
        this.touchedLock.unlock()
        return out
    }

    /**
     * 注入插件管理器（V2b Step 2：事件钩子）
     * Agent 在工具结果回填前触发 on_tool_result 钩子，允许插件拦截/改写结果。
     */
    public func setPluginManager(pm: PluginManager): Unit {
        this.pluginManager = pm
    }

    /**
     * 触发 on_tool_result 事件钩子
     * 返回改写后的 content；无钩子或钩子失败时返回原 content
     */
    private func fireToolResultHook(toolName: String, content: String): String {
        // 白名单：这些工具的结果不应被 log-pruner 等钩子裁剪——
        //   web_fetch/web_search：结构化抓取正文需完整传给 LLM 才能总结
        //   read_file：按需读取工具（LLM 已用 offset/limit 控制读取量），
        //     截断会导致 LLM 看到不完整内容、反复小段重读（用户实测：模型
        //     被迫 bash sed 分段读，速度/效率骤降）；与内置截断器对
        //     read_file 不截断（Int64.Max）的设计一致。
        // log-pruner 设计意图是裁剪冗长 bash 日志（>1000 字符截断）。
        if (Agent.isHookExempt(toolName)) {
            return content
        }
        match (this.pluginManager) {
            case Some(pm) =>
                if (!pm.hasHook("on_tool_result")) {
                    return content
                }
                var data = JsonObject()
                data.put("tool", JsonString(toolName))
                data.put("content", JsonString(content))
                let rewritten = pm.fireHook("on_tool_result", data)
                if (rewritten.size > 0) {
                    return rewritten
                }
                return content
            case None => return content
        }
    }

    // ==================== 内置任务管理 ====================

    /**
     * 添加任务，返回新任务 id
     */
    public func addTask(content: String): Int64 {
        let item: TodoItem = TodoItem(this.nextTodoId, content)
        this.nextTodoId += 1
        this.todos.add(item)
        this.onTodosChanged()
        return item.id
    }

    /**
     * 更新任务状态
     */
    public func updateTaskStatus(id: Int64, status: TodoStatus): Unit {
        for (item in this.todos) {
            if (item.id == id) {
                item.status = status
                this.onTodosChanged()
                return
            }
        }
    }

    /**
     * 更新任务内容
     */
    public func updateTaskContent(id: Int64, content: String): Unit {
        for (item in this.todos) {
            if (item.id == id) {
                item.content = content
                this.onTodosChanged()
                return
            }
        }
    }

    /**
     * 获取所有任务（按添加顺序）
     */
    public func getTodos(): ArrayList<TodoItem> {
        return this.todos
    }

    /**
     * 清空任务列表
     */
    public func clearTodos(): Unit {
        this.todos = ArrayList<TodoItem>()
        this.nextTodoId = 1
        this.onTodosChanged()
    }

    /**
     * 追加用户消息并运行，返回回合统计（含最终文本答复 summary.reply）
     */
    public func run(userInput: String): RunSummary {
        // 回合开始：统一重置状态（清除中断残留，状态 Running）
        this.beginRound()
        var summary = RunSummary()
        try {
            summary = this.runLoop(userInput)
        } catch (e: Exception) {
            // 异常出口：状态统一清理由 finally 兜底
            Log.error("Agent.run 顶层异常: ${e}", e)
            summary.rounds = this.roundsCompleted
            summary.reply = "[执行异常: ${e}]"
            // 顶层兜底同样留结构化信号（中断优先由渠道判定 cancelled，不会误报成故障）
            summary.errorCode = "run_failed"
            summary.errorMessage = "执行失败：${e}"
            summary.errorRetryable = true
        } finally {
            // 所有出口（正常/中断/异常）统一清理：状态回 Idle
            this.endRound()
        }
        return summary
    }

    /**
     * 回合主体（原 run 逻辑，多出口 return summary；状态清理由 run() finally 兜底）
     */
    private func runLoop(userInput: String): RunSummary {
        this.messages.add(ChatMessage("user", userInput))

        // 回合统计收集
        let summary = RunSummary()
        let startTime = DateTime.now()
        var iterations: Int64 = 0
        // 空响应重试计数（LLM 返回无 text 且无 tool_calls 时重试，超过 maxEmptyRetries 才退出）
        var emptyRetries: Int64 = 0
        let maxEmptyRetries: Int64 = 3
        // 软顶（wrapUpRounds）：达到 maxIterations 后注入"立即总结收尾"指令，不再硬切——
        // 长任务可在当前工作线程自然收尾；超过 wrapUpRounds 仍未结束才强制停止
        var wrapUpInjected: Bool = false
        let wrapUpRounds: Int64 = 10
        let hardCap: Int64 = this.config.maxIterations + wrapUpRounds
        while (iterations < hardCap) {
            // 软顶注入：达到 maxIterations 时要求模型收尾（不消耗轮次）
            if (iterations >= this.config.maxIterations && !wrapUpInjected) {
                wrapUpInjected = true
                this.messages.add(ChatMessage("user",
                    "[System Notice] 任务已执行 ${this.config.maxIterations} 轮，请立即结束：不要再调用任何工具，直接给出最终总结答复（如任务确未完成，简述剩余步骤）。"))
                this.onAssistantText("\n[System] 已达轮次上限（${this.config.maxIterations}），要求模型收尾总结\n")
            }
            // P0-2：用户 Ctrl+C 中断——轮次间检查，保留已完成工作
            if (this.isInterrupted()) {
                Log.warn("Agent.run 被用户中断（${iterations} 轮后）")
                this.fireHooks(AgentHook.Interrupt, JsonObject())
                this.onAssistantText("\n_[已中断：保留已完成的工作，可继续提问]_")
                let d = (DateTime.now() - startTime).toMilliseconds()
                summary.durationMs = d
                summary.reply = "[已中断：${iterations} 轮已完成]"
                return summary
            }
            iterations += 1
            summary.rounds = iterations
            this.roundsCompleted = iterations

            // 长会话压缩（P1b 后台异步化）：每轮发起 LLM 请求前——
            // 若后台摘要已完成则换装 messages（不阻塞），未完成则顺延；
            // 后台曾失败则本 run 回退同步压缩（行为降级不崩）。
            // 必须放在循环内——单次 run() 可能跑几十轮，prompt 随轮次膨胀，
            // 只在 run() 开头检查的话压缩永远不会触发（实测 48 轮 prompt 涨到 31K token）
            this.checkPendingCompact()

            // 排队输入注入（atomcode 式"steer"）：上一轮工具调用完成、本轮
            // 请求发出前的边界消费 TUI 队列——用户忙时提交的消息不打断当前
            // 回合，在此作为 user 消息让模型在继续执行时感知新指令并可调整计划。
            // 一次性排空队列（多条连发合并进本回合）。放在 checkPendingCompact
            // 之后：避免刚注入的新指令随即被换装成摘要。Esc 中断优先于注入：
            // 排空前再查一次 isInterrupted——中断后剩余队列消息由 TUI 在 run
            // 结束后作为新 turn 发送（"中断并立即发送"，见 TuiApp Esc 分支）。
            if (!this.isInterrupted()) {
                try {
                    // while-let 语法糖：条件每轮重新求值，拉到 Some 就注入，None 退出
                    while (let Some(msg) <- this.onRequestPendingInput()) {
                        this.messages.add(ChatMessage("user", msg))
                        this.onAssistantText("\n[收到排队输入，将在本轮响应中处理]\n")
                    }
                } catch (e: Exception) {
                    Log.warn("排队输入拉取回调异常: ${e}")
                }
            }

            // 顶层兜底：LLM 响应解析可能抛 IllegalArgumentException（非法 UTF-8 字节）
            // 不让它崩 TUI，转成错误消息返回
            // 历史修复（发上游前）：回合被打断会留下孤儿 tool 消息 / 悬空 tool_calls，
            // 上游对配对要求严格，会把整段脏历史判成 400，导致该会话永久不可用。
            // repairHistory 幂等，合法历史零开销。
            let repaired = repairHistory(this.messages)
            if (repaired.fixes > 0) {
                Log.warn("会话历史残缺已修复 ${repaired.fixes} 处（孤儿 tool 消息 / 悬空 tool_calls / 重复结果）")
                this.messages = repaired.messages
            }
            let response: ModelResponse
            let roundStart = DateTime.now()
            let msgCount = Int64(this.messages.size)
            Log.info("=== 第 ${iterations} 轮开始 | 消息数 ${msgCount} | 历史 token ~${summary.promptTokens} ===")
            try {
                this.onThinking()
                response = this.provider.chatStream(this.messages, this.tools.specs(), { delta =>
                    this.onDelta(delta)
                    var p = JsonObject()
                    p.put("delta", JsonString(delta))
                    this.fireHooks(AgentHook.ChatDelta, p)
                }, { r =>
                    this.onReasoning(r)
                    var p = JsonObject()
                    p.put("delta", JsonString(r))
                    this.fireHooks(AgentHook.Reasoning, p)
                }, { est =>
                    this.onTokenEstimate(est)
                }, { => this.isInterrupted() })
            } catch (e: Exception) {
                // 建连/响应头阶段被用户中断（StreamInterruptedException 或 abort 后异常）：
                // 明确标记已中断，而非"LLM 调用异常"
                if (this.isInterrupted()) {
                    Log.warn("Agent.run 请求阶段被中断（第 ${iterations} 轮）: ${e}")
                    this.fireHooks(AgentHook.Interrupt, JsonObject())
                    this.onAssistantText("\n_[已中断：保留已完成的工作，可继续提问]_")
                    let d = (DateTime.now() - startTime).toMilliseconds()
                    summary.durationMs = d
                    summary.reply = "[已中断：${iterations} 轮已完成]"
                    return summary
                }
                Log.error("Agent.run chatStream 异常: ${e}", e)
                summary.reply = "[LLM 调用异常: ${e}]"
                // 结构化失败信号：渠道据此推 error 帧（否则客户端只看到一个空 done，无从判断失败）
                let fail = classifyProviderFailure("${e}")
                summary.errorCode = fail.code
                summary.errorMessage = fail.message
                summary.errorRetryable = fail.retryable
                return summary
            }
            // 流式中被用户中断（Ctrl+C / 空闲看门狗）：立即结束回合，明确标记已中断
            // （原实现只在轮次间检查——流中中断后会把半截回复当正常回复返回，
            //   且中断提示不出现；现在短读轮询保证中断在 ≤5s 内抵达 chatStream 返回）
            if (this.isInterrupted()) {
                Log.warn("Agent.run 流式中被中断（第 ${iterations} 轮）")
                this.fireHooks(AgentHook.Interrupt, JsonObject())
                this.onAssistantText("\n_[已中断：保留已完成的工作，可继续提问]_")
                let d = (DateTime.now() - startTime).toMilliseconds()
                summary.durationMs = d
                summary.reply = "[已中断：${iterations} 轮已完成]"
                return summary
            }
            let roundMs = (DateTime.now() - roundStart).toMilliseconds()
            // 累计 token 用量
            summary.promptTokens += response.usage.promptTokens
            summary.completionTokens += response.usage.completionTokens
            summary.cachedTokens += response.usage.cachedTokens
            // 记录真实 prompt token（压缩触发依据；首轮为 0 时用字符估算兜底）
            this.lastPromptTokens = response.usage.promptTokens
            // P1b：轮末检查阈值——超限且无后台任务在跑 → spawn 后台摘要（不阻塞主循环，
            // 下一轮请求前 checkPendingCompact 换装或顺延）
            this.maybeTriggerBackgroundCompact()
            this.onTokens(response.usage.promptTokens + response.usage.completionTokens)
            // S3 修实测卡死：每轮一次的轮次/用量回调（provider 无关）。此前面板刷新接在
            // onTokenEstimate 上——anthropic 每 SSE chunk 回调一次，长流式下每秒成百次
            // 锁+快照拷贝+全帧置脏，主循环被淹没（界面静止、输入无响应）
            this.onRoundTick(iterations, summary.promptTokens, summary.completionTokens)
            Log.info("第 ${iterations} 轮完成 | 耗时 ${roundMs}ms | prompt ${response.usage.promptTokens} completion ${response.usage.completionTokens} cached ${response.usage.cachedTokens} | toolCalls ${response.toolCalls.size} | textLen ${response.text.size} | truncated ${response.truncated} | timedOut ${response.timedOut}")

            // SSE 空闲超时：网络长时间无新数据，已收文本/tool_calls 保留。
            // 内容已开始输出（text 或 tool_calls 非空）→ 直接按正常回复处理，
            // 不再注入提示重试——代理 keep-alive 不发完成标记时，重试会
            // "卡→重试→又卡"死循环（实测 Streaming 104s+ 排队积压）。
            // 内容保留为回复（可能不完整但实用优先），回合正常结束。
            // 仅当完全无内容时才重试（空响应，重试合理）。
            if (response.timedOut && response.text.size == 0 && response.toolCalls.size == 0) {
                Log.error("SSE 空闲超时且无任何内容，SSE 流被切断")
                this.onAssistantText("\n\n⚠ 网络空闲超时（模型长时间无输出），已收到内容为空。\n")
                this.messages.add(ChatMessage("user", "[System Notice] The previous SSE stream was cut off due to an idle timeout (no new data). Please continue or retry."))
            } else if (response.timedOut) {
                Log.warn("SSE 空闲超时（${this.config.maxIterations} 轮内），已收内容保留为回复（不重试）：textLen=${response.text.size} toolCalls=${response.toolCalls.size}")
                this.onAssistantText("\n\n⚠ 网络空闲超时，已收到的内容已保留（可能不完整）。\n")
            }

            if (response.hasToolCalls()) {
                // 把 assistant 文本（若有）+ 工具调用加入历史（toolCalls 随消息携带，供 Anthropic 回传）
                var asstMsg = ChatMessage("assistant", response.text)
                if (response.toolCalls.size > 0) {
                    asstMsg = ChatMessage("assistant", response.text, response.toolCalls)
                }
                this.messages.add(asstMsg)
                if (response.text.size > 0) {
                    this.onAssistantText(response.text)
                }
                summary.toolCalls += Int64(response.toolCalls.size)
                // V2d 并发执行引擎：DAG 依赖分析 + 拓扑分组调度
                // - 同一 path 且至少一个 write → 串行依赖（避免并发写竞态）
                // - 不同 path → 可并发（即使都是 write）
                // - 无依赖关系的 read-only → 全并发
                // 组内 spawn 并发，组间串行；结果按 LLM 原始顺序回填
                let toolCalls = response.toolCalls
                this.recordTouchedPaths(toolCalls)
                let n = Int64(toolCalls.size)
                let deps = this.buildDependencyGraph(toolCalls)
                let groups = this.topologicalGroups(deps, n)

                // 按拓扑分组执行：组内 spawn 并发，组间串行
                // 结果暂存到 results 数组（按原始索引），全部完成后按原始顺序回填
                var results = ArrayList<ToolResult>()
                for (_ in 0..n) {
                    results.add(ToolResult("", false))
                }
                for (g in 0..groups.size) {
                    let group = groups[g]
                    // 单元素组直接串行执行（避免 spawn 开销）
                    if (group.size == 1) {
                        let i = group[0]
                        let tc = toolCalls[i]
                        this.onToolStart(tc.name, tc.arguments)
                        var preP = JsonObject()
                        preP.put("tool", JsonString(tc.name))
                        preP.put("args", tc.arguments)
                        this.fireHooks(AgentHook.PreToolUse, preP)
                        let toolT0 = DateTime.now()
                        var result = this.executeGuarded(tc.name, tc.arguments)
                        let toolMs = (DateTime.now() - toolT0).toMilliseconds()
                        Log.info("  工具 ${tc.name} | 耗时 ${toolMs}ms | 结果 ${result.content.size} chars | isError ${result.isError}")
                        if (response.truncated && (tc.name == "write_file" || tc.name == "edit_file")) {
                            result = ToolResult(result.content + "\n\n⚠ 截断警告：本轮 LLM 输出被 max_tokens 强制截断，上面写入的文件内容【不完整】。\n请【立即】按以下步骤修复（不要再用 write_file 重写整个文件，那会再次截断）：\n1. 调用 read_file 读取刚写入的文件，确认截断位置\n2. 调用 edit_file，old_string 填文件末尾最后几个有效字符，new_string 续写剩余部分\n3. 重复 1-2 直到文件完整闭合（HTML 需 </script></body></html>）\n务必分多次小段续写，每段 new_string 控制在 ~1500 字符以内。", true)
                        }
                        results[i] = result
                    } else {
                        // 多元素组：spawn 并发执行
                        // V2d 性能基线：记录并发实际耗时 vs 假设串行耗时
                        let batchStart = DateTime.now()
                        var futures = ArrayList<Future<(Int64, ToolResult, Int64)>>()
                        for (k in 0..group.size) {
                            let i = group[k]
                            let tc = toolCalls[i]
                            this.onToolStart(tc.name, tc.arguments)
                            var preP2 = JsonObject()
                            preP2.put("tool", JsonString(tc.name))
                            preP2.put("args", tc.arguments)
                            this.fireHooks(AgentHook.PreToolUse, preP2)
                            let localName = tc.name
                            let localArgs = tc.arguments
                            let localIdx = i
                            futures.add(spawn {
                                let t0 = DateTime.now()
                                let r = this.executeGuarded(localName, localArgs)
                                let dur = (DateTime.now() - t0).toMilliseconds()
                                (localIdx, r, dur)
                            })
                        }
                        // 收集组内结果，累加假设串行耗时
                        var serialMs: Int64 = 0
                        for (k in 0..group.size) {
                            let (idx, result, dur) = futures[k].get()
                            serialMs += dur
                            let tc = toolCalls[idx]
                            Log.info("  工具 ${tc.name} (并发) | 耗时 ${dur}ms | 结果 ${result.content.size} chars | isError ${result.isError}")
                            var r = result
                            if (response.truncated && (tc.name == "write_file" || tc.name == "edit_file")) {
                                r = ToolResult(r.content + "\n\n⚠ 截断警告：本轮 LLM 输出被 max_tokens 强制截断，上面写入的文件内容【不完整】。\n请【立即】按以下步骤修复（不要再用 write_file 重写整个文件，那会再次截断）：\n1. 调用 read_file 读取刚写入的文件，确认截断位置\n2. 调用 edit_file，old_string 填文件末尾最后几个有效字符，new_string 续写剩余部分\n3. 重复 1-2 直到文件完整闭合（HTML 需 </script></body></html>）\n务必分多次小段续写，每段 new_string 控制在 ~1500 字符以内。", true)
                            }
                            results[idx] = r
                        }
                        // 并发实际耗时
                        let parallelMs = (DateTime.now() - batchStart).toMilliseconds()
                        // 节省 = 假设串行 - 并发实际
                        if (serialMs > parallelMs) {
                            summary.parallelSavedMs += (serialMs - parallelMs)
                        }
                        summary.parallelBatches += 1
                        if (Int64(group.size) > summary.maxParallelism) {
                            summary.maxParallelism = Int64(group.size)
                        }
                    }
                }

                // 按原始顺序回填结果到消息历史
                for (i in 0..n) {
                    let tc = toolCalls[i]
                    let result = results[i]
                    this.onToolResult(tc.name, result)
                    var postP = JsonObject()
                    postP.put("tool", JsonString(tc.name))
                    var resObj = JsonObject()
                    resObj.put("content", JsonString(result.content))
                    resObj.put("is_error", JsonBool(result.isError))
                    postP.put("result", resObj)
                    this.fireHooks(AgentHook.PostToolUse, postP)
                    let hookedContent = this.fireToolResultHook(tc.name, result.content)
                    this.messages.add(ChatMessage("tool", truncateToolResult(hookedContent, tc.name, tc.id), tc.id, tc.name))
                }

                // 截断打断：检测到被截断的 write_file/edit_file 路径，注入 [System Notice] 绝对指令
                if (response.truncatedPaths.size > 0) {
                    var notice = "\n[System Notice - ABSOLUTE DIRECTIVE, MUST EXECUTE]\n"
                    notice += "The previous write_file was truncated by the model's max_tokens. The file has been saved to disk but is INCOMPLETE.\n"
                    notice += "Truncated files:\n"
                    for (i in 0..response.truncatedPaths.size) {
                        notice += "  - ${response.truncatedPaths[i]}\n"
                    }
                    notice += "\n[FORBIDDEN] Absolutely DO NOT call write_file again to rewrite these files -- it will truncate again and fall into an infinite loop.\n"
                    notice += "[MANDATORY] For each truncated file, execute immediately:\n"
                    notice += "  1. read_file <path> to confirm the current end of the file\n"
                    notice += "  2. append_file <path> \"<next chunk of remaining content>\" (each chunk <= 1500 chars)\n"
                    notice += "  3. Repeat step 2; the final chunk MUST append the closing tags </script></body></html>\n"
                    notice += "  4. read_file <path> to verify the file is complete and properly closed\n"
                    notice += "Do NOT perform any other action until the above steps are complete."
                    this.messages.add(ChatMessage("user", notice))
                    this.onAssistantText("\n[System] Truncation detected, forced continuation directive injected\n")
                }
                // tool 执行完毕，回到 while 顶部发起下一轮 LLM 请求
                // （让 LLM 看到 tool result 后继续总结/调用）
                continue
            }

            // 纯文本答复（无 tool 调用分支才会走到这里）
            if (response.text.size > 0) {
                this.messages.add(ChatMessage("assistant", response.text))
                this.onAssistantText(response.text)
            } else {
                // LLM 返回空响应（无 text 且无 tool_calls）：重试，超过 maxEmptyRetries 才退出
                emptyRetries += 1
                if (emptyRetries <= maxEmptyRetries) {
                    Log.warn("LLM 返回空响应，重试 ${emptyRetries}/${maxEmptyRetries}")
                    this.messages.add(ChatMessage("user",
                        "[System Notice] Your previous response was empty (no text and no tool calls). " +
                        "Please continue the task and provide a response."))
                    // 不消耗 iterations，回 while 顶部重试
                    iterations -= 1
                    continue
                }
                Log.error("LLM 连续 ${maxEmptyRetries} 次返回空响应，放弃重试")
                this.onAssistantText("\n[空响应] LLM 连续 ${maxEmptyRetries} 次未返回内容，回合结束。")
            }
            // 回合结束：计算耗时，回填 reply，返回 summary（onRunComplete 由调用方在 setAgentRunning(false) 后触发）
            let durationMs = (DateTime.now() - startTime).toMilliseconds()
            summary.durationMs = durationMs
            summary.reply = response.text
            // 只在真的被上游截断时置位：其余终局路径（中断 / 异常 / 硬顶）都不许虚报截断
            summary.truncated = response.truncated
            // Stop 事件钩子广播（回合正常完成）
            var stopP = JsonObject()
            stopP.put("rounds", JsonInt(iterations))
            stopP.put("toolCalls", JsonInt(summary.toolCalls))
            stopP.put("durationMs", JsonInt(durationMs))
            stopP.put("reply", JsonString(summary.reply))
            this.fireHooks(AgentHook.Stop, stopP)
            // 正常退出也记日志，方便排查"意外停止"——区分 LLM 主动结束 vs 异常
            // 用 warn 级别确保写入 error.log（info 级别默认 NoopLogger）
            Log.warn("Agent.run 正常结束: ${iterations} rounds, ${summary.toolCalls} tools, ${durationMs}ms")
            return summary
        }
        // 超过软顶 + wrapUpRounds 仍未收尾：强制结束（保留已完成工作）
        Log.warn("已达硬顶 ${hardCap} 轮（软顶 ${this.config.maxIterations} + ${wrapUpRounds}）仍未收尾，强制结束回合")
        let durationMsMax = (DateTime.now() - startTime).toMilliseconds()
        summary.durationMs = durationMsMax
        summary.reply = "[已达最大迭代次数 ${hardCap}]"
        // 给 TUI 上文字提示，而非静默退出
        this.onAssistantText("\n⚠ 已达最大迭代次数 ${hardCap}，回合强制结束。如需继续，请重新提问。")
        return summary
    }

    /**
     * Compaction：消息历史超过阈值时，用 LLM 把早期消息压缩成摘要，
     * 保留最近 compactKeep 条（含 system）。对齐 pi 的自动摘要压缩：
     * 触发后调用链 = 摘要请求（无工具）→ 重建 messages = system + 摘要 + 近期历史
     *
     * 手动路径（/compact，独立线程 spawn 调用）保持同步 + compactLock 保护，
     * 与 P1b 主循环后台异步路径（maybeTriggerBackgroundCompact + checkPendingCompact）
     * 共享 compactLock 保证 messages 快照/换装的跨线程一致性。
     *
     * 返回值：(是否执行了压缩, 压缩前消息数, 压缩后消息数)。
     * force=true 时无视阈值强制压缩（/compact 手动命令）。
     */
    public func compact(force: Bool): (Bool, Int64, Int64) {
        let before: Int64 = this.messages.size
        if (force) {
            // 强制压缩：跳过阈值判断，但仍保留 system + 最近 keep 条
            this.doCompact()
        } else {
            this.maybeCompact()
        }
        let after: Int64 = this.messages.size
        return (after < before, before, after)
    }

    /**
     * 实际执行压缩（force 路径）：无阈值判断，keep 至少 2 条
     */
    private func doCompact(): Unit {
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        if (this.messages.size <= keep + 1) {
            // 历史 + system 不足，无需压缩
            return
        }
        this.maybeCompactForce(keep)
    }

    /**
     * 强制压缩实现（复用 maybeCompact 的摘要请求逻辑）
     */
    private func maybeCompactForce(keep: Int64): Unit {
        let compactEnd = this.messages.size - keep
        if (compactEnd <= 1) {
            return
        }
        var sb = StringBuilder()
        sb.append("请把以下对话历史压缩成一段简洁的中文摘要（保留：任务目标、已完成的工具调用与关键结果、当前进度、尚未解决的问题）。不要遗漏重要事实。")
        for (i in 1..compactEnd) {
            let m = this.messages[i]
            sb.append("\n[${m.role}] ${m.content}")
        }
        var summaryMsgs = ArrayList<ChatMessage>()
        summaryMsgs.add(ChatMessage("user", sb.toString()))
        var summary = ""
        try {
            let resp = this.provider.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => }, { _ => }, { => false })
            summary = resp.text
        } catch (e: Exception) {
            return
        }
        if (summary.size == 0) {
            return
        }
        var newMsgs = ArrayList<ChatMessage>()
        if (this.messages.size > 0) {
            newMsgs.add(this.messages[0])
        }
        newMsgs.add(ChatMessage("user", "[历史摘要] ${summary}"))
        for (i in compactEnd..this.messages.size) {
            newMsgs.add(this.messages[i])
        }
        // P1b：换装持 compactLock——手动 /compact 在独立线程调用，与主循环后台
        // 摘要任务的快照/换装共享 messages，锁串行化换装语句保证不交错写坏
        this.compactLock.lock()
        try {
            this.messages = newMsgs
        } finally {
            this.compactLock.unlock()
        }
        this.onDelta("\n\n_[会话历史已手动压缩：${compactEnd - 1} 条早期消息 → 摘要]_")
    }

    /**
     * Tool Output 压缩 Hook（逻辑在 ToolResultTruncator，含落盘回溯钥匙）
     */
    private func truncateToolResult(content: String, toolName: String, toolCallId: String): String {
        return ToolResultTruncator.truncate(content, toolName, this.config.toolResultMaxChars,
            this.config.spillDir, this.config.sessionId, toolCallId)
    }

    /**
     * 消息历史 token 粗估：content 字符数 / 4 + 每条消息固定开销。
     * 中文单字≈1 token、英文≈4 字符/token，混合内容按 /4 是保守下界，
     * 用于压缩触发判断（无需精确，只需量级正确）。
     */
    private func estimateMessagesTokens(): Int64 {
        var total: Int64 = 0
        for (m in this.messages) {
            total += m.content.size / 4 + 8  // +8 近似 role/name/tool_call_id 开销
        }
        return total
    }

    /**
     * Compaction（同步路径，P1b 保留）：消息历史超过阈值时，用 LLM 把早期消息压缩成摘要，
     * 保留最近 compactKeep 条（含 system）。对齐 pi 的自动摘要压缩：
     * 触发后调用链 = 摘要请求（无工具）→ 重建 messages = system + 摘要 + 近期历史
     *
     * 供 compact(false) 手动路径使用（/compact 之外的非强制入口）；主循环自动压缩
     * 走 P1b 后台异步路径（maybeTriggerBackgroundCompact + checkPendingCompact）。
     */
    private func maybeCompact(): Unit {
        if (this.config.compactThreshold <= 0 && this.config.compactTokenThreshold <= 0) {
            return
        }
        // 双阈值触发判断（任一超限即压缩），与后台路径共用同一判定
        if (!this.compactionOverThreshold()) {
            return
        }
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        if (this.messages.size - keep <= 1) {
            return
        }
        let req = this.buildSummaryRequest(keep)
        let summary = this.requestSummary(req[2])
        if (summary.size == 0) {
            return
        }
        this.applySummary(summary, req)
    }

    /**
     * 双阈值触发判断（消息条数 或 token 任一超限）。
     * token 触发优先用上一轮 provider 返回的真实 prompt token（精确）；
     * 首轮前无测量时退化为字符估算（/4，保守）。
     */
    private func compactionOverThreshold(): Bool {
        let msgCount: Int64 = this.messages.size
        let overCount: Bool = this.config.compactThreshold > 0 && msgCount > this.config.compactThreshold
        let triggerTokens = if (this.lastPromptTokens > 0) { this.lastPromptTokens } else { this.estimateMessagesTokens() }
        let overTokens: Bool = this.config.compactTokenThreshold > 0 && triggerTokens > this.config.compactTokenThreshold
        return overCount || overTokens
    }

    /**
     * 构造摘要请求（P1-8）：assistant 纯文本进摘要，tool_call/tool_result 保留原文。
     * 避免摘要丢失工具结果细节导致压缩后 agent"失忆"。
     * 返回 (compactEnd, kept 工具链消息, 摘要请求消息)。
     */
    private func buildSummaryRequest(keep: Int64): (Int64, ArrayList<ChatMessage>, ArrayList<ChatMessage>) {
        let compactEnd = this.messages.size - keep
        var kept = ArrayList<ChatMessage>()
        var sb = StringBuilder()
        sb.append("请把以下对话历史压缩成一段简洁的中文摘要（保留：任务目标、已完成的关键操作与结果、当前进度、尚未解决的问题）。不要遗漏重要事实。")
        for (i in 1..compactEnd) {
            let m = this.messages[i]
            if (m.role == "tool" || m.toolCalls.size > 0) {
                // 工具调用/结果消息：保留原文（信息完整性）
                kept.add(m)
            } else {
                // assistant 文本 / 用户指令：进摘要
                sb.append("\n[${m.role}] ${m.content}")
            }
        }
        var summaryMsgs = ArrayList<ChatMessage>()
        summaryMsgs.add(ChatMessage("user", sb.toString()))
        return (compactEnd, kept, summaryMsgs)
    }

    /**
     * 摘要请求（无工具）：P1-5 摘要走快模型（配置了 summary 时）。
     * 失败或空摘要返回 ""（调用方保持原历史）。
     */
    private func requestSummary(summaryMsgs: ArrayList<ChatMessage>): String {
        let sp = if (this.summaryProvider.isSome()) { this.summaryProvider.getOrThrow() } else { this.provider }
        try {
            let resp = sp.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => }, { _ => }, { => false })
            return resp.text
        } catch (e: Exception) {
            Log.warn("compaction 摘要请求失败: ${e}")
            return ""
        }
    }

    /**
     * 应用摘要（换装 messages）：system + 摘要 + 保留的工具链消息 + 最近 keep 条。
     * 在 compactLock 内执行，与后台任务的"快照→换装"互斥，避免换装旧列表。
     */
    private func applySummary(summary: String, req: (Int64, ArrayList<ChatMessage>, ArrayList<ChatMessage>)): Unit {
        let compactEnd = req[0]
        let kept = req[1]
        this.compactLock.lock()
        try {
            // 重建历史：system + 摘要 + 保留的工具链消息 + 最近 keep 条
            var newMsgs = ArrayList<ChatMessage>()
            if (this.messages.size > 0) {
                newMsgs.add(this.messages[0])  // system
            }
            newMsgs.add(ChatMessage("user", "[历史摘要] ${summary}"))
            for (m in kept) {
                newMsgs.add(m)
            }
            for (i in compactEnd..this.messages.size) {
                newMsgs.add(this.messages[i])
            }
            this.messages = newMsgs
            // 重置真实 prompt token 记录：压缩后旧测量值已失真（>阈值），
            // 不重置会导致下一轮基于陈旧值再次压缩（churn）
            this.lastPromptTokens = 0
        } finally {
            this.compactLock.unlock()
        }
        this.onDelta("\n\n_[会话历史已自动压缩：${compactEnd - 1} 条早期消息 → 摘要]_")
    }

    // ==================== P1b：compaction 后台异步化 ====================
    //
    // 主循环每轮结束检查真实 prompt token（lastPromptTokens），超阈值即后台 spawn
    // 摘要任务（读 messages 快照生成摘要，不阻塞主循环）；下一轮 LLM 请求前
    // tryGet 检查：已完成则换装 messages（主线程独占写，compactLock 守护），
    // 未完成则顺延（当前轮照常跑）；后台失败静默重试一次，再失败回退同步路径
    // （本 run 内 autoCompactMode 置 SyncFallback，后续按同步压缩，行为降级不崩）。

    /**
     * P1b：查询当前自动压缩模式（测试观测用）。
     * "None"=未触发；"Async"=后台摘要在跑；"AsyncApplied"=后台摘要已完成换装
     * （run 同步结束时后台必已完成，pending 已清，终态为 AsyncApplied）；
     * "SyncFallback"=后台曾失败已回退同步。
     */
    public func getCompactionMode(): String {
        if (this.pendingCompact.isSome()) {
            return "Async"
        }
        if (this.compactAppliedOnce) {
            return "AsyncApplied"
        }
        return this.autoCompactMode
    }

    /**
     * P1b：轮末触发后台摘要（不阻塞）。
     * 超阈值 且 无后台任务在跑 且 未处于同步回退模式 → spawn 摘要任务。
     * 触发点在主循环 lastPromptTokens 回填后、assistant 消息入历史前，
     * 快照边界 = 截至上一轮末尾的历史（干净，不含本轮响应）。
     */
    private func maybeTriggerBackgroundCompact(): Unit {
        if (this.config.compactThreshold <= 0 && this.config.compactTokenThreshold <= 0) {
            return
        }
        if (this.autoCompactMode == "SyncFallback") {
            return
        }
        if (this.pendingCompact.isSome()) {
            return
        }
        if (!this.compactionOverThreshold()) {
            return
        }
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        if (this.messages.size - keep <= 1) {
            return
        }
        // 在锁内取快照（快照必须与换装互斥：换装改 this.messages，
        // 快照读 this.messages，两者需串行以避免读到换装后的列表）。
        // 拷贝独立列表（非引用别名）：spawn 闭包只持有快照副本，
        // 主线程后续换装/增长 messages 不影响摘要输入
        var snapMsgs = ArrayList<ChatMessage>()
        this.compactLock.lock()
        try {
            let built = this.buildSummaryRequest(keep)
            for (m in built[2]) {
                snapMsgs.add(m)
            }
        } finally {
            this.compactLock.unlock()
        }
        // let 接住不可变快照（spawn 闭包只能捕获不可量：快照列表此刻起不再变化）
        let snapSummaryMsgs = snapMsgs
        // spawn 摘要任务：读快照生成摘要（失败静默重试一次，返回 ""=失败）
        this.compactTriggeredOnce = true
        this.pendingCompact = Some(spawn {
            let sp = if (this.summaryProvider.isSome()) { this.summaryProvider.getOrThrow() } else { this.provider }
            var result = ""
            for (attempt in 0..2) {
                try {
                    let resp = sp.chatStream(snapSummaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => }, { _ => }, { => false })
                    result = resp.text
                    if (result.size > 0) {
                        break
                    }
                } catch (e: Exception) {
                    Log.warn("compaction 后台摘要失败（第 ${attempt + 1} 次）: ${e}")
                }
            }
            result
        })
        Log.info("compaction 后台摘要已触发（pending）")
    }

    /**
     * P1b：每轮 LLM 请求前检查后台摘要任务。
     * 已完成（tryGet 非 None）→ 换装 messages（成功置 AsyncApplied，失败回退同步）；
     * 未完成（None）→ 顺延，当前轮照常跑。
     * 换装时按【当前】size 重算 compactEnd 与 kept：触发到换装之间历史已增长，
     * 用触发时的旧边界会丢消息；kept 重算则与摘要内容自然衔接不重复。
     */
    private func checkPendingCompact(): Unit {
        if (this.pendingCompact.isNone()) {
            return
        }
        let fut = this.pendingCompact.getOrThrow()
        let res = fut.tryGet()
        if (res.isNone()) {
            // 未完成 → 顺延
            return
        }
        let summary = res.getOrThrow()
        this.pendingCompact = None
        if (summary.size == 0) {
            // 后台两次都失败 → 回退同步路径（本 run 内按同步压缩，行为降级不崩）
            Log.warn("compaction 后台摘要失败，本 run 回退同步压缩")
            this.autoCompactMode = "SyncFallback"
            this.maybeCompact()
            return
        }
        // 成功 → 换装（主线程独占写，锁守护快照/换装互斥）
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        let compactEnd = this.messages.size - keep
        if (compactEnd <= 1) {
            // 当前历史不足（极端：run 期间被清空），丢弃摘要
            return
        }
        this.compactLock.lock()
        try {
            var newMsgs = ArrayList<ChatMessage>()
            if (this.messages.size > 0) {
                newMsgs.add(this.messages[0])  // system
            }
            newMsgs.add(ChatMessage("user", "[历史摘要] ${summary}"))
            // kept 工具链消息（与同步路径同规则）：1..compactEnd 内的工具调用/结果保留原文
            for (i in 1..compactEnd) {
                let m = this.messages[i]
                if (m.role == "tool" || m.toolCalls.size > 0) {
                    newMsgs.add(m)
                }
            }
            for (i in compactEnd..this.messages.size) {
                newMsgs.add(this.messages[i])
            }
            this.messages = newMsgs
            // 重置真实 prompt token 记录：压缩后旧测量值已失真（>阈值），
            // 不重置会导致下一轮基于陈旧值再次压缩（churn）
            this.lastPromptTokens = 0
        } finally {
            this.compactLock.unlock()
        }
        this.compactAppliedOnce = true
        this.onDelta("\n\n_[会话历史已后台自动压缩：${compactEnd - 1} 条早期消息 → 摘要]_")
        Log.info("compaction 后台摘要完成，已换装（${compactEnd} 条 → 摘要）")
    }

    /**
     * V2d 并发执行引擎：判断一批 tool_calls 是否全部 read-only
     * 全 read-only → 可并发执行；含 state-modifying → 整批串行
     */

    /**
     * V2d DAG 依赖分析：从 ToolCall 提取资源访问 (path, isWrite)
     *
     * 资源识别规则（对齐 builtin.cj 工具参数）：
     *   - read_file/grep/list_dir → path, read
     *   - write_file/append_file/edit_file → path, write
     *   - bash → command, write（保守：bash 可能改任意状态）
     *   - 其他工具 → "", write（保守：未知工具当写处理）
     *
     * @return (resourcePath, isWrite)；path 为空表示无文件资源
     */
    private func extractResourceAccess(tc: ToolCall): (String, Bool) {
        let accesses = this.extractResourceAccesses(tc)
        if (accesses.size == 0) {
            return ("", false)  // explore task：无边无资源
        }
        return accesses[0]
    }

    /**
     * S6：多资源版资源提取。task 工具的 scope（逗号分隔 glob）每项一条写边；
     * 无 scope 的 worker 返回哨兵 ("**", true)——与所有 writer 串行（保守，防静默覆盖）。
     */
    internal func extractResourceAccesses(tc: ToolCall): ArrayList<(String, Bool)> {
        let out = ArrayList<(String, Bool)>()
        if (tc.name == "task") {
            // explore 只读：不产生写冲突，不建边（否则两路 explore 会被写哨兵串行化，
            // 并发审批/并发调查全部失效——pty 4b 回归根因）
            var isWorker = true
            match (tc.arguments.get("subagent_type")) {
                case Some(t) => isWorker = t.asString().getValue() == "worker"
                case None => ()
            }
            if (!isWorker) {
                return out
            }
            match (tc.arguments.get("scope")) {
                case Some(s) =>
                    let scopeStr = s.asString().getValue()
                    var hasScope = false
                    for (raw in scopeStr.split(",", -1)) {
                        let g = raw.trimAscii()
                        if (g.size > 0) {
                            out.add((g, true))
                            hasScope = true
                        }
                    }
                    if (!hasScope) {
                        out.add(("**", true))
                    }
                case None => out.add(("**", true))
            }
            return out
        }
        match (tc.name) {
            case "read_file" | "grep" | "list_dir" | "glob" =>
                match (tc.arguments.get("path")) {
                    case Some(p) => out.add((p.asString().getValue(), false))
                    case None => out.add(("", false))
                }
            case "write_file" | "append_file" | "edit_file" | "hashline_edit" =>
                match (tc.arguments.get("path")) {
                    case Some(p) => out.add((p.asString().getValue(), true))
                    case None => out.add(("", true))
                }
            case "bash" =>
                match (tc.arguments.get("command")) {
                    case Some(c) => out.add((c.asString().getValue(), true))
                    case None => out.add(("", true))
                }
            case _ =>
                out.add(("", true))
        }
        return out
    }

    /**
     * V2d DAG 依赖分析：构建工具调用之间的依赖图
     *
     * 依赖规则（文件资源级别）：
     *   - 同一 path 且至少一个 isWrite → 必须串行（写→读、写→写、读→写）
     *   - 不同 path → 可并发
     *   - bash 工具的 command 当 path 处理（不同 bash 命令可并发）
     *
     * @return deps[i] = 依赖 i 的工具调用索引列表（i 必须在 deps[i] 之后执行）
     */
    internal func buildDependencyGraph(toolCalls: ArrayList<ToolCall>): ArrayList<ArrayList<Int64>> {
        let n = toolCalls.size
        // deps[i] = i 依赖的工具调用索引列表（这些必须先完成，i 才能开始）
        var deps = ArrayList<ArrayList<Int64>>()
        for (_ in 0..n) {
            deps.add(ArrayList<Int64>())
        }

        // 提取每个工具调用的资源访问（S6：多资源——task 的 scope 每项一条）
        var accesses = ArrayList<ArrayList<(String, Bool)>>()
        for (_ in 0..n) {
            accesses.add(ArrayList<(String, Bool)>())
        }
        for (i in 0..n) {
            accesses[i] = this.extractResourceAccesses(toolCalls[i])
        }

        // 构建依赖边：i/j 存在共同资源键且至少一方是写 → 串行依赖。
        // task 无 scope 的哨兵 "**" 使无写域 worker 与所有 writer 串行（保守防静默覆盖）
        for (i in 0..n) {
            if (accesses[i].size == 0) {
                continue
            }
            for (j in 0..n) {
                if (i == j) {
                    continue
                }
                if (accesses[j].size == 0) {
                    continue
                }
                var conflict = false
                for ((pathI, writeI) in accesses[i]) {
                    if (pathI.size == 0) {
                        continue
                    }
                    for ((pathJ, writeJ) in accesses[j]) {
                        if (pathJ.size == 0) {
                            continue
                        }
                        // 哨兵 "**"：无 scope 的写任务与任何带资源的调用串行（保守防静默覆盖）
                        if ((pathI == "**" && writeI) || (pathJ == "**" && writeJ)) {
                            conflict = true
                            break
                        }
                        if (pathI == pathJ && (writeI || writeJ)) {
                            conflict = true
                            break
                        }
                    }
                    if (conflict) {
                        break
                    }
                }
                if (conflict && j < i) {
                    // 保留 LLM 原始顺序：j < i 时 i 依赖 j
                    deps[i].add(Int64(j))
                }
            }
        }
        return deps
    }

    /**
     * V2d DAG 拓扑排序：按依赖关系分组执行
     *
     * 同一组的工具调用可并发执行；下一组必须等当前组全部完成。
     * 组内顺序保持 LLM 原始顺序（结果回填顺序）。
     *
     * @return 每组包含可并发执行的工具调用索引
     */
    private func topologicalGroups(deps: ArrayList<ArrayList<Int64>>,
        n: Int64): ArrayList<ArrayList<Int64>> {
        // 入度：依赖的工具调用数量
        var inDegree = ArrayList<Int64>()
        for (_ in 0..n) {
            inDegree.add(0)
        }
        for (i in 0..n) {
            inDegree[i] = Int64(deps[i].size)
        }

        var groups = ArrayList<ArrayList<Int64>>()
        var completed = HashSet<Int64>()  // 已完成的工具调用索引

        // 迭代：每轮找入度为 0 的节点（无未完成依赖）作为一组
        var remaining = n
        while (remaining > 0) {
            var group = ArrayList<Int64>()
            for (i in 0..n) {
                if (completed.contains(Int64(i))) {
                    continue
                }
                // 检查所有依赖是否已完成
                var allDepsDone = true
                for (d in deps[i]) {
                    if (!completed.contains(d)) {
                        allDepsDone = false
                        break
                    }
                }
                if (allDepsDone) {
                    group.add(Int64(i))
                }
            }
            if (group.size == 0) {
                break  // 无可执行节点（可能有环），退出
            }
            groups.add(group)
            for (idx in group) {
                completed.add(idx)
                remaining -= 1
            }
        }
        return groups
    }

    /**
     * 带安全护栏的工具执行：
     * 1. 工具域检查（白名单/拒绝/审批）
     * 2. bash 命令域检查（命令白名单 + 危险命令黑名单）
     * 3. 文件资源域检查（fs glob 白名单/排除，write 区分读写）
     * 未配置 capability 时（宽松模式）全部放行，行为与旧版一致
     */
    private func executeGuarded(name: String, args: JsonObject): ToolResult {
        let cap = this.config.capability
        // 1. 工具域
        match (cap.checkTool(name)) {
            case CapDecision.Allow => ()
            case CapDecision.Deny(reason) =>
                return ToolResult("被安全策略拒绝: ${reason}", true)
            case CapDecision.NeedApproval(reason) =>
                if (!this.onApproval(name, args, reason)) {
                    return ToolResult("操作被用户拒绝（${reason}）", true)
                }
        }
        // 2/3. 命令域 + 资源域（按工具类型检查参数）
        let cmd = args.get("command")
        if (cmd.isSome() && name == "bash") {
            let c = cmd.getOrThrow().asString().getValue()
            match (cap.checkCommand(c)) {
                case CapDecision.Allow => ()
                case CapDecision.Deny(reason) =>
                    return ToolResult("被安全策略拒绝: ${reason}", true)
                case CapDecision.NeedApproval(reason) =>
                    if (!this.onApproval(name, args, reason)) {
                        return ToolResult("操作被用户拒绝（${reason}）", true)
                    }
            }
        }
        let path = args.get("path")
        // 资源域检查覆盖全部带 path 参数的工具：
        // 读：read_file/grep/list_dir/glob；写：write_file/append_file/edit_file/hashline_edit
        // （原实现漏掉 append_file/edit_file/hashline_edit/glob，写文件只按读检查——安全缺口）
        if (path.isSome() && (name == "read_file" || name == "write_file" || name == "grep" ||
            name == "list_dir" || name == "glob" || name == "append_file" ||
            name == "edit_file" || name == "hashline_edit")) {
            let p = path.getOrThrow().asString().getValue()
            let isWrite = (name == "write_file" || name == "append_file" ||
                name == "edit_file" || name == "hashline_edit")
            match (cap.checkPath(p, isWrite)) {
                case CapDecision.Allow => ()
                case CapDecision.Deny(reason) =>
                    return ToolResult("被安全策略拒绝: ${reason}", true)
                case CapDecision.NeedApproval(reason) =>
                    if (!this.onApproval(name, args, reason)) {
                        return ToolResult("操作被用户拒绝（${reason}）", true)
                    }
            }
            // S6：writeScope 收窄（AND 语义：capability 放行后仍须落在写域内；空=不限）。
            // 只收窄、绝不放宽——红线：不触碰 Capability 默认宽松语义
            if (isWrite) {
                let ws = this.config.writeScope
                if (ws.size > 0) {
                    var inScope = false
                    for (g in ws) {
                        if (Capability.globMatch(g, p)) {
                            inScope = true
                            break
                        }
                    }
                    if (!inScope) {
                        var scopeStr = StringBuilder()
                        for (g in ws) {
                            scopeStr.append(g)
                            scopeStr.append(" ")
                        }
                        return ToolResult(
                            "超出本子代理写域 (scope: ${scopeStr.toString()}): ${p}。请只在给定写域内修改。",
                            true)
                    }
                }
            }
        }
        // 全部通过：正常执行（兜底异常，避免单工具崩溃带垮整个 Agent 循环）
        try {
            return this.tools.execute(name, args)
        } catch (e: Exception) {
            return ToolResult("工具执行异常: ${e}", true)
        }
    }

    /**
     * 生成项目记忆摘要（P1-6，Hindsight 式）：
     * 从消息历史提取结构化关键信息（最后任务/结果/涉及文件/工具统计），
     * 无 LLM 调用（快），供跨会话注入。
     */
    public func summarizeForMemory(): String {
        return this.summarizeFrom(this.messages)
    }

    /**
     * 任务简报上下文块（方案 §5 / 决策 D1）：触碰文件表 + 会话摘要。
     * spawnSubagent fork 子代理时调用——子代理不共享父历史，靠此块显式传递上下文。
     */
    public func taskBriefContext(): String {
        // 后台摘要任务可能正在换装 messages（compactLock 保护）：锁内重取引用，
        // 保证拿到的是换装前/后完整列表之一（旧列表换装后冻结不再追加）
        var msgs = this.messages
        this.compactLock.lock()
        try {
            msgs = this.messages
        } finally {
            this.compactLock.unlock()
        }
        var sb = StringBuilder()
        sb.append("--- 父会话上下文（父代理自动附带）---\n")
        this.touchedLock.lock()
        try {
            if (this.touchedFiles.size > 0) {
                sb.append("- 本会话已触碰文件:")
                var first = true
                var n: Int64 = 0
                for (f in this.touchedFiles) {
                    if (n >= 8) {
                        break
                    }
                    if (!first) {
                        sb.append(",")
                    }
                    sb.append(" ${f}")
                    first = false
                    n += 1
                }
                sb.append("\n")
            }
        } finally {
            this.touchedLock.unlock()
        }
        sb.append("- 会话摘要:\n")
        let mem = this.summarizeFrom(msgs)
        // 简报整体上限 ~1500 字符：防止上下文块本身成为新的 token 爆点（方案 §5）
        sb.append(if (mem.size > 1500) { truncateUtf8(mem, 1500) + "…" } else { mem })
        return sb.toString()
    }

    /**
     * 记录本会话触碰的文件路径（复用 V2d DAG 资源提取；供子代理简报）
     */
    private func recordTouchedPaths(toolCalls: ArrayList<ToolCall>): Unit {
        this.touchedLock.lock()
        try {
            for (tc in toolCalls) {
                let (path, _) = this.extractResourceAccess(tc)
                if (path.size > 0) {
                    this.touchedFiles.add(path)
                }
            }
        } finally {
            this.touchedLock.unlock()
        }
    }

    /**
     * 摘要主体（对传入快照提取；summarizeForMemory 与子代理简报共用）
     */
    private func summarizeFrom(msgs: ArrayList<ChatMessage>): String {
        var task = ""
        var files = HashSet<String>()
        var toolCount: Int64 = 0
        var lastReply = ""
        for (m in msgs) {
            if (m.role == "user" && task.size == 0) {
                task = m.content
            }
            if (m.role == "tool") {
                toolCount += 1
                // 从工具消息内容提取路径（read/write/edit 结果含路径或内容）
                if (m.name == "read_file" || m.name == "write_file" || m.name == "edit_file" ||
                    m.name == "append_file" || m.name == "hashline_edit" || m.name == "grep" || m.name == "glob") {
                    // 常见格式："Written <path> ..." / "<path>:<line>: ..." / "=== <path> ==="
                    let c = m.content
                    var i: Int64 = 0
                    while (i < c.size) {
                        // 提取 / 开头的路径片段（简化启发式）
                        if (c[i] == 47u8) {  // '/'
                            var j = i
                            var path = StringBuilder()
                            while (j < c.size && c[j] != 32u8 && c[j] != 10u8 && c[j] != 58u8 && c[j] != 41u8 && path.toString().size < 120) {
                                path.append(String(Rune(c[j])))
                                j += 1
                            }
                            let p = path.toString()
                            if (p.size > 4 && (p.contains(".") || p.contains("/"))) {
                                files.add(p)
                            }
                            i = j
                        } else {
                            i += 1
                        }
                    }
                }
            }
            if (m.role == "assistant" && m.content.size > 0) {
                lastReply = m.content
            }
        }
        var sb = StringBuilder()
        sb.append("- 最后任务: ")
        // truncateUtf8：仓颉 String 按字节切片且校验 UTF-8 边界，task[0..60] 在中文（3 字节/字）
        // 密集内容上切点 60 落在字符中间会抛 IllegalArgumentException: Invalid utf8 byte sequence。
        // 该调用在 TUI spawn 收尾路径（entries.cj）且历史上位于 try 之外，未捕获异常会静默杀死
        // 收尾线程 → setAgentRunning(false) 永不执行 → TUI 僵尸"Streaming…"态、排队永不发送。
        sb.append(if (task.size > 60) { truncateUtf8(task, 60) + "…" } else { task })
        sb.append("\n")
        sb.append("- 工具调用: ${toolCount} 次\n")
        if (files.size > 0) {
            sb.append("- 涉及文件:")
            var first: Bool = true
            var n: Int64 = 0
            for (f in files) {
                if (n >= 8) {
                    break
                }
                if (!first) {
                    sb.append(",")
                }
                sb.append(" ${f}")
                first = false
                n += 1
            }
            sb.append("\n")
        }
        let reply = lastReply.trimAscii()
        if (reply.size > 0) {
            sb.append("- 结果: ")
            // 同 task 切片：中文回复切点 200 可能落在多字节字符中间
            sb.append(if (reply.size > 200) { truncateUtf8(reply, 200) + "…" } else { reply })
            sb.append("\n")
        }
        return sb.toString()
    }

    /**
     * 获取当前消息历史（供会话持久化）
     */
    public func history(): ArrayList<ChatMessage> {
        return this.messages
    }

    /**
     * 注入历史消息（恢复会话；跳过 system 由构造器管理）
     */
    public func loadHistory(history: ArrayList<ChatMessage>): Unit {
        // 注意：这里**不做**历史修复——加载侧保留原始历史（TUI 回看、摘要、compaction
        // 都按真实内容工作）；配对整形只在发上游前做（见 run 循环的 repairHistory）。
        for (m in history) {
            if (m.role != "system") {
                this.messages.add(m)
            }
        }
    }
}
