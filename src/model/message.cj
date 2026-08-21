package cjh.model

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

    public init(role: String, content: String) {
        this.role = role
        this.content = content
        this.toolCallId = ""
        this.name = ""
    }

    public init(role: String, content: String, toolCallId: String, name: String) {
        this.role = role
        this.content = content
        this.toolCallId = toolCallId
        this.name = name
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
}

/**
 * 一次 LLM 响应的解析结果：
 * - 纯文本回复（无工具调用）
 * - 或一组工具调用请求
 */
public class ModelResponse {
    public let text: String
    public let toolCalls: ArrayList<ToolCall>

    public init(text: String, toolCalls: ArrayList<ToolCall>) {
        this.text = text
        this.toolCalls = toolCalls
    }

    public func hasToolCalls(): Bool {
        return this.toolCalls.size > 0
    }
}
