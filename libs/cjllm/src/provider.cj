package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import std.io.*
import std.collection.*

/**
 * 工具定义（发送给模型的 tool schema，OpenAI 格式）
 */
public class ToolSpec {
    public let name: String
    public let description: String
    public let parameters: JsonObject   // JSON Schema

    public init(name: String, description: String, parameters: JsonObject) {
        this.name = name
        this.description = description
        this.parameters = parameters
    }

    public func toOpenAiJson(): JsonValue {
        var obj = JsonObject()
        obj.put("type", JsonString("function"))
        obj.put("function", this.functionJson())
        return obj
    }

    private func functionJson(): JsonValue {
        var fn = JsonObject()
        fn.put("name", JsonString(this.name))
        fn.put("description", JsonString(this.description))
        fn.put("parameters", this.parameters)
        return fn
    }
}

/**
 * LLM 提供商抽象：统一 chat 流式接口
 */
public interface LlmProvider {
    /**
     * 发送流式 chat 请求，逐段回调增量文本。
     * @param messages 消息历史
     * @param tools    工具 schema（可为空）
     * @param onDelta  文本增量回调
     * @return 完整响应（含工具调用）
     */
    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit): ModelResponse
}

/**
 * 流式响应累加器：解析 OpenAI 兼容 SSE 帧
 */
public class StreamAccumulator {
    public var text: String = ""
    public var toolCalls: ArrayList<ToolCall> = ArrayList<ToolCall>()
    private var curToolId: String = ""
    private var curToolName: String = ""
    private var curToolArgs: String = ""

    /**
     * 处理一个 SSE data 帧（JSON）
     */
    public func feed(data: String): Unit {
        try {
            let j = JsonValue.fromStr(data)
            match (j.kind()) {
                case JsonKind.JsObject => ()
                case _ => return
            }
            let obj = j.asObject()
            // 工具调用增量（可能分片）
            if (let Some(tcs) <- obj.get("tool_calls")) {
                match (tcs.kind()) {
                    case JsonKind.JsArray =>
                        let arr = tcs.asArray()
                        for (i in 0..arr.size()) {
                            if (let Some(tc) <- arr.get(i)) {
                                this.feedToolCall(tc)
                            }
                        }
                    case _ => ()
                }
            }
            // 文本增量
            if (let Some(choices) <- obj.get("choices")) {
                match (choices.kind()) {
                    case JsonKind.JsArray =>
                        let arr = choices.asArray()
                        if (arr.size() > 0) {
                            if (let Some(c0) <- arr.get(0)) {
                                match (c0.kind()) {
                                    case JsonKind.JsObject =>
                                        let c = c0.asObject()
                                        if (let Some(delta) <- c.get("delta")) {
                                            match (delta.kind()) {
                                                case JsonKind.JsObject =>
                                                    if (let Some(content) <- delta.asObject().get("content")) {
                                                        match (content.kind()) {
                                                            case JsonKind.JsString =>
                                                                let s = content.asString().getValue()
                                                                if (s.size > 0) {
                                                                    this.text += s
                                                                }
                                                            case _ => ()
                                                        }
                                                    }
                                                case _ => ()
                                            }
                                        }
                                        // 流结束标记（finish_reason）
                                        if (let Some(fr) <- c.get("finish_reason")) {
                                            match (fr.kind()) {
                                                case JsonKind.JsString => () // 可记录
                                                case _ => ()
                                            }
                                        }
                                    case _ => ()
                                }
                            }
                        }
                    case _ => ()
                }
            }
        } catch (e: Exception) {
            // 忽略非 JSON 帧（如 keep-alive）
        }
    }

    private func feedToolCall(tc: JsonValue): Unit {
        match (tc.kind()) {
            case JsonKind.JsObject =>
                let obj = tc.asObject()
                if (let Some(id) <- obj.get("id")) {
                    match (id.kind()) {
                        case JsonKind.JsString =>
                            if (this.curToolId.size == 0) {
                                this.curToolId = id.asString().getValue()
                            }
                        case _ => ()
                    }
                }
                if (let Some(fn) <- obj.get("function")) {
                    match (fn.kind()) {
                        case JsonKind.JsObject =>
                            let f = fn.asObject()
                            if (let Some(name) <- f.get("name")) {
                                match (name.kind()) {
                                    case JsonKind.JsString => this.curToolName = name.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(args) <- f.get("arguments")) {
                                match (args.kind()) {
                                    case JsonKind.JsString => this.curToolArgs += args.asString().getValue()
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }

    /**
     * 流结束后调用：将累积的工具调用参数解析为 ToolCall
     */
    public func finish(): ModelResponse {
        if (this.curToolId.size > 0 && this.curToolName.size > 0) {
            var args = JsonObject()
            if (this.curToolArgs.size > 0) {
                try {
                    let parsed = JsonValue.fromStr(this.curToolArgs)
                    match (parsed.kind()) {
                        case JsonKind.JsObject => args = parsed.asObject()
                        case _ => ()
                    }
                } catch (e: Exception) {
                    // 参数非法：透传原始字符串
                    args.put("_raw", JsonString(this.curToolArgs))
                }
            }
            this.toolCalls.add(ToolCall(this.curToolId, this.curToolName, args))
        }
        return ModelResponse(this.text, this.toolCalls)
    }
}
