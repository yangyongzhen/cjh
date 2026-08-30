package cjh.agent

import std.collection.*
import cjlog.*
import stdx.encoding.json.*
import std.time.*
import std.fs.*
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
 * Agent 配置
 */
public class AgentConfig {
    public let systemPrompt: String
    public let maxIterations: Int64
    // 三域 capability 安全模型（未配置=宽松模式，全部允许）
    public let capability: Capability
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
    private var provider: LlmProvider
    private let tools: ToolRegistry
    private let config: AgentConfig
    private var messages: ArrayList<ChatMessage>
    // 上一轮 LLM 响应的真实 prompt token（usage.promptTokens）。
    // 压缩触发用它而非字符估算——估算对中文/JSON 开销严重低估（实测 6.5x 偏差），
    // 真实用量是 provider 已返回的精确值。0=尚未有测量（首轮前）。
    private var lastPromptTokens: Int64 = 0
    // 中断标志（P0-2）：用户 Ctrl+C 请求中断当前任务轮次。
    // 线程安全（主线程 handleKey 设置，agent 线程轮询检查）。
    private var interruptFlag: Bool = false
    private var interruptLock: Mutex = Mutex()
    // 摘要专用快模型（P1-5 模型路由）：compaction 摘要走快模型，None=复用主 provider
    private var summaryProvider: Option<LlmProvider> = None
    // 内置任务列表（对齐 Claude Code TodoWrite，TUI Tasks 面板数据源）
    private var todos: ArrayList<TodoItem> = ArrayList<TodoItem>()
    private var nextTodoId: Int64 = 1
    // 插件管理器（V2b Step 2：事件钩子；None 时跳过钩子调用）
    private var pluginManager: ?PluginManager = None

    // 事件回调（供 TUI/CLI 展示）
    public var onDelta: (String) -> Unit = { d => }
    public var onReasoning: (String) -> Unit = { r => }
    public var onToolStart: (String, JsonObject) -> Unit = { n, a => }
    public var onToolResult: (String, ToolResult) -> Unit = { n, r => }
    public var onAssistantText: (String) -> Unit = { t => }
    // 状态回调（TUI 实时状态行用）
    public var onThinking: () -> Unit = { => }
    public var onTokens: (Int64) -> Unit = { _ => }
    // 流式逐帧 token 估算回调（思考过程中实时更新动态状态栏）
    public var onTokenEstimate: (Int64) -> Unit = { _ => }
    // 审批回调：危险操作需人工确认时调用，返回 true=同意执行（默认拒绝）
    public var onApproval: (String, JsonObject, String) -> Bool = { n, a, r => false }
    // 任务变更回调（TUI Tasks 面板实时刷新）
    public var onTodosChanged: () -> Unit = { => }
    // 回合结束回调（渲染回合总结条：轮数/工具数/耗时/token用量/缓存命中率）
    public var onRunComplete: (RunSummary) -> Unit = { s => }

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

    public init(provider: LlmProvider, tools: ToolRegistry, config: AgentConfig) {
        this.provider = provider
        this.tools = tools
        this.config = config
        this.messages = ArrayList<ChatMessage>()
        this.messages.add(ChatMessage("system", config.systemPrompt))
    }

    /**
     * 请求中断当前任务（P0-2）：设置中断标志，agent 在轮次间/工具执行后
     * 检查并停止循环，保留已完成的工作。线程安全。
     */
    public func interrupt(): Unit {
        this.interruptLock.lock()
        try {
            this.interruptFlag = true
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
        // 新一轮开始：清除上次中断状态（否则 interruptFlag 残留 true，
        // 后续所有消息立即命中"已中断"——用户实测的"再也不回复"bug）
        this.interruptLock.lock()
        this.interruptFlag = false
        this.interruptLock.unlock()
        this.messages.add(ChatMessage("user", userInput))

        // 回合统计收集
        let summary = RunSummary()
        let startTime = DateTime.now()
        var iterations: Int64 = 0
        // 空响应重试计数（LLM 返回无 text 且无 tool_calls 时重试，超过 maxEmptyRetries 才退出）
        var emptyRetries: Int64 = 0
        let maxEmptyRetries: Int64 = 3
        while (iterations < this.config.maxIterations) {
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

            // 长会话压缩：每轮发起 LLM 请求前检查历史是否超阈值
            // （消息条数 或 估算 token 任一超限即 LLM 摘要压缩早期历史）。
            // 必须放在循环内——单次 run() 可能跑几十轮，prompt 随轮次膨胀，
            // 只在 run() 开头检查的话压缩永远不会触发（实测 48 轮 prompt 涨到 31K token）
            this.maybeCompact()

            // 顶层兜底：LLM 响应解析可能抛 IllegalArgumentException（非法 UTF-8 字节）
            // 不让它崩 TUI，转成错误消息返回
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
                Log.error("Agent.run chatStream 异常: ${e}", e)
                summary.reply = "[LLM 调用异常: ${e}]"
                return summary
            }
            let roundMs = (DateTime.now() - roundStart).toMilliseconds()
            // 累计 token 用量
            summary.promptTokens += response.usage.promptTokens
            summary.completionTokens += response.usage.completionTokens
            summary.cachedTokens += response.usage.cachedTokens
            // 记录真实 prompt token（压缩触发依据；首轮为 0 时用字符估算兜底）
            this.lastPromptTokens = response.usage.promptTokens
            this.onTokens(response.usage.promptTokens + response.usage.completionTokens)
            Log.info("第 ${iterations} 轮完成 | 耗时 ${roundMs}ms | prompt ${response.usage.promptTokens} completion ${response.usage.completionTokens} cached ${response.usage.cachedTokens} | toolCalls ${response.toolCalls.size} | textLen ${response.text.size} | truncated ${response.truncated} | timedOut ${response.timedOut}")

            // SSE 空闲超时：网络 60s 无新数据，已收文本/tool_calls 保留
            // 给 LLM 注入提示，让它在下一轮知道发生了超时
            if (response.timedOut) {
                Log.error("SSE 空闲超时（60s 无新数据），SSE 流被切断")
                this.onAssistantText("\n\n⚠️ 网络空闲超时（60s 无新数据），SSE 流被切断。已收到的内容已保留，但可能不完整。\n")
                this.messages.add(ChatMessage("user", "[System Notice] The previous SSE stream was cut off due to a 60-second idle timeout (network stall). The received content may be INCOMPLETE. Please check whether the output/tool_calls were fully received, and continue or retry as needed."))
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
                            result = ToolResult(result.content + "\n\n⚠️ 截断警告：本轮 LLM 输出被 max_tokens 强制截断，上面写入的文件内容【不完整】。\n请【立即】按以下步骤修复（不要再用 write_file 重写整个文件，那会再次截断）：\n1. 调用 read_file 读取刚写入的文件，确认截断位置\n2. 调用 edit_file，old_string 填文件末尾最后几个有效字符，new_string 续写剩余部分\n3. 重复 1-2 直到文件完整闭合（HTML 需 </script></body></html>）\n务必分多次小段续写，每段 new_string 控制在 ~1500 字符以内。", true)
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
                                r = ToolResult(r.content + "\n\n⚠️ 截断警告：本轮 LLM 输出被 max_tokens 强制截断，上面写入的文件内容【不完整】。\n请【立即】按以下步骤修复（不要再用 write_file 重写整个文件，那会再次截断）：\n1. 调用 read_file 读取刚写入的文件，确认截断位置\n2. 调用 edit_file，old_string 填文件末尾最后几个有效字符，new_string 续写剩余部分\n3. 重复 1-2 直到文件完整闭合（HTML 需 </script></body></html>）\n务必分多次小段续写，每段 new_string 控制在 ~1500 字符以内。", true)
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
        // 达最大迭代次数也触发总结
        Log.warn("已达最大迭代次数 ${this.config.maxIterations}，强制结束回合")
        let durationMsMax = (DateTime.now() - startTime).toMilliseconds()
        summary.durationMs = durationMsMax
        summary.reply = "[已达最大迭代次数 ${this.config.maxIterations}]"
        // 给 TUI 上文字提示，而非静默退出
        this.onAssistantText("\n⚠️ 已达最大迭代次数 ${this.config.maxIterations}，回合强制结束。如需继续，请重新提问。")
        return summary
    }

    /**
     * Compaction：消息历史超过阈值时，用 LLM 把早期消息压缩成摘要，
     * 保留最近 compactKeep 条（含 system）。对齐 pi 的自动摘要压缩：
     * 触发后调用链 = 摘要请求（无工具）→ 重建 messages = system + 摘要 + 近期历史
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
        this.messages = newMsgs
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
     * Compaction：消息历史超过阈值时，用 LLM 把早期消息压缩成摘要，
     * 保留最近 compactKeep 条（含 system）。对齐 pi 的自动摘要压缩：
     * 触发后调用链 = 摘要请求（无工具）→ 重建 messages = system + 摘要 + 近期历史
     */
    private func maybeCompact(): Unit {
        if (this.config.compactThreshold <= 0 && this.config.compactTokenThreshold <= 0) {
            return
        }
        // 双阈值触发（任一超限即压缩）：
        //  1. 消息条数阈值：compactThreshold（对齐 pi 自动摘要）
        //  2. token 估算阈值：compactTokenThreshold——长 tool_result 时消息条数涨得慢
        //     但 prompt 已膨胀，靠字符数估算兜底（实测 30 条消息时 prompt 已 15-20K token）
        let msgCount: Int64 = this.messages.size
        let overCount: Bool = this.config.compactThreshold > 0 && msgCount > this.config.compactThreshold
        // token 触发：优先用上一轮 provider 返回的真实 prompt token（精确）；
        // 首轮前无测量时退化为字符估算（/4，保守）
        let triggerTokens = if (this.lastPromptTokens > 0) { this.lastPromptTokens } else { this.estimateMessagesTokens() }
        let overTokens: Bool = this.config.compactTokenThreshold > 0 && triggerTokens > this.config.compactTokenThreshold
        if (!overCount && !overTokens) {
            return
        }
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        // 待压缩段：索引 1 .. size-keep-1（跳过 system，保留最近 keep 条）
        let compactEnd = this.messages.size - keep
        if (compactEnd <= 1) {
            return
        }
        // P1-8：构造摘要请求——assistant 纯文本进摘要，tool_call/tool_result 保留原文。
        // 避免摘要丢失工具结果细节导致压缩后 agent"失忆"。
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
        var summary = ""
        try {
            // P1-5：摘要走快模型（配置了 summary 时），降低摘要调用耗时
            let sp = if (this.summaryProvider.isSome()) { this.summaryProvider.getOrThrow() } else { this.provider }
            let resp = sp.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => }, { _ => }, { => false })
            summary = resp.text
        } catch (e: Exception) {
            // 摘要失败不阻塞主流程（保持原历史继续）
            return
        }
        if (summary.size == 0) {
            return
        }
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
        this.onDelta("\n\n_[会话历史已自动压缩：${compactEnd - 1} 条早期消息 → 摘要]_")
    }

    /**
     * V2d 并发执行引擎：判断一批 tool_calls 是否全部 read-only
     * 全 read-only → 可并发执行；含 state-modifying → 整批串行
     */
    private func allReadOnly(toolCalls: ArrayList<ToolCall>): Bool {
        for (tc in toolCalls) {
            if (!this.tools.isReadOnly(tc.name)) {
                return false
            }
        }
        return true
    }

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
        match (tc.name) {
            case "read_file" | "grep" | "list_dir" | "glob" =>
                match (tc.arguments.get("path")) {
                    case Some(p) => return (p.asString().getValue(), false)
                    case None => return ("", false)
                }
            case "write_file" | "append_file" | "edit_file" | "hashline_edit" =>
                match (tc.arguments.get("path")) {
                    case Some(p) => return (p.asString().getValue(), true)
                    case None => return ("", true)
                }
            case "bash" =>
                match (tc.arguments.get("command")) {
                    case Some(c) => return (c.asString().getValue(), true)
                    case None => return ("", true)
                }
            case _ =>
                return ("", true)
        }
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
    private func buildDependencyGraph(toolCalls: ArrayList<ToolCall>): ArrayList<ArrayList<Int64>> {
        let n = toolCalls.size
        // deps[i] = i 依赖的工具调用索引列表（这些必须先完成，i 才能开始）
        var deps = ArrayList<ArrayList<Int64>>()
        for (_ in 0..n) {
            deps.add(ArrayList<Int64>())
        }

        // 提取每个工具调用的资源访问
        var accesses = ArrayList<(String, Bool)>()
        for (_ in 0..n) {
            accesses.add(("", false))
        }
        for (i in 0..n) {
            accesses[i] = this.extractResourceAccess(toolCalls[i])
        }

        // 构建依赖边：同 path 且至少一个 write → 串行依赖
        for (i in 0..n) {
            let (pathI, writeI) = accesses[i]
            if (pathI.size == 0) {
                continue  // 无资源路径，不建依赖
            }
            for (j in 0..n) {
                if (i == j) {
                    continue
                }
                let (pathJ, writeJ) = accesses[j]
                if (pathJ.size == 0) {
                    continue
                }
                // 同一路径 + 至少一个写 → 串行依赖
                if (pathI == pathJ && (writeI || writeJ)) {
                    // 保留 LLM 原始顺序：j < i 时 i 依赖 j
                    if (j < i) {
                        deps[i].add(Int64(j))
                    }
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
        var task = ""
        var files = HashSet<String>()
        var toolCount: Int64 = 0
        var lastReply = ""
        for (m in this.messages) {
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
        sb.append(if (task.size > 60) { task[0..60] + "…" } else { task })
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
            sb.append(if (reply.size > 200) { reply[0..200] + "…" } else { reply })
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
        for (m in history) {
            if (m.role != "system") {
                this.messages.add(m)
            }
        }
    }
}
