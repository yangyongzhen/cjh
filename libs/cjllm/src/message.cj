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

    public init(role: String, content: String) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
        this.toolCalls = ArrayList<ToolCall>()
    }

    public init(role: String, content: String, toolCallId: String, name: String) {
        this.role = role
        this.content = content
        this.toolCallId = toolCallId
        this.name = name
        this.toolCalls = ArrayList<ToolCall>()
    }

    public init(role: String, content: String, toolCalls: ArrayList<ToolCall>) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
        this.toolCalls = toolCalls
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
    // 被截断的 write_file/edit_file 的 path 列表（agent loop 据此注入 [System Notice]）
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
