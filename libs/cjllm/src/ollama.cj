package cjllm

import stdx.encoding.json.*
import std.collection.*
import std.io.*
import std.sync.*
import std.net.*
import cjutil.*

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
    private var currentTransport: ?HttpStreamClient = None
    private var clientLock: Mutex = Mutex()
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

    public func abort(): Unit {
        this.clientLock.lock()
        let t = this.currentTransport
        this.clientLock.unlock()
        match (t) {
            case Some(tr) =>
                try { tr.abort() } catch (e: Exception) { }
            case None => ()
        }
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
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

        // 传输层：std.net 直连（本地 HTTP，无 TLS），per-read 60s 空闲超时
        let (host, port, path, useTls) = splitEndpoint(this.endpointUrl())
        let transport = HttpStreamClient(host, port, useTls)
        transport.readTimeout = defaultIdleTimeout()
        this.clientLock.lock()
        this.currentTransport = Some(transport)
        this.clientLock.unlock()
        transport.connect()
        var hdrs = ArrayList<(String, String)>()
        hdrs.add(("Content-Type", "application/json"))
        // apiKey 为空时跳过 Authorization（本地 Ollama 默认无认证）
        if (this.apiKey.size > 0) {
            hdrs.add(("Authorization", "Bearer ${this.apiKey}"))
        }
        transport.request("POST", path, hdrs, body.toJsonString())
        let (status, _) = transport.readResponseHead()
        if (status != 200) {
            var errBuf = Array<Byte>(4096, repeat: 0)
            var err = ""
            try {
                let n = transport.readBody(errBuf)
                if (n > 0) {
                    err = safeFromUtf8(errBuf[0..n])
                }
            } catch (e: Exception) {
                // 读错误体失败忽略
            }
            transport.close()
            throw LlmException("Ollama HTTP ${status}: ${err}")
        }

        // SSE 解析（复用 OpenAI 兼容的 StreamAccumulator + SseParser）
        let acc = StreamAccumulator()
        // prompt token 估算：消息历史字符数 / 4
        var promptChars: Int64 = 0
        for (m in messages) {
            promptChars += Int64(m.content.size)
        }
        acc.estimatedPromptTokens = promptChars / 4
        acc.onTokenEstimate = onTokenEstimate
        let parser = SseParser(HttpStreamInput(transport))
        parser.onEvent = { data =>
            // 用户 Ctrl+C 中断：提前结束流解析（保留已收内容）
            if (isCancelled()) {
                parser.cancel()
                return
            }
            acc.feed(data)
            let delta = acc.takeDelta()
            if (delta.size > 0) {
                onDelta(delta)
            }
        }
        parser.run()
        transport.close()
        return acc.finish()
    }
}
