package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import std.collection.*
import std.io.*

/**
 * Ollama 本地模型 Provider（V3b：解锁离线场景）
 *
 * 设计：Ollama 自 v0.3 起原生支持 OpenAI 兼容端点 /v1/chat/completions，
 * 且支持 tools 流式调用。因此 OllamaProvider 直接复用 OpenAI SSE 协议
 * （StreamAccumulator + SseParser），仅在两点适配本地 Ollama 服务：
 *
 * 1. endpointUrl：Ollama 默认 http://localhost:11434/v1，需正确补全
 *    /chat/completions（baseUrl 可能是 http://localhost:11434 或
 *    http://localhost:11434/v1，两种都要支持）
 * 2. 认证：本地 Ollama 不需认证，apiKey 为空时跳过 Authorization 头；
 *    apiKey 非空时仍发送（适配启用了 Ollama 网关认证的场景）
 *
 * 协议：HTTP（非 HTTPS）。本地服务无需 TLS，TLS 配置反而会导致
 * "unknown CA" 或 SNI 不匹配。故 chatStream 不设置 TlsClientConfig。
 *
 * 失败模式：Ollama 服务未启动时，client.send 会抛连接异常，
 * 由上层 makeProvider → agent.run 捕获并提示 "是否启动 ollama serve？"
 */
public class OllamaProvider <: LlmProvider {
    public let baseUrl: String
    public let apiKey: String
    public let model: String
    public var temperature: Float64 = 0.7
    public var maxTokens: Int64 = 4096

    public init(baseUrl: String, apiKey: String, model: String) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
    }

    /**
     * 设置采样参数（对齐 OpenAiProvider.setSampling）
     */
    public func setSampling(temperature: Float64, maxTokens: Int64): Unit {
        this.temperature = temperature
        this.maxTokens = maxTokens
    }

    /**
     * 归一化端点：baseUrl → http://host:port/v1/chat/completions
     * 接受的 baseUrl 形态：
     *   - http://localhost:11434         → 补 /v1/chat/completions
     *   - http://localhost:11434/v1      → 补 /chat/completions
     *   - http://localhost:11434/v1/chat → 补 /completions
     *   - http://localhost:11434/v1/chat/completions → 原样
     */
    public func endpointUrl(): String {
        var url = this.baseUrl
        if (url.endsWith("/")) {
            url = url[0..url.size - 1]
        }
        if (!url.contains("/chat/completions")) {
            if (url.endsWith("/v1") || url.endsWith("/v1/chat")) {
                url += "/chat/completions"
            } else if (url.endsWith("/chat")) {
                url += "/completions"
            } else {
                // 裸 host:port，补 /v1/chat/completions
                url += "/v1/chat/completions"
            }
        }
        return url
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit): ModelResponse {
        // 构造请求体（与 OpenAiProvider 一致）
        var body = JsonObject()
        body.put("model", JsonString(this.model))
        body.put("stream", JsonBool(true))
        body.put("temperature", JsonFloat(this.temperature))
        body.put("max_tokens", JsonInt(this.maxTokens))

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

        // 本地 Ollama 走 HTTP，不设置 TLS（TLS 配置会导致 SNI/证书不匹配）
        let client = ClientBuilder().build()
        let reqBuilder = HttpRequestBuilder()
            .post()
            .url(this.endpointUrl())
            .header("Content-Type", "application/json")
        // apiKey 为空时跳过 Authorization（本地 Ollama 默认无认证）
        if (this.apiKey.size > 0) {
            reqBuilder.header("Authorization", "Bearer ${this.apiKey}")
        }
        let req = reqBuilder.body(body.toJsonString()).build()

        let resp = client.send(req)
        let status = resp.status
        if (status != 200) {
            var errBuf = Array<Byte>(4096, repeat: 0)
            var err = ""
            let n = resp.body.read(errBuf)
            if (n > 0) {
                err = safeFromUtf8(errBuf[0..n])
            }
            throw LlmException("Ollama HTTP ${status}: ${err}")
        }

        // SSE 解析（复用 OpenAI 兼容的 StreamAccumulator + SseParser）
        let acc = StreamAccumulator()
        let parser = SseParser(resp.body)
        parser.onEvent = { data =>
            acc.feed(data)
            let delta = acc.takeDelta()
            if (delta.size > 0) {
                onDelta(delta)
            }
        }
        parser.run()
        return acc.finish()
    }
}
