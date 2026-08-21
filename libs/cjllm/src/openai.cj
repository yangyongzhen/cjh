package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import std.collection.*
import std.io.*

/**
 * OpenAI 兼容协议实现（OpenAI / DeepSeek / 通义 / Moonshot 等均兼容）
 */
public class OpenAiProvider <: LlmProvider {
    public let baseUrl: String
    public let apiKey: String
    public let model: String

    public init(baseUrl: String, apiKey: String, model: String) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit): ModelResponse {
        // 构造请求体
        var body = JsonObject()
        body.put("model", JsonString(this.model))
        body.put("stream", JsonBool(true))

        var msgList = ArrayList<JsonValue>()
        for (m in messages) {
            msgList.add(m.toOpenAiJson())
        }
        body.put("messages", JsonArray(msgList))

        if (tools.size > 0) {
            var toolList = ArrayList<JsonValue>()
            for (t in tools) {
                toolList.add(t.toOpenAiJson())
            }
            body.put("tools", JsonArray(toolList))
        }

        // 请求
        let client = ClientBuilder().build()
        let req = HttpRequestBuilder()
            .post()
            .url(this.baseUrl)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer ${this.apiKey}")
            .body(body.toJsonString())
            .build()

        let resp = client.send(req)
        let status = resp.status
        if (status != 200) {
            // 读取错误体
            var errBuf = Array<Byte>(4096, repeat: 0)
            var err = ""
            let n = resp.body.read(errBuf)
            if (n > 0) {
                err = String.fromUtf8(errBuf[0..n])
            }
            throw LlmException("HTTP ${status}: ${err}")
        }

        // SSE 解析
        let acc = StreamAccumulator()
        let parser = SseParser(resp.body)
        parser.onEvent = { data =>
            acc.feed(data)
            // 实时回调文本增量（仅新增部分）
            let delta = acc.takeDelta()
            if (delta.size > 0) {
                onDelta(delta)
            }
        }
        parser.run()
        return acc.finish()
    }
}

/**
 * LLM 调用异常
 */
public class LlmException <: Exception {
    public init(msg: String) {
        super(msg)
    }
}
