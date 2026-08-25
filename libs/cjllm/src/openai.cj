package cjllm

import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import std.collection.*
import std.io.*
import cjutil.*

/**
 * OpenAI 兼容协议实现（OpenAI / DeepSeek / 通义 / Moonshot 等均兼容）
 */
public class OpenAiProvider <: LlmProvider {
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
     * 设置采样参数（对齐 pi：temperature / max_tokens）
     */
    public func setSampling(temperature: Float64, maxTokens: Int64): Unit {
        this.temperature = temperature
        this.maxTokens = maxTokens
    }

    /**
     * 归一化端点：接受 base（https://api.deepseek.com）或完整路径，自动补全 /v1/chat/completions
     */
    public func endpointUrl(): String {
        var url = this.baseUrl
        if (url.endsWith("/")) {
            url = url[0..url.size - 1]
        }
        // base 已含 /v1 或 /v1/chat 时只补 /chat/completions；否则补 /v1/chat/completions
        if (!url.contains("/chat/completions")) {
            if (url.endsWith("/v1") || url.endsWith("/v1/chat")) {
                url += "/chat/completions"
            } else {
                url += "/v1/chat/completions"
            }
        }
        return url
    }

    /**
     * 提取 SNI 主机名：baseUrl → host（去协议/路径，如 https://taotoken.net/api/v1 → taotoken.net）
     */
    public func sniHost(): String {
        var url = this.baseUrl
        if (url.startsWith("https://")) {
            url = url[8..url.size]
        } else if (url.startsWith("http://")) {
            url = url[7..url.size]
        }
        var host = url
        if (let Some(slash) <- url.indexOf("/")) {
            host = url[0..slash]
        }
        // 去端口（host:port → host），SNI 只含主机名
        if (let Some(colon) <- host.indexOf(":")) {
            host = host[0..colon]
        }
        return host
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit): ModelResponse {
        // 构造请求体
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

        // 请求（base_url 自动补全 /v1/chat/completions 路径）
        // 显式加载系统根证书 + 设置 SNI：TlsClientConfig 默认不自动发 SNI，
        // 部分服务端（如 taotoken.net）在无 SNI 时返回不可信证书导致 unknown CA
        var tlsConfig = TlsClientConfig()
        tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
        tlsConfig.domain = Some(this.sniHost())
        // SSE 流式响应：readTimeout 是每次 read 的空闲超时（非绝对超时）
        // DeepSeek 长 completions chunk 持续到达，不会触发空闲超时
        // 网络卡住 60s 无新数据 → HttpTimeoutException → 保留已收数据
        let client = ClientBuilder()
            .tlsConfig(tlsConfig)
            .readTimeout(Duration.second * 60)
            .build()
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
                err = safeFromUtf8(errBuf[0..n])
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
        let modelResp = acc.finish()
        modelResp.timedOut = parser.timedOut
        return modelResp
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
