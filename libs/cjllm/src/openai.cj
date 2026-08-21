package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
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

    /**
     * 归一化端点：接受 base（https://api.deepseek.com）或完整路径，自动补全 /v1/chat/completions
     */
    public func endpointUrl(): String {
        var url = this.baseUrl
        if (url.endsWith("/")) {
            url = url[0..url.size - 1]
        }
        if (!url.contains("/chat/completions") && !url.endsWith("/v1") && !url.endsWith("/v1/chat")) {
            url += "/v1/chat/completions"
        }
        return url
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

        // 请求（base_url 自动补全 /v1/chat/completions 路径）
        let client = ClientBuilder().tlsConfig(TlsClientConfig()).build()
        let req = HttpRequestBuilder()
            .post()
            .url(this.endpointUrl())
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
