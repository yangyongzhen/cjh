package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import std.time.*
import cjllm.*
import cjh.tools.*
import cjllm.*
import cjcfg.*
import std.sync.*

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
    // 压缩时保留的最近消息条数
    public let compactKeep: Int64

    public init(systemPrompt: String, maxIterations: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = Capability()
        this.compactThreshold = 0
        this.compactKeep = 12
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = 0
        this.compactKeep = 12
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability,
        compactThreshold: Int64, compactKeep: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = compactThreshold
        this.compactKeep = compactKeep
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
    // 内置任务列表（对齐 Claude Code TodoWrite，TUI Tasks 面板数据源）
    private var todos: ArrayList<TodoItem> = ArrayList<TodoItem>()
    private var nextTodoId: Int64 = 1

    // 事件回调（供 TUI/CLI 展示）
    public var onDelta: (String) -> Unit = { d => }
    public var onToolStart: (String, JsonObject) -> Unit = { n, a => }
    public var onToolResult: (String, ToolResult) -> Unit = { n, r => }
    public var onAssistantText: (String) -> Unit = { t => }
    // 审批回调：危险操作需人工确认时调用，返回 true=同意执行（默认拒绝）
    public var onApproval: (String, JsonObject, String) -> Bool = { n, a, r => false }
    // 任务变更回调（TUI Tasks 面板实时刷新）
    public var onTodosChanged: () -> Unit = { => }
    // 回合结束回调（渲染回合总结条：轮数/工具数/耗时/token用量/缓存命中率）
    public var onRunComplete: (RunSummary) -> Unit = { s => }

    public init(provider: LlmProvider, tools: ToolRegistry, config: AgentConfig) {
        this.provider = provider
        this.tools = tools
        this.config = config
        this.messages = ArrayList<ChatMessage>()
        this.messages.add(ChatMessage("system", config.systemPrompt))
    }

    /**
     * 运行时切换 provider（/model 命令；历史保留）
     */
    public func setProvider(p: LlmProvider): Unit {
        this.provider = p
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
     * 追加用户消息并运行，返回最终文本答复
     */
    public func run(userInput: String): String {
        this.messages.add(ChatMessage("user", userInput))
        // 长会话：超阈值先压缩早期历史（LLM 摘要），避免 token 爆炸
        this.maybeCompact()

        // 回合统计收集
        let summary = RunSummary()
        let startTime = DateTime.now()
        var iterations: Int64 = 0
        while (iterations < this.config.maxIterations) {
            iterations += 1
            summary.rounds = iterations

            let response = this.provider.chatStream(this.messages, this.tools.specs(), { delta =>
                this.onDelta(delta)
            })
            // 累计 token 用量
            summary.promptTokens += response.usage.promptTokens
            summary.completionTokens += response.usage.completionTokens
            summary.cachedTokens += response.usage.cachedTokens

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
                // V2d 并发执行引擎：Read vs. Write 分类调度（对齐 pi/omp/anon-kode）
                // - 全 read-only → spawn 并发执行，结果按 LLM 原始顺序重排
                // - 含 state-modifying → 整批串行（避免并发写竞态）
                let allReadOnly = this.allReadOnly(response.toolCalls)
                if (allReadOnly && response.toolCalls.size > 1) {
                    // 并发执行：每个 tool_call 独立 spawn，Future 按原始顺序 get()
                    var futures = ArrayList<Future<ToolResult>>()
                    for (tc in response.toolCalls) {
                        this.onToolStart(tc.name, tc.arguments)
                        let localName = tc.name
                        let localArgs = tc.arguments
                        futures.add(spawn {
                            this.executeGuarded(localName, localArgs)
                        })
                    }
                    // 按原始顺序 get 结果，回填消息历史
                    var idx: Int64 = 0
                    for (tc in response.toolCalls) {
                        let result = futures[idx].get()
                        this.onToolResult(tc.name, result)
                        this.messages.add(ChatMessage("tool", result.content, tc.id, tc.name))
                        idx += 1
                    }
                } else {
                    // 串行执行：含 state-modifying 工具或单工具调用
                    for (tc in response.toolCalls) {
                        this.onToolStart(tc.name, tc.arguments)
                        let result = this.executeGuarded(tc.name, tc.arguments)
                        this.onToolResult(tc.name, result)
                        // tool 结果回填
                        this.messages.add(ChatMessage("tool", result.content, tc.id, tc.name))
                    }
                }
                continue
            }

            // 纯文本答复
            if (response.text.size > 0) {
                this.messages.add(ChatMessage("assistant", response.text))
                this.onAssistantText(response.text)
            }
            // 回合结束：计算耗时并触发 onRunComplete
            let durationMs = (DateTime.now() - startTime).toMilliseconds()
            summary.durationMs = durationMs
            this.onRunComplete(summary)
            return response.text
        }
        // 达最大迭代次数也触发总结
        let durationMsMax = (DateTime.now() - startTime).toMilliseconds()
        summary.durationMs = durationMsMax
        this.onRunComplete(summary)
        return "[已达最大迭代次数 ${this.config.maxIterations}]"
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
            let resp = this.provider.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => })
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
     * Compaction：消息历史超过阈值时，用 LLM 把早期消息压缩成摘要，
     * 保留最近 compactKeep 条（含 system）。对齐 pi 的自动摘要压缩：
     * 触发后调用链 = 摘要请求（无工具）→ 重建 messages = system + 摘要 + 近期历史
     */
    private func maybeCompact(): Unit {
        if (this.config.compactThreshold <= 0) {
            return
        }
        // 消息数 = system + 对话；超过阈值才压缩
        if (this.messages.size <= this.config.compactThreshold) {
            return
        }
        let keep = if (this.config.compactKeep >= 2) { this.config.compactKeep } else { 2 }
        // 待压缩段：索引 1 .. size-keep-1（跳过 system，保留最近 keep 条）
        let compactEnd = this.messages.size - keep
        if (compactEnd <= 1) {
            return
        }
        // 构造摘要请求：把待压缩段拼接给 LLM，请求生成紧凑摘要
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
            let resp = this.provider.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => })
            summary = resp.text
        } catch (e: Exception) {
            // 摘要失败不阻塞主流程（保持原历史继续）
            return
        }
        if (summary.size == 0) {
            return
        }
        // 重建历史：system + 摘要消息 + 最近 keep 条
        var newMsgs = ArrayList<ChatMessage>()
        if (this.messages.size > 0) {
            newMsgs.add(this.messages[0])  // system
        }
        newMsgs.add(ChatMessage("user", "[历史摘要] ${summary}"))
        for (i in compactEnd..this.messages.size) {
            newMsgs.add(this.messages[i])
        }
        this.messages = newMsgs
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
        if (path.isSome() && (name == "read_file" || name == "write_file" || name == "grep" || name == "list_dir")) {
            let p = path.getOrThrow().asString().getValue()
            let isWrite = (name == "write_file")
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
        // 全部通过：正常执行
        return this.tools.execute(name, args)
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
