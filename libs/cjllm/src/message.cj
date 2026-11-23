package cjllm

import stdx.encoding.json.*
import std.collection.*

/**
 * Agent 消息模型
 * 角色：system / user / assistant / tool
 */
public class ChatMessage {
    public let role: String
    public let content: String
    public let toolCallId: String   // tool 结果消息关联的工具调用 ID
    public let name: String         // tool 结果消息的工具名
    public let toolCalls: ArrayList<ToolCall>  // assistant 消息携带的请求工具调用
    // 内部提效提醒（单工具提醒/续跑指令/空响应重试等）只给模型看：
    // 不持久化、不进 Web 历史、不参与压缩。用户排队消息不在此列（含真实用户内容）。
    public let hiddenFromUser: Bool

    public init(role: String, content: String) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
        this.toolCalls = ArrayList<ToolCall>()
        this.hiddenFromUser = false
    }

    public init(role: String, content: String, toolCallId: String, name: String) {
        this.role = role
        this.content = content
        this.toolCallId = toolCallId
        this.name = name
        this.toolCalls = ArrayList<ToolCall>()
        this.hiddenFromUser = false
    }

    public init(role: String, content: String, toolCalls: ArrayList<ToolCall>) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
        this.toolCalls = toolCalls
        this.hiddenFromUser = false
    }

    /** 内部提醒消息构造：hiddenFromUser=true 时不落盘、不进可见历史。 */
    public init(role: String, content: String, hiddenFromUser: Bool) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
        this.toolCalls = ArrayList<ToolCall>()
        this.hiddenFromUser = hiddenFromUser
    }

    /**
     * 是否为内部提醒。
     *
     * 新消息看 hiddenFromUser；旧会话没有该字段，按内容前缀识别（兼容升级前的
     * `[System Notice]` 注入）。用户排队消息（SteerPolicy.NOTICE_HEAD）不算内部，
     * 因为它携带真实用户指令，必须在恢复后仍然可见。
     */
    public func isInternalNotice(): Bool {
        return this.hiddenFromUser || ChatMessage.isLegacyInternalNotice(this.content)
    }

    /** 旧会话内容前缀识别（无 hiddenFromUser 元数据时使用）。 */
    public static func isLegacyInternalNotice(content: String): Bool {
        return content.startsWith("[System Notice] 你已连续 ") ||
            content.startsWith("[System Notice] 轮次预算已续") ||
            content.startsWith("[System Notice] 任务已执行 ") ||
            content.startsWith("[System Notice] 你还没有完成任务") ||
            content.startsWith("[System Notice] 你上一轮只输出了思考") ||
            content.startsWith("[System Notice] The previous SSE stream was cut off") ||
            content.startsWith("[System Notice - ABSOLUTE DIRECTIVE") ||
            content.startsWith("[System Notice] Your previous response was empty")
    }

    /**
     * 转 OpenAI chat 消息 JSON
     */
    public func toOpenAiJson(): JsonValue {
        var obj = JsonObject()
        obj.put("role", JsonString(this.role))
        if (this.role == "tool") {
            obj.put("tool_call_id", JsonString(this.toolCallId))
            obj.put("content", JsonString(this.content))
            // 工具名必须持久化：session 保存/恢复循环依赖它，
            // 原实现漏写导致 tool 消息恢复后 name 丢失
            if (this.name.size > 0) {
                obj.put("name", JsonString(this.name))
            }
        } else {
            obj.put("content", JsonString(this.content))
            if (this.toolCalls.size > 0) {
                var tcs = ArrayList<JsonValue>()
                for (tc in this.toolCalls) {
                    tcs.add(tc.toOpenAiToolJson())
                }
                obj.put("tool_calls", JsonArray(tcs))
            }
        }
        return obj
    }

    /**
     * 会话落盘 JSON：OpenAI 形状 + 可选 `internal` 元数据。
     *
     * 不能直接改 toOpenAiJson：那是发往模型 API 的请求体，未知字段可能被
     * OpenAI/Anthropic 拒绝。持久化单独走这里。
     */
    public func toSessionJson(): JsonValue {
        var obj = this.toOpenAiJson().asObject()
        if (this.hiddenFromUser) {
            obj.put("internal", JsonBool(true))
        }
        return obj
    }
}

/**
 * 模型回复中的工具调用请求
 */
public class ToolCall {
    public let id: String
    public let name: String
    public let arguments: JsonObject

    public init(id: String, name: String, arguments: JsonObject) {
        this.id = id
        this.name = name
        this.arguments = arguments
    }

    public func toJson(): JsonValue {
        var obj = JsonObject()
        obj.put("id", JsonString(this.id))
        obj.put("name", JsonString(this.name))
        obj.put("arguments", this.arguments)
        return obj
    }

    /**
     * OpenAI 格式：{"id","type":"function","function":{"name","arguments"(string)}}
     */
    public func toOpenAiToolJson(): JsonValue {
        var fn = JsonObject()
        fn.put("name", JsonString(this.name))
        fn.put("arguments", JsonString(this.arguments.toJsonString()))
        var obj = JsonObject()
        obj.put("id", JsonString(this.id))
        obj.put("type", JsonString("function"))
        obj.put("function", fn)
        return obj
    }

    /**
     * Anthropic 格式 content block：{"type":"tool_use","id","name","input"}
     */
    public func toAnthropicBlockJson(): JsonValue {
        var obj = JsonObject()
        obj.put("type", JsonString("tool_use"))
        obj.put("id", JsonString(this.id))
        obj.put("name", JsonString(this.name))
        obj.put("input", this.arguments)
        return obj
    }
}

/**
 * 一次 LLM 响应的解析结果：
 * - 纯文本回复（无工具调用）
 * - 或一组工具调用请求
 */
public class ModelResponse {
    public let text: String
    public let toolCalls: ArrayList<ToolCall>
    public var usage: TokenUsage = TokenUsage()
    public var truncated: Bool = false   // finish_reason=="length"：输出被 max_tokens 截断
    // 被截断的 write_file/edit 的 path 列表（agent loop 据此注入 [System Notice]）
    public var truncatedPaths: ArrayList<String> = ArrayList<String>()
    // SSE 空闲超时（网络卡住 60s 无新数据）：已收文本/tool_calls 保留，但流被切断
    public var timedOut: Bool = false

    public init(text: String, toolCalls: ArrayList<ToolCall>) {
        this.text = text
        this.toolCalls = toolCalls
    }

    public func hasToolCalls(): Bool {
        return this.toolCalls.size > 0
    }
}

/**
 * 单次 LLM 调用的 token 用量
 */
public class TokenUsage {
    public var promptTokens: Int64 = 0       // 输入 token
    public var completionTokens: Int64 = 0   // 输出 token
    public var cachedTokens: Int64 = 0       // 缓存命中 token（prompt_cache_hit_tokens 等）

    public init() {}
}
