package cjh.agent

import std.collection.*
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
        this.compactKeep = 12
        this.toolResultMaxChars = 6000
        this.spillDir = ""
        this.sessionId = ""
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
        this.compactThreshold = 0
        this.compactKeep = 12
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
        // web_fetch/web_search 等结构化抓取工具的结果不应被 log-pruner 裁剪：
        // log-pruner 设计意图是裁剪冗长 bash 日志（>1000 字符截断），
        // 但 web_fetch 返回的正文需要完整传给 LLM 才能总结。
        if (toolName == "web_fetch" || toolName == "web_search") {
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

            // 顶层兜底：LLM 响应解析可能抛 IllegalArgumentException（非法 UTF-8 字节）
            // 不让它崩 TUI，转成错误消息返回
            let response: ModelResponse
            try {
                this.onThinking()
                response = this.provider.chatStream(this.messages, this.tools.specs(), { delta =>
                    this.onDelta(delta)
                }, { r =>
                    this.onReasoning(r)
                })
            } catch (e: Exception) {
                Log.error("Agent.run chatStream 异常: ${e}")
                summary.reply = "[LLM 调用异常: ${e}]"
                return summary
            }
            // 累计 token 用量
            summary.promptTokens += response.usage.promptTokens
            summary.completionTokens += response.usage.completionTokens
            summary.cachedTokens += response.usage.cachedTokens
            this.onTokens(response.usage.promptTokens)

            // SSE 空闲超时：网络 60s 无新数据，已收文本/tool_calls 保留
            // 给 LLM 注入提示，让它在下一轮知道发生了超时
            if (response.timedOut) {
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
                        var result = this.executeGuarded(tc.name, tc.arguments)
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
            }
            // 回合结束：计算耗时，回填 reply，返回 summary（onRunComplete 由调用方在 setAgentRunning(false) 后触发）
            let durationMs = (DateTime.now() - startTime).toMilliseconds()
            summary.durationMs = durationMs
            summary.reply = response.text
            return summary
        }
        // 达最大迭代次数也触发总结
        let durationMsMax = (DateTime.now() - startTime).toMilliseconds()
        summary.durationMs = durationMsMax
        summary.reply = "[已达最大迭代次数 ${this.config.maxIterations}]"
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
            let resp = this.provider.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => })
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
     * 工具差异化截断阈值（对标 Pi v0.13.2）
     * bash 输出可能很长；list_dir 目录树过长；grep 搜索结果多
     */
    private func toolResultMaxChars(toolName: String): Int64 {
        // 全局禁用截断（0 或负数）→ 返回一个大数，等价于不截断
        if (this.config.toolResultMaxChars <= 0) {
            return Int64.Max
        }
        match (toolName) {
            case "bash" => if (this.config.toolResultMaxChars >= 8000) { this.config.toolResultMaxChars } else { 8000 }
            case "list_dir" => 4000
            case _ => this.config.toolResultMaxChars
        }
    }

    /**
     * 落盘文件路径：spillDir/<sessionId>/<toolCallId>.txt
     */
    private func spillPath(toolCallId: String): String {
        return this.config.spillDir + "/" + this.config.sessionId + "/" + toolCallId + ".txt"
    }

    /**
     * 落盘写入完整工具结果
     */
    private func writeSpill(path: String, content: String): Unit {
        try {
            // 从完整路径里取出目录部分（最后一次 "/" 之前）
            match (path.lastIndexOf("/")) {
                case Some(dirEnd) =>
                    let dir = path[0..dirEnd]
                    if (!exists(dir)) {
                        Directory.create(dir, recursive: true)
                    }
                case None => ()
            }
            File.writeTo(path, content.toArray())
        } catch (e: Exception) {
            Log.warn("spill 落盘失败: ${e}")
            // 落盘失败不影响截断本身，只是丢了回溯路径
        }
    }

    /**
     * Tool Output 压缩 Hook：tool_result 过长时裁剪成 Head/Tail 摘要，
     * 避免巨大 tool 结果（如 read_file 读了个几千行日志）冲垮前缀缓存或 token 预算。
     *
     * 截断 + 落盘 + 回溯钥匙（对标 Pi spill extension）：
     * - 超过阈值的工具结果保留头尾 + 中间省略标记
     * - 完整结果落盘到 spillDir/<sessionId>/<toolCallId>.txt
     * - 省略标记包含落盘文件路径（这把「钥匙」），模型可用 read_file 按需读回
     */
    private func truncateToolResult(content: String, toolName: String, toolCallId: String): String {
        let maxChars = this.toolResultMaxChars(toolName)
        // 按 Rune（字符）计数，避免按字节切片截断在多字节 UTF-8 中间
        let runes = content.toRuneArray()
        let charCount = Int64(runes.size)
        if (maxChars <= 0 || charCount <= maxChars) {
            return content
        }
        let headLen: Int64 = maxChars / 2
        let tailLen: Int64 = maxChars - headLen
        var headSb = StringBuilder()
        for (i in 0..Int64(headLen)) {
            headSb.append(String(runes[i]))
        }
        let tailStart = charCount - tailLen
        var tailSb = StringBuilder()
        for (i in Int64(tailStart)..charCount) {
            tailSb.append(String(runes[i]))
        }
        let skipped = charCount - maxChars

        // 落盘完整结果（回溯路径）
        var spillHint = ""
        if (this.config.spillDir.size > 0 && this.config.sessionId.size > 0) {
            let spillPath = this.spillPath(toolCallId)
            this.writeSpill(spillPath, content)
            spillHint = "，完整结果已保存：" + spillPath + "，可用 read_file 读取"
        }

        return headSb.toString()
            + "\n\n…[已截断 " + skipped.toString() + " 字符" + spillHint + "]…\n\n"
            + tailSb.toString()
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
            let resp = this.provider.chatStream(summaryMsgs, ArrayList<ToolSpec>(), { _ => }, { _ => })
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
            case "read_file" | "grep" | "list_dir" =>
                match (tc.arguments.get("path")) {
                    case Some(p) => return (p.asString().getValue(), false)
                    case None => return ("", false)
                }
            case "write_file" | "append_file" | "edit_file" =>
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
        // 全部通过：正常执行（兜底异常，避免单工具崩溃带垮整个 Agent 循环）
        try {
            return this.tools.execute(name, args)
        } catch (e: Exception) {
            return ToolResult("工具执行异常: ${e}", true)
        }
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
