package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjllm.*

/**
 * Agent 配置
 */
public class AgentConfig {
    public let systemPrompt: String
    public let maxIterations: Int64

    public init(systemPrompt: String, maxIterations: Int64) {
        this.systemPrompt = systemPrompt
        this.maxIterations = maxIterations
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
    private let provider: LlmProvider
    private let tools: ToolRegistry
    private let config: AgentConfig
    private var messages: ArrayList<ChatMessage>

    // 事件回调（供 TUI/CLI 展示）
    public var onDelta: (String) -> Unit = { d => }
    public var onToolStart: (String, JsonObject) -> Unit = { n, a => }
    public var onToolResult: (String, ToolResult) -> Unit = { n, r => }
    public var onAssistantText: (String) -> Unit = { t => }

    public init(provider: LlmProvider, tools: ToolRegistry, config: AgentConfig) {
        this.provider = provider
        this.tools = tools
        this.config = config
        this.messages = ArrayList<ChatMessage>()
        this.messages.add(ChatMessage("system", config.systemPrompt))
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
                    let result = this.tools.execute(tc.name, tc.arguments)
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
