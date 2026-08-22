package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import std.collection.*
import std.io.*

/**
 * Anthropic Messages API 协议实现
 *
 * 端点：POST /v1/messages
 * 认证：x-api-key + anthropic-version 头
 * 流式：SSE events（message_start / content_block_delta / message_delta / message_stop）
 *
 * 与 OpenAI 的差异：
 * - 请求：system 单独字段；messages 无 system 角色
 * - 工具调用：content 为 blocks 数组（type=tool_use），参数是 input_json_delta 分片
 * - tool 结果：以 user 角色 + tool_result block 回传
 */
public class AnthropicProvider <: LlmProvider {
    public let baseUrl: String
    public let apiKey: String
    public let model: String

    public init(baseUrl: String, apiKey: String, model: String) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
    }

    /**
     * 归一化端点：接受 base（https://api.anthropic.com）或完整路径，自动补全 /v1/messages
     */
    public func endpointUrl(): String {
        var url = this.baseUrl
        if (url.endsWith("/")) {
            url = url[0..url.size - 1]
        }
        if (!url.contains("/messages")) {
            url += "/v1/messages"
        }
        return url
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit): ModelResponse {
        // 请求体
        var body = JsonObject()
        body.put("model", JsonString(this.model))
        body.put("max_tokens", JsonInt(4096))
        body.put("stream", JsonBool(true))

        // system 单独提取
        var sys = ""
        for (m in messages) {
            if (m.role == "system") {
                if (sys.size > 0) {
                    sys += "\n"
                }
                sys += m.content
            }
        }
        if (sys.size > 0) {
            body.put("system", JsonString(sys))
        }

        // messages（Anthropic 无 system 角色，tool 结果转 user+tool_result）
        var msgList = ArrayList<JsonValue>()
        for (m in messages) {
            if (m.role == "system") {
                continue
            }
            if (m.role == "tool") {
                // tool 结果 → user 角色 + tool_result block
                var contentArr = ArrayList<JsonValue>()
                var tr = JsonObject()
                tr.put("type", JsonString("tool_result"))
                tr.put("tool_use_id", JsonString(m.toolCallId))
                tr.put("content", JsonString(m.content))
                contentArr.add(tr)
                var msg = JsonObject()
                msg.put("role", JsonString("user"))
                msg.put("content", JsonArray(contentArr))
                msgList.add(msg)
            } else {
                var msg = JsonObject()
                msg.put("role", JsonString(m.role))
                if (m.toolCalls.size > 0) {
                    // assistant 带 tool_use blocks（content 数组）
                    var blocks = ArrayList<JsonValue>()
                    if (m.content.size > 0) {
                        var textBlock = JsonObject()
                        textBlock.put("type", JsonString("text"))
                        textBlock.put("text", JsonString(m.content))
                        blocks.add(textBlock)
                    }
                    for (tc in m.toolCalls) {
                        blocks.add(tc.toAnthropicBlockJson())
                    }
                    msg.put("content", JsonArray(blocks))
                } else {
                    msg.put("content", JsonString(m.content))
                }
                msgList.add(msg)
            }
        }
        body.put("messages", JsonArray(msgList))

        // tools → input_schema
        if (tools.size > 0) {
            var toolList = ArrayList<JsonValue>()
            for (t in tools) {
                var tool = JsonObject()
                tool.put("name", JsonString(t.name))
                tool.put("description", JsonString(t.description))
                tool.put("input_schema", t.parameters)
                toolList.add(tool)
            }
            body.put("tools", JsonArray(toolList))
        }

        // 请求（base_url 自动补全 /v1/messages）
        let client = ClientBuilder().tlsConfig(TlsClientConfig()).build()
        let req = HttpRequestBuilder()
            .post()
            .url(this.endpointUrl())
            .header("Content-Type", "application/json")
            .header("x-api-key", this.apiKey)
            .header("anthropic-version", "2023-06-01")
            .body(body.toJsonString())
            .build()

        let resp = client.send(req)
        let status = resp.status
        if (status != 200) {
            var errBuf = Array<Byte>(4096, repeat: 0)
            var err = ""
            let n = resp.body.read(errBuf)
            if (n > 0) {
                err = String.fromUtf8(errBuf[0..n])
            }
            throw LlmException("HTTP ${status}: ${err}")
        }

        // SSE 解析（Anthropic event 格式）
        let acc = AnthropicAccumulator()
        let parser = SseParser(resp.body)
        parser.onEvent = { data =>
            acc.feed(data, onDelta)
        }
        parser.run()
        return acc.finish()
    }
}

/**
 * Anthropic 流式响应累加器
 * 处理 events：message_start / content_block_delta（text_delta, input_json_delta）等
 */
public class AnthropicAccumulator {
    public var text: String = ""
    public var toolCalls: ArrayList<ToolCall> = ArrayList<ToolCall>()

    // 当前工具调用分片状态
    private var curToolId: String = ""
    private var curToolName: String = ""
    private var curToolArgs: String = ""
    private var toolStarted: Bool = false
    // 增量游标
    private var lastSentText: String = ""

    public init() {}

    /**
     * 处理一个 SSE data 帧（Anthropic event JSON）
     */
    public func feed(data: String, onDelta: (String) -> Unit): Unit {
        try {
            let j = JsonValue.fromStr(data)
            match (j.kind()) {
                case JsonKind.JsObject => ()
                case _ => return
            }
            let obj = j.asObject()
            // event 类型
            var eventType = ""
            if (let Some(t) <- obj.get("type")) {
                match (t.kind()) {
                    case JsonKind.JsString => eventType = t.asString().getValue()
                    case _ => ()
                }
            }

            match (eventType) {
                case "content_block_start" =>
                    // 工具调用开始
                    if (let Some(cb) <- obj.get("content_block")) {
                        match (cb.kind()) {
                            case JsonKind.JsObject =>
                                let block = cb.asObject()
                                if (let Some(bt) <- block.get("type")) {
                                    match (bt.kind()) {
                                        case JsonKind.JsString =>
                                            if (bt.asString().getValue() == "tool_use") {
                                                this.toolStarted = true
                                                if (let Some(id) <- block.get("id")) {
                                                    match (id.kind()) {
                                                        case JsonKind.JsString => this.curToolId = id.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(name) <- block.get("name")) {
                                                    match (name.kind()) {
                                                        case JsonKind.JsString => this.curToolName = name.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                            }
                                        case _ => ()
                                    }
                                }
                            case _ => ()
                        }
                    }
                case "content_block_delta" =>
                    if (let Some(d) <- obj.get("delta")) {
                        match (d.kind()) {
                            case JsonKind.JsObject =>
                                let delta = d.asObject()
                                if (let Some(dt) <- delta.get("type")) {
                                    match (dt.kind()) {
                                        case JsonKind.JsString =>
                                            match (dt.asString().getValue()) {
                                                case "text_delta" =>
                                                    if (let Some(txt) <- delta.get("text")) {
                                                        match (txt.kind()) {
                                                            case JsonKind.JsString =>
                                                                let s = txt.asString().getValue()
                                                                if (s.size > 0) {
                                                                    this.text += MojibakeFix.fix(s)
                                                                }
                                                            case _ => ()
                                                        }
                                                    }
                                                case "input_json_delta" =>
                                                    if (let Some(pj) <- delta.get("partial_json")) {
                                                        match (pj.kind()) {
                                                            case JsonKind.JsString => this.curToolArgs += pj.asString().getValue()
                                                            case _ => ()
                                                        }
                                                    }
                                                case _ => ()
                                            }
                                        case _ => ()
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }

            // 回调文本增量
            let delta = this.takeDelta()
            if (delta.size > 0) {
                onDelta(delta)
            }
        } catch (e: Exception) {
            // 忽略非 JSON 帧
        }
    }

    private func takeDelta(): String {
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
     * 流结束：解析累积的工具调用
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
                    args.put("_raw", JsonString(this.curToolArgs))
                }
            }
            this.toolCalls.add(ToolCall(this.curToolId, this.curToolName, args))
        }
        return ModelResponse(this.text, this.toolCalls)
    }
}
