package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjcfg.*
import cjllm.*
import cjh.agent.*
import cjh.gateway.*
import cjh.tools.*

/**
 * 服务商失败路径测试（issue #4 复现）
 *
 * 现象：chat 帧内覆盖了 model/base_url/api_key（覆盖本身生效），但上游端点打不通时，
 * 客户端收到的是「没有任何增量、也没有 error 帧」的收尾——只有一个空 done，
 * 拿不到 code，只能显示空回复。
 *
 * 根因在 agent：请求阶段异常被吞成 `summary.reply` 后正常返回，渠道无从知道这一轮失败了。
 * 本文件钉住两层契约：
 *   1. Agent 层：上游失败必须在 RunSummary 上留下结构化信号（code / message / retryable），
 *      且正常路径与「中断」路径不得误报；
 *   2. 网关层：回合失败必须推 error 帧（带 code）并照发 done（finish_reason=error），
 *      且 error 与 done 属于同一回合身份。
 */

/**
 * 端点打不通的 provider 替身：chatStream 直接抛异常
 *
 * 模拟 base_url 不可达 / 401 / HTTP 5xx 等上游失败——失败发生在**请求阶段**，
 * 因此本回合不会有任何 delta。
 */
public class DeadEndpointProvider <: LlmProvider {
    private let message: String
    public var calls: Int64 = 0

    public init(message: String) {
        this.message = message
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        _: (String) -> Unit, _: (String) -> Unit,
        _: (Int64) -> Unit, _: () -> Bool): ModelResponse {
        this.calls += 1
        throw Exception(this.message)
    }
}

/**
 * ProviderFactory 替身：resolve 一律成功（帧内端点原样生效），create 给出「打不通的 provider」
 *
 * 对齐 issue #4 的复现：覆盖字段生效（所以走的是覆盖后的 provider），
 * 失败点是请求打不出去——不是模型解析失败（那条路径已由 model_unavailable 覆盖）。
 */
public class DeadEndpointFactory <: ProviderFactory {
    private let message: String

    public init(message: String) {
        this.message = message
    }

    public func resolve(model: String, baseUrl: String, apiKey: String): ModelTarget {
        let target = ModelTarget()
        target.model = if (model.size > 0) { model } else { "dead-model" }
        target.baseUrl = if (baseUrl.size > 0) { baseUrl } else { "http://127.0.0.1:9/v1/chat/completions" }
        target.apiKey = if (apiKey.size > 0) { apiKey } else { "sk-unused" }
        return target
    }

    public func create(_: ModelTarget): LlmProvider {
        return DeadEndpointProvider(this.message)
    }
}

/**
 * 构造只挂只读工具的 Agent（失败发生在 LLM 请求阶段，工具用不到）
 */
func buildDeadAgent(spillDir: String, message: String, sessionId: String): Agent {
    let registry = ToolRegistry()
    registry.register(ReadTool())
    let config = AgentConfig("provider 失败测试", 2, Capability(), 0, 0, 6, 2000, spillDir, sessionId)
    return Agent(DeadEndpointProvider(message), registry, config)
}

/**
 * @Test 类：Agent 层的失败信号
 */
@Test
public class ProviderFailureSummaryTest {

    @TestCase
    public func testUnreachableEndpointReportsCode(): Unit {
        // 连接打不通：如实报「连不上」，且可重试（换端点/网络恢复后重发有意义）
        let dir = testTempDir("provfail_conn")
        let agent = buildDeadAgent(dir, "Connection refused: 无法连接到 127.0.0.1:9", "sess-prov-1")
        let summary = agent.run("回复 OK")
        @Assert(summary.errorCode, "provider_unreachable")
        @Assert(summary.errorMessage.size > 0, true)
        @Assert(summary.errorRetryable, true)
    }

    @TestCase
    public func testHttpErrorMapsToProviderError(): Unit {
        // 连上了但上游报错（4xx/5xx / 响应解析失败）：与"连不上"区分开，码不同
        let dir = testTempDir("provfail_http")
        let agent = buildDeadAgent(dir, "HTTP 500 Internal Server Error from upstream", "sess-prov-2")
        let summary = agent.run("回复 OK")
        @Assert(summary.errorCode, "provider_error")
        @Assert(summary.errorRetryable, true)
    }

    @TestCase
    public func testNormalRunHasNoErrorSignal(): Unit {
        // 正常路径不许报警：没有失败信号 = 渠道照常发 done(stop)
        let dir = testTempDir("provfail_ok")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let registry = ToolRegistry()
        registry.register(ReadTool())
        let config = AgentConfig("provider 正常路径", 2, Capability(), 0, 0, 6, 2000, dir, "sess-prov-3")
        let agent = Agent(MockProvider(dir + "/mock.txt"), registry, config)
        let summary = agent.run("你好")
        @Assert(summary.errorCode, "")
        @Assert(summary.errorMessage, "")
        @Assert(summary.errorRetryable, false)
    }
}

/**
 * @Test 类：网关层的 error 帧契约（issue #4 的 observable 行为）
 */
@Test
public class GatewayProviderFailureTest {

    private func buildFailGateway(dir: String, message: String): ChannelGateway {
        let cfg = CjhConfig()
        cfg.systemPrompt = "provider 失败测试"
        cfg.maxIterations = 2
        let registry = ToolRegistry()
        registry.register(ReadTool())
        let provider = MockProvider(dir + "/mock.txt")
        return ChannelGateway(cfg, provider, registry, Some(DeadEndpointFactory(message)))
    }

    @TestCase
    public func testChatOverrideDeadEndpointEmitsErrorFrame(): Unit {
        // issue #4 的 B 轮：帧内覆盖指向死端点 → 必须回 error{code} + done(finish_reason=error)
        let dir = testTempDir("gw_provfail_override")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = this.buildFailGateway(dir, "Connection refused: 无法连接到 127.0.0.1:9")
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "回复 OK",
            Some(ModelOverride("probe-model-xyz", "http://127.0.0.1:9/v1/chat/completions", "sk-dead")))
        waitForEvents(ch, 5000)
        // 失败不静默：一个 error 帧，带 code 与 retryable
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "provider_unreachable")
        @Assert(ch.errors[0].retryable, true)
        @Assert(ch.errors[0].message.size > 0, true)
        // 终局信号照发：done 仍只有一个，且 reason=error
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "error")
        // error 与 done 同属一回合：身份齐备且一致
        @Assert(ch.errorMetas.size, 1)
        @Assert(ch.errorMetas[0].turnId.size > 0, true)
        @Assert(ch.errorMetas[0].turnId, ch.metas[ch.metas.size - 1].turnId)
    }

    @TestCase
    public func testChatWithHttpErrorOverrideEmitsProviderError(): Unit {
        // 上游 5xx：码要能区分（客户端据此决定"重试"还是"换个模型/端点"）
        let dir = testTempDir("gw_provfail_http")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = this.buildFailGateway(dir, "HTTP 500 Internal Server Error from upstream")
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "回复 OK",
            Some(ModelOverride("probe-model-xyz", "https://api.example.com/v1/chat/completions", "sk-bad")))
        waitForEvents(ch, 5000)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "provider_error")
        @Assert(ch.errors[0].retryable, true)
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "error")
    }

    @TestCase
    public func testChatWithAuthErrorOverrideEmitsAuthCode(): Unit {
        // 密钥错（401）：重试无用 → retryable=false，客户端该提示"检查配置"而不是"重试"
        let dir = testTempDir("gw_provfail_auth")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = this.buildFailGateway(dir, "HTTP 401 Unauthorized from upstream")
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "回复 OK",
            Some(ModelOverride("probe-model-xyz", "https://api.example.com/v1/chat/completions", "sk-bad")))
        waitForEvents(ch, 5000)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "provider_auth_error")
        @Assert(ch.errors[0].retryable, false)
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "error")
    }

    @TestCase
    public func testChatWithoutOverrideUsesOwnProvider(): Unit {
        // issue #4 的 C 轮对照：不带覆盖 = 走服务端自己的配置（MockProvider）→ 正常收尾
        let dir = testTempDir("gw_provfail_plain")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = this.buildFailGateway(dir, "Connection refused")
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "你好", None)
        waitForEvents(ch, 10000)
        @Assert(ch.errors.size, 0)
        @Assert(ch.dones > 0, true)
        @Assert(ch.doneReasons[0], "stop")
    }
}

/**
 * @Test 类：失败分类（纯函数，客户端拿到的 code/retryable 由这里定）
 */
@Test
public class ProviderFailureClassifyTest {

    @TestCase
    public func testConnectionRefusedIsUnreachable(): Unit {
        let info = classifyProviderFailure("Connection refused: 无法连接到 127.0.0.1:9")
        @Assert(info.code, "provider_unreachable")
        @Assert(info.retryable, true)
    }

    @TestCase
    public func testChineseTransportMessageIsUnreachable(): Unit {
        // cjllm 传输层的中文文案（连接关闭（读响应头 EOF））同样要判成"连不上"
        let info = classifyProviderFailure("HttpTransportException: 连接关闭（读响应头 EOF）")
        @Assert(info.code, "provider_unreachable")
    }

    @TestCase
    public func testPortNumberIsNotMistakenForAuthError(): Unit {
        // 裸数字陷阱：端口 9401 里的 "401" 不许被判成鉴权失败（只认 "http 401" 这类带前缀形式）
        let info = classifyProviderFailure("Connection refused: 无法连接到 127.0.0.1:9401")
        @Assert(info.code, "provider_unreachable")
    }

    @TestCase
    public func testAuthErrorHidesUpstreamText(): Unit {
        // 鉴权失败不回显上游原文：原文常回显 api_key，进了帧就等于泄漏到客户端与日志
        let info = classifyProviderFailure("HTTP 401 Unauthorized: invalid api key sk-secret123")
        @Assert(info.code, "provider_auth_error")
        @Assert(info.retryable, false)
        @Assert(info.message.contains("sk-secret123"), false)
    }

    @TestCase
    public func testRateLimitedIsRetryable(): Unit {
        let info = classifyProviderFailure("HTTP 429 Too Many Requests")
        @Assert(info.code, "provider_rate_limited")
        @Assert(info.retryable, true)
    }

    @TestCase
    public func testClientErrorIsNotRetryable(): Unit {
        // 4xx 参数类：原样重试没用（改配置/改请求才行）
        let info = classifyProviderFailure("HTTP 400 Bad Request: invalid tools schema")
        @Assert(info.code, "provider_error")
        @Assert(info.retryable, false)
    }

    @TestCase
    public func testLongChineseMessageIsCappedSafely(): Unit {
        // 超长中文异常文案：截断必须走 UTF-8 安全切片（否则在多字节字符中间炸）
        let sb = StringBuilder()
        for (i in 0..200) {
            sb.append("中")
        }
        let info = classifyProviderFailure("连接超时: " + sb.toString())
        @Assert(info.code, "provider_unreachable")
        @Assert(info.message.size <= 400, true)
    }
}
