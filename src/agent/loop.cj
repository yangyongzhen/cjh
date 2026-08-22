package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjllm.*
import cjcfg.*

/**
 * Agent 配置
 */
public class AgentConfig {
    public let systemPrompt: String
    public let maxIterations: Int64
    // 三域 capability 安全模型（未配置=宽松模式，全部允许）
    public let capability: Capability

    public init(systemPrompt: String, maxIterations: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = Capability()
    }

    public init(systemPrompt: String, maxIterations: Int64, capability: Capability) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
        this.capability = capability
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

    // 事件回调（供 TUI/CLI 展示）
    public var onDelta: (String) -> Unit = { d => }
    public var onToolStart: (String, JsonObject) -> Unit = { n, a => }
    public var onToolResult: (String, ToolResult) -> Unit = { n, r => }
    public var onAssistantText: (String) -> Unit = { t => }
    // 审批回调：危险操作需人工确认时调用，返回 true=同意执行（默认拒绝）
    public var onApproval: (String, JsonObject, String) -> Bool = { n, a, r => false }

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
     * 追加用户消息并运行，返回最终文本答复
     */
    public func run(userInput: String): String {
        this.messages.add(ChatMessage("user", userInput))

        var iterations: Int64 = 0
        while (iterations < this.config.maxIterations) {
            iterations += 1

            let response = this.provider.chatStream(this.messages, this.tools.specs(), { delta =>
                this.onDelta(delta)
            })

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
                for (tc in response.toolCalls) {
                    this.onToolStart(tc.name, tc.arguments)
                    let result = this.executeGuarded(tc.name, tc.arguments)
                    this.onToolResult(tc.name, result)
                    // tool 结果回填
                    this.messages.add(ChatMessage("tool", result.content, tc.id, tc.name))
                }
                continue
            }

            // 纯文本答复
            if (response.text.size > 0) {
                this.messages.add(ChatMessage("assistant", response.text))
                this.onAssistantText(response.text)
            }
            return response.text
        }
        return "[已达最大迭代次数 ${this.config.maxIterations}]"
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
