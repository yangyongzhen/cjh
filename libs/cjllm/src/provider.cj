package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import std.io.*
import std.collection.*
import cjutil.*

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
    // 上次已回调的文本长度（供增量回调）
    private var lastSentText: String = ""
    // 并行工具调用按 index 分别累积（OpenAI 流式 tool_calls 数组元素带 index；
    // 旧实现单一 curToolArgs 会把多个调用参数拼成非法 JSON → _raw 透传 → "缺少参数"）
    private var pendingToolIds: ArrayList<String> = ArrayList<String>()
    private var pendingToolNames: ArrayList<String> = ArrayList<String>()
    private var pendingToolArgs: ArrayList<String> = ArrayList<String>()
    // token 用量（SSE 最后一帧或非流式响应的 usage 字段）
    public var promptTokens: Int64 = 0
    public var completionTokens: Int64 = 0
    public var cachedTokens: Int64 = 0

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
                                                    // 文本增量
                                                    if (let Some(content) <- delta.asObject().get("content")) {
                                                        match (content.kind()) {
                                                            case JsonKind.JsString =>
                                                                let s = content.asString().getValue()
                                                                if (s.size > 0) {
                                                                    // 只累积原始文本：mojibake 修复必须在完整串上做，
                                                                    // 逐 chunk 修复在分片切碎 mojibake 串时会失败（finish 时整体修复）
                                                                    this.text += s
                                                                }
                                                            case _ => ()
                                                        }
                                                    }
                                                    // 工具调用增量（流式在 delta.tool_calls，非顶层）
                                                    if (let Some(tcs) <- delta.asObject().get("tool_calls")) {
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
            // token 用量（OpenAI 流式最后一帧或非流式响应顶层 usage）
            if (let Some(u) <- obj.get("usage")) {
                match (u.kind()) {
                    case JsonKind.JsObject =>
                        let usage = u.asObject()
                        if (let Some(pt) <- usage.get("prompt_tokens")) {
                            match (pt.kind()) {
                                case JsonKind.JsInt => this.promptTokens = pt.asInt().getValue()
                                case _ => ()
                            }
                        }
                        if (let Some(ct) <- usage.get("completion_tokens")) {
                            match (ct.kind()) {
                                case JsonKind.JsInt => this.completionTokens = ct.asInt().getValue()
                                case _ => ()
                            }
                        }
                        // DeepSeek 缓存命中：prompt_cache_hit_tokens
                        if (let Some(ch) <- usage.get("prompt_cache_hit_tokens")) {
                            match (ch.kind()) {
                                case JsonKind.JsInt => this.cachedTokens = ch.asInt().getValue()
                                case _ => ()
                            }
                        }
                        // Anthropic 缓存命中：cache_read_input_tokens
                        if (let Some(cr) <- usage.get("cache_read_input_tokens")) {
                            match (cr.kind()) {
                                case JsonKind.JsInt => this.cachedTokens += cr.asInt().getValue()
                                case _ => ()
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
                // 并行调用 index（缺失按 0 处理；流式分片同一 index 追加）
                var index: Int64 = 0
                if (let Some(idx) <- obj.get("index")) {
                    match (idx.kind()) {
                        case JsonKind.JsInt => index = idx.asInt().getValue()
                        case JsonKind.JsFloat => index = Int64(idx.asFloat().getValue())
                        case _ => ()
                    }
                }
                // 扩容到 index+1（ArrayList 无 insert，用占位 + 赋值）
                while (this.pendingToolIds.size <= index) {
                    this.pendingToolIds.add("")
                    this.pendingToolNames.add("")
                    this.pendingToolArgs.add("")
                }
                if (let Some(id) <- obj.get("id")) {
                    match (id.kind()) {
                        case JsonKind.JsString =>
                            // id 只在首个分片出现，非空时保留
                            if (this.pendingToolIds[index].size == 0) {
                                this.pendingToolIds[index] = id.asString().getValue()
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
                                    case JsonKind.JsString => this.pendingToolNames[index] = name.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(args) <- f.get("arguments")) {
                                match (args.kind()) {
                                    case JsonKind.JsString => this.pendingToolArgs[index] += args.asString().getValue()
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
     * 提取自上次回调以来的文本增量（并更新游标）
     */
    public func takeDelta(): String {
        // 增量 = 全文 - 已发送文本（字符安全，避免 UTF-8 切片错位）
        let cur = this.text
        if (cur.size <= this.lastSentText.size) {
            return ""
        }
        // 从已发送长度开始，找到合法字符边界作为增量起点
        var cut = this.lastSentText.size
        var delta = ""
        while (cut <= cur.size) {
            try {
                delta = cur[cut..cur.size]
                break
            } catch (e: Exception) {
                cut -= 1
            }
        }
        // 已发出 delta（cur[cut..size]），记录已发送 = 整个 cur
        this.lastSentText = cur
        return delta
    }

    /**
     * 流结束后调用：将累积的工具调用参数解析为 ToolCall（每个 index 一个）
     */
    public func finish(): ModelResponse {
        for (i in 0..this.pendingToolIds.size) {
            let id = this.pendingToolIds[i]
            let name = this.pendingToolNames[i]
            if (id.size == 0 || name.size == 0) {
                continue
            }
            var args = JsonObject()
            let raw = this.pendingToolArgs[i]
            if (raw.size > 0) {
                // 三级容错：直接解析 → 去双重转义 → JSON 补全
                // 参考 OpenAI SDK accumulate_delta + partialParse
                let parsed = tryParseJson(raw)
                match (parsed) {
                    case Some(obj) => args = obj
                    case None => 
                        // 去掉双重转义（DeepSeek 返回 \\\" → \"）
                        let unescaped = raw.replace("\\\\\"", "\"").replace("\\\\\\\\", "\\\\")
                        let parsed2 = tryParseJson(unescaped)
                        match (parsed2) {
                            case Some(obj) => args = obj
                            case None =>
                                // JSON 被截断：补全
                                let repaired = repairTruncatedJson(raw)
                                let parsed3 = tryParseJson(repaired)
                                match (parsed3) {
                                    case Some(obj) => args = obj
                                    case None =>
                                        Log.error("finish: JSON 解析失败, raw[:200]=${raw[0..(if (raw.size > 200) { 200 } else { raw.size })]}")
                                        args.put("_raw", JsonString(raw))
                                }
                        }
                }
            }
            this.toolCalls.add(ToolCall(id, name, args))
        }
        // 整体修复：流式累积的原始文本可能含 DeepSeek Latin-1 误解码 mojibake
        let resp = ModelResponse(MojibakeFix.fix(this.text), this.toolCalls)
        resp.usage.promptTokens = this.promptTokens
        resp.usage.completionTokens = this.completionTokens
        resp.usage.cachedTokens = this.cachedTokens
        return resp
    }
}
