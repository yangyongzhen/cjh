package cjllm

import stdx.encoding.json.*
import std.sync.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.X509Certificate
import std.collection.*
import std.io.*
import std.env.*
import std.fs.*
import std.time.*
import cjutil.*

/**
 * OpenAI 兼容协议实现（OpenAI / DeepSeek / 通义 / Moonshot 等均兼容）
 */
public class OpenAiProvider <: LlmProvider {
    public let baseUrl: String
    public let apiKey: String
    public let model: String
    // 备用 key（P1-5 429 fallback）：401/429/5xx 时轮换重试，防限流中断任务
    public var fallbackKeys: ArrayList<String> = ArrayList<String>()
    public var temperature: Float64 = 0.7
    public var maxTokens: Int64 = 4096
    // 当前流式请求的 Client（abort 时 close 打断阻塞 read）
    private var currentClient: ?Client = None
    private var clientLock: Mutex = Mutex()

    public init(baseUrl: String, apiKey: String, model: String) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        // 预热已移除：stdx.net.http 的 ClientBuilder.send 会启动 readTimer 后台线程，
        // 即使请求已完成、client 实例被回收，readTimer 仍会在约 15 秒后超时触发
        // sendRequestTimeout WARN，该 WARN 写到 /dev/tty，绕过 Stderr.suppress()
        // 和 setGlobalLogger(NoopLogger())，污染 TUI 输入框。
        // warmup 只是省首次 TLS 冷启动的优化，不值得引入 WARN 污染。
        // 首次 chatStream 会正常建连，TLS 冷启动开销用户感知不明显。
    }

    public init(baseUrl: String, apiKey: String, model: String, fallbackKeys: ArrayList<String>) {
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        for (k in fallbackKeys) {
            if (k.size > 0) {
                this.fallbackKeys.add(k)
            }
        }
    }

    /**
     * 全部 key（主 key + 备用），轮换顺序
     */
    public func allKeys(): ArrayList<String> {
        var keys = ArrayList<String>()
        keys.add(this.apiKey)
        for (k in this.fallbackKeys) {
            keys.add(k)
        }
        return keys
    }

    /**
     * V2d 连接预热（已禁用）
     *
     * 保留函数体供未来可能的替代预热方案复用，但 init 不再调用。
     * 原因：stdx.net.http 的 ClientBuilder.send 会启动 readTimer 后台线程，
     * 即使请求已完成、client 实例被回收，readTimer 仍会超时触发
     * sendRequestTimeout WARN，该 WARN 写到 /dev/tty，绕过所有 fd 重定向，
     * 污染 TUI 输入框。
     */
    /**
     * 中止当前流式请求：关闭连接打断阻塞的流读取（用户中断时由 agent 调用）
     */
    public func abort(): Unit {
        this.clientLock.lock()
        let c = this.currentClient
        this.clientLock.unlock()
        match (c) {
            case Some(cl) =>
                try {
                    cl.close()
                } catch (e: Exception) {
                    // 关闭失败忽略（连接可能已结束）
                }
            case None => ()
        }
    }

    public func warmup(): Unit {
        try {
            var tlsConfig = TlsClientConfig()
            tlsConfig.verifyMode = CertificateVerifyMode.CustomCA(X509Certificate.systemRootCerts())
            tlsConfig.domain = Some(this.sniHost())
            let client = ClientBuilder()
                .tlsConfig(tlsConfig)
                .build()
            var modelsUrl = this.baseUrl
            if (modelsUrl.endsWith("/")) {
                modelsUrl = modelsUrl[0..modelsUrl.size - 1]
            }
            if (!modelsUrl.endsWith("/v1")) {
                modelsUrl += "/v1"
            }
            modelsUrl += "/models"
            let req = HttpRequestBuilder()
                .get()
                .url(modelsUrl)
                .header("Authorization", "Bearer ${this.apiKey}")
                .build()
            let _ = client.send(req)
        } catch (e: Exception) {
            // 预热失败静默
        }
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
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
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
        // SSE 流式响应：readTimeout 是"读取一个响应的最大时长"——绝对超时
        // DeepSeek 长 completions 思考阶段可能 >60s 才到第一个 chunk，
        // 故放宽到 10 分钟，避免长任务被切断导致最后一帧 usage 丢失（token=0）
        // 注：readTimer 在请求正常完成后会被取消，不会触发 WARN；
        // 只有 warmup 那种"fire and forget"的请求才会让 readTimer 跑到超时
        // Client 不能缓存复用：stdx.net.http 的 Client 在 send 完成后会被关闭，
        // 复用已关闭的 Client 会报 "send body failed, since closed"
        let client = ClientBuilder()
            .tlsConfig(tlsConfig)
            .readTimeout(Duration.second * 300)
            .build()
        // 保存当前 client（abort 时 close）
        this.clientLock.lock()
        this.currentClient = Some(client)
        this.clientLock.unlock()

        // P1-5 key 轮换：401/429/5xx → 换备用 key 重试（防限流中断任务）
        let keys = this.allKeys()
        var lastErr = ""
        for (ki in 0..keys.size) {
            let key = keys[ki]
            let req = HttpRequestBuilder()
                .post()
                .url(this.endpointUrl())
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer ${key}")
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
                lastErr = "HTTP ${status}: ${err}"
                // 认证/限流/服务端错误：换 key 重试；其他 4xx 业务错误直接抛出
                if (status == 401 || status == 429 || status >= 500) {
                    if (ki < keys.size - 1) {
                        continue  // 换下一个 key
                    }
                }
                throw LlmException(lastErr)
            }

        // SSE 解析
        let acc = StreamAccumulator()
        // prompt token 估算：消息历史字符数 / 4（混合中英文经验值）
        var promptChars: Int64 = 0
        for (m in messages) {
            promptChars += Int64(m.content.size)
        }
        acc.estimatedPromptTokens = promptChars / 4
        let parser = SseParser(resp.body)
        parser.onEvent = { data =>
            // 用户 Ctrl+C 中断：提前结束流解析（保留已收内容）
            if (isCancelled()) {
                parser.cancel()
                return
            }
            acc.feed(data)
            // 实时回调文本增量（仅新增部分）
            let delta = acc.takeDelta()
            if (delta.size > 0) {
                onDelta(delta)
            }
        }
        // 思考增量回调：reasoning_content 实时推给调用方
        // glm-5.3-flash 等模型先输出大量 reasoning_content，不显示会让用户干等
        acc.onReasoningDelta = { r =>
            onReasoning(r)
        }
        // token 实时估算回调：流式逐帧粗估，usage 最后一帧回传精确值后由 finish() 覆盖
        acc.onTokenEstimate = onTokenEstimate
        parser.run()
        let modelResp = acc.finish()
        modelResp.timedOut = parser.timedOut
        return modelResp
            }  // for key 轮换循环
        // 不可达兜底：循环内 200 已 return，所有 key 失败已 throw
        throw LlmException(lastErr)
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
