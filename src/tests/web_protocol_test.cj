package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjcfg.*
import cjllm.*
import cjh.gateway.*
import cjh.tools.*
import cjh.web.*

/**
 * WS 协议扩展单元测试（模型覆盖 / 控制帧回执 / 结构化错误）
 *
 * 覆盖点（对齐客户端约定）：
 *   1. chat 帧可选 model/base_url/api_key：snake_case 与 camelCase 都认，缺省 = 旧行为
 *   2. switch_model 帧：带端点/密钥解析，回 ack（含解析后的 model + base_url）
 *   3. 控制帧禁止静默：switch_model / compact / cancel 必有 ack 或 error
 *   4. error 带 code / retryable：客户端据此决定重试或换模型
 *
 * 测试通过 execute 级别的 observable 契约断言（Channel 收到的 ack / error），
 * 不触碰私有实现。
 */

/**
 * 捕获事件用渠道替身：只记录 gateway 推来的事件，不打网络、不落盘
 */
public class CaptureChannel <: Channel {
    public var acks: ArrayList<AckInfo> = ArrayList<AckInfo>()
    public var cancelleds: ArrayList<CancelledInfo> = ArrayList<CancelledInfo>()
    public var errors: ArrayList<CapturedError> = ArrayList<CapturedError>()
    public var deltas: String = ""
    public var dones: Int64 = 0
    public var histories: Int64 = 0
    public var tasks: Int64 = 0
    // 回合级事件携带的帧身份（按到达顺序记录，用于断言"同一回合同一组 id"）
    public var metas: ArrayList<FrameMeta> = ArrayList<FrameMeta>()
    // done 的结束原因（按到达顺序）
    public var doneReasons: ArrayList<String> = ArrayList<String>()
    // done 帧原始 JSON（按到达顺序）：可选键（如 truncated）的存在性只能靠原文断言，
    // 因为"缺键"与"值为 false"在取值辅助函数下长得一样
    public var doneRawJson: ArrayList<String> = ArrayList<String>()
    // 错误事件的帧身份（与 errors 一一对应）
    public var errorMetas: ArrayList<FrameMeta> = ArrayList<FrameMeta>()
    // 审批请求（危险操作前网关推来；测试据此答复或放任超时）
    public var approvals: ArrayList<ApprovalRequestInfo> = ArrayList<ApprovalRequestInfo>()
    // 工具结果（按到达顺序；三个列表一一对应）
    public var toolNames: ArrayList<String> = ArrayList<String>()
    public var toolResultTexts: ArrayList<String> = ArrayList<String>()
    public var toolResultErrors: ArrayList<Bool> = ArrayList<Bool>()
    // 工具结果携带的结构化 diff（与上面三个列表一一对应；非文件工具为 None）
    public var toolResultDiffs: ArrayList<?DiffInfo> = ArrayList<?DiffInfo>()

    public func channelId(): String {
        return "test"
    }

    public func sendDelta(_: String, meta: FrameMeta, text: String): Unit {
        this.metas.add(meta)
        this.deltas += text
    }

    public func sendToolStart(_: String, meta: FrameMeta, _: String, _: JsonObject): Unit {
        this.metas.add(meta)
    }

    public func sendToolResult(_: String, meta: FrameMeta, name: String, result: String,
        isError: Bool, diff: ?DiffInfo): Unit {
        this.metas.add(meta)
        this.toolNames.add(name)
        this.toolResultTexts.add(result)
        this.toolResultErrors.add(isError)
        this.toolResultDiffs.add(diff)
    }

    public func sendDone(_: String, meta: FrameMeta, summary: JsonObject): Unit {
        this.dones += 1
        this.metas.add(meta)
        this.doneReasons.add(getStr(summary, "finish_reason"))
        // 原文一并留存：可选键（truncated）的"缺键 vs 值为 false"只有原文能区分
        this.doneRawJson.add(summary.toString())
    }

    public func sendError(_: String, message: String): Unit {
        this.errors.add(CapturedError(message, "", false))
    }

    public func sendErrorCode(_: String, meta: FrameMeta, message: String, code: String,
        retryable: Bool): Unit {
        this.errors.add(CapturedError(message, code, retryable))
        this.errorMetas.add(meta)
    }

    public func sendAck(_: String, ack: AckInfo): Unit {
        this.acks.add(ack)
    }

    public func sendCancelled(_: String, info: CancelledInfo): Unit {
        this.cancelleds.add(info)
    }

    public func sendHistory(_: String, _: String, _: JsonArray): Unit {
        this.histories += 1
    }

    public func sendTasks(_: String, _: JsonArray): Unit {
        this.tasks += 1
    }

    public func sendApprovalRequest(_: String, info: ApprovalRequestInfo): Unit {
        this.approvals.add(info)
    }
}

/**
 * 捕获到的错误事件（content 三要素：message / code / retryable）
 */
public class CapturedError {
    public var message: String = ""
    public var code: String = ""
    public var retryable: Bool = false

    public init(message: String, code: String, retryable: Bool) {
        this.message = message
        this.code = code
        this.retryable = retryable
    }
}

/**
 * ProviderFactory 替身：模型名 → 端点映射，指定模型解析失败
 *
 * @param failModel 非空时该模型解析失败（用于错误路径）
 */
public class StubProviderFactory <: ProviderFactory {
    private let failModel: String
    private let created: ArrayList<String> = ArrayList<String>()

    public init(failModel: String) {
        this.failModel = failModel
    }

    public func resolve(model: String, baseUrl: String, apiKey: String): ModelTarget {
        let target = ModelTarget()
        let want = if (model.size > 0) { model } else { "stub-default" }
        if (want == this.failModel) {
            target.error = "模型 ${want} 未在配置中，无法解析端点"
            return target
        }
        target.model = want
        target.baseUrl = if (baseUrl.size > 0) { baseUrl } else { "http://stub.local/v1/chat/completions" }
        target.apiKey = if (apiKey.size > 0) { apiKey } else { "stub-key" }
        return target
    }

    public func create(target: ModelTarget): LlmProvider {
        this.created.add(target.model)
        return MockProvider("/tmp/cjh_ut_gw_ctrl_mock.txt")
    }

    /**
     * 已构造的 provider 对应的模型名（断言"真的建过 provider"）
     */
    public func createdModels(): ArrayList<String> {
        return this.created
    }
}

/**
 * 构造隔离的网关（provider 用 MockProvider，不触网）
 *
 * 说明：sessionsDir / spillDir 是 CjhConfig 的 let（由 CJH_CONFIG_DIR 决定，不可就地改），
 * 而本测试只用控制帧与 MockProvider，createSession 不落盘（newSessionId 纯计算），
 * 因此无需额外隔离配置目录；测试自身产物一律写在 testTempDir 下。
 */
func buildGateway(dir: String, factory: ?ProviderFactory): ChannelGateway {
    let cfg = CjhConfig()
    cfg.systemPrompt = "控制帧测试"
    cfg.maxIterations = 4
    let registry = ToolRegistry()
    registry.register(ReadTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    let provider = MockProvider(dir + "/mock.txt")
    return ChannelGateway(cfg, provider, registry, factory)
}

/**
 * 轮询等待异步回合产生事件（上限 waitMs，避免慢机器误判为"没反应"）
 */
func waitForEvents(ch: CaptureChannel, waitMs: Int64): Unit {
    var waited: Int64 = 0
    while (ch.errors.size == 0 && ch.dones == 0 && waited < waitMs) {
        sleep(Duration.millisecond * 10)
        waited += 10
    }
}

/**
 * 协议帧解析（纯函数）
 */
@Test
public class WebProtocolFrameTest {

    @TestCase
    public func testChatRequestParsesSnakeCaseOverride(): Unit {
        let obj = JsonObject()
        obj.put("message", JsonString("你好"))
        obj.put("model", JsonString("m-fast"))
        obj.put("base_url", JsonString("https://api.example.com/v1/chat/completions"))
        obj.put("api_key", JsonString("sk-test"))
        let req = ChatRequest.fromJson(obj)
        @Assert(req.message, "你好")
        @Assert(req.hasModelOverride(), true)
        @Assert(req.model, "m-fast")
        @Assert(req.baseUrl, "https://api.example.com/v1/chat/completions")
        @Assert(req.apiKey, "sk-test")
    }

    @TestCase
    public func testChatRequestParsesCamelCaseOverride(): Unit {
        let obj = JsonObject()
        obj.put("message", JsonString("hi"))
        obj.put("baseUrl", JsonString("http://localhost:11434/v1"))
        obj.put("apiKey", JsonString("k2"))
        let req = ChatRequest.fromJson(obj)
        @Assert(req.baseUrl, "http://localhost:11434/v1")
        @Assert(req.apiKey, "k2")
        @Assert(req.model, "")
    }

    @TestCase
    public func testChatRequestWithoutOverrideIsBackwardCompatible(): Unit {
        // 老客户端只发 message：不得被"覆盖"污染（行为与改造前一致）
        let obj = JsonObject()
        obj.put("message", JsonString("hi"))
        let req = ChatRequest.fromJson(obj)
        @Assert(req.hasModelOverride(), false)
        match (req.modelOverride()) {
            case Some(_) => @Assert(false, true)
            case None => @Assert(true, true)
        }
    }

    @TestCase
    public func testChatRequestIgnoresMalformedAndUnknownFields(): Unit {
        // model 给成数字、未知字段、空串：不崩、不误判为覆盖
        let obj = JsonObject()
        obj.put("message", JsonString("hi"))
        obj.put("model", JsonInt(7))
        obj.put("whatever", JsonString("x"))
        obj.put("base_url", JsonString(""))
        let req = ChatRequest.fromJson(obj)
        @Assert(req.message, "hi")
        @Assert(req.model, "")
        @Assert(req.baseUrl, "")
        @Assert(req.hasModelOverride(), false)
    }

    @TestCase
    public func testSwitchModelRequestParsesSnakeAndCamel(): Unit {
        var obj = JsonObject()
        obj.put("model", JsonString("m1"))
        obj.put("base_url", JsonString("https://a/v1"))
        obj.put("api_key", JsonString("k1"))
        let r1 = SwitchModelRequest.fromJson(obj)
        @Assert(r1.model, "m1")
        @Assert(r1.baseUrl, "https://a/v1")
        @Assert(r1.apiKey, "k1")

        var obj2 = JsonObject()
        obj2.put("model", JsonString("m2"))
        obj2.put("baseUrl", JsonString("https://b/v1"))
        obj2.put("apiKey", JsonString("k2"))
        let r2 = SwitchModelRequest.fromJson(obj2)
        @Assert(r2.model, "m2")
        @Assert(r2.baseUrl, "https://b/v1")
        @Assert(r2.apiKey, "k2")
    }

    @TestCase
    public func testSwitchModelRequestModelOnly(): Unit {
        // 只给 model（端点交给服务端按配置补齐）是合法用法，不得报错
        var obj = JsonObject()
        obj.put("model", JsonString("m3"))
        let req = SwitchModelRequest.fromJson(obj)
        @Assert(req.model, "m3")
        @Assert(req.baseUrl, "")
        @Assert(req.apiKey, "")
    }

    @TestCase
    public func testAckEventJsonShape(): Unit {
        let event = AckEvent("switch_model")
        event.sessionId = "s1.2.3"
        event.model = "m9"
        event.baseUrl = "https://x/v1"
        event.compacted = true
        event.messagesBefore = 12
        event.messagesAfter = 3
        let parsed = JsonValue.fromStr(event.toJson()).asObject()
        @Assert(getStr(parsed, "type"), "ack")
        @Assert(getStr(parsed, "action"), "switch_model")
        @Assert(getStr(parsed, "session_id"), "s1.2.3")
        @Assert(getStr(parsed, "model"), "m9")
        @Assert(getStr(parsed, "base_url"), "https://x/v1")
        @Assert(getBool(parsed, "compacted"), true)
        @Assert(getInt(parsed, "messages_before"), 12)
        @Assert(getInt(parsed, "messages_after"), 3)
    }

    @TestCase
    public func testCancelledEventJsonShape(): Unit {
        let event = CancelledEvent("s9.8.7", true)
        let parsed = JsonValue.fromStr(event.toJson()).asObject()
        @Assert(getStr(parsed, "type"), "cancelled")
        @Assert(getStr(parsed, "session_id"), "s9.8.7")
        @Assert(getBool(parsed, "was_running"), true)
    }

    @TestCase
    public func testErrorEventCarriesCodeAndRetryable(): Unit {
        let plain = ErrorEvent("旧形状")
        let p1 = JsonValue.fromStr(plain.toJson()).asObject()
        @Assert(getStr(p1, "code"), "internal")
        @Assert(getBool(p1, "retryable"), false)

        let coded = ErrorEvent("Provider 连接失败", "provider_error", true)
        let p2 = JsonValue.fromStr(coded.toJson()).asObject()
        @Assert(getStr(p2, "message"), "Provider 连接失败")
        @Assert(getStr(p2, "code"), "provider_error")
        @Assert(getBool(p2, "retryable"), true)
    }
}

/**
 * 网关控制帧（switch_model / compact / cancel）：禁止静默，必有回执
 */
@Test
public class GatewayControlFrameTest {

    @TestCase
    public func testSwitchModelWithoutFactoryReportsUnsupported(): Unit {
        // 无工厂 = 服务端不支持切模型：必须明确报错，不能静默丢帧
        let dir = testTempDir("gw_ctrl_no_factory")
        let gateway = buildGateway(dir, None)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleSwitchModel("test", "chat1", "some-model", "", "")
        @Assert(ch.acks.size, 0)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "switch_model_unsupported")
        @Assert(ch.errors[0].retryable, false)
        @Assert(ch.errors[0].message.size > 0, true)
    }

    @TestCase
    public func testSwitchModelAcksResolvedTarget(): Unit {
        let dir = testTempDir("gw_ctrl_switch")
        let factory = StubProviderFactory("")
        let gateway = buildGateway(dir, Some(factory))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleSwitchModel("test", "chat1", "m-fast", "", "")
        @Assert(ch.errors.size, 0)
        @Assert(ch.acks.size, 1)
        @Assert(ch.acks[0].action, "switch_model")
        @Assert(ch.acks[0].model, "m-fast")
        // 端点回给客户端（否则它不知道请求打到了哪儿）
        @Assert(ch.acks[0].baseUrl, "http://stub.local/v1/chat/completions")
        @Assert(ch.acks[0].sessionId.size > 0, true)
        @Assert(factory.createdModels().size, 1)
    }

    @TestCase
    public func testSwitchModelResolveFailureReportsError(): Unit {
        let dir = testTempDir("gw_ctrl_switch_fail")
        let factory = StubProviderFactory("ghost-model")
        let gateway = buildGateway(dir, Some(factory))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleSwitchModel("test", "chat1", "ghost-model", "", "")
        @Assert(ch.acks.size, 0)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "switch_model_failed")
        // 解析失败不得造 provider（否则等于悄悄换到了别的模型）
        @Assert(factory.createdModels().size, 0)
    }

    @TestCase
    public func testSwitchModelHonorsExplicitEndpoint(): Unit {
        let dir = testTempDir("gw_ctrl_switch_explicit")
        let factory = StubProviderFactory("")
        let gateway = buildGateway(dir, Some(factory))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleSwitchModel("test", "chat1", "m-x", "https://custom.example.com/v1", "sk-x")
        @Assert(ch.acks.size, 1)
        @Assert(ch.acks[0].baseUrl, "https://custom.example.com/v1")
    }

    @TestCase
    public func testCompactWithoutSessionAcksNotCompacted(): Unit {
        // 无会话可压缩：回 ack（compacted=false），而不是静默
        let dir = testTempDir("gw_ctrl_compact_idle")
        let gateway = buildGateway(dir, None)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleCompact("test", "chat1")
        @Assert(ch.acks.size, 1)
        @Assert(ch.acks[0].action, "compact")
        @Assert(ch.acks[0].compacted, false)
        @Assert(ch.acks[0].messagesAfter, 0)
    }

    @TestCase
    public func testCancelWithoutRunningTurnReportsWasRunningFalse(): Unit {
        // 无回合在跑：回执要如实说 false（不是错误，是事实）
        let dir = testTempDir("gw_ctrl_cancel_idle")
        let gateway = buildGateway(dir, None)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleCancel("test", "chat1", "")
        @Assert(ch.cancelleds.size, 1)
        @Assert(ch.cancelleds[0].wasRunning, false)
    }

    @TestCase
    public func testCancelEchoesExplicitSessionId(): Unit {
        let dir = testTempDir("gw_ctrl_cancel_sid")
        let gateway = buildGateway(dir, None)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleCancel("test", "chat1", "s111.222.333")
        @Assert(ch.cancelleds.size, 1)
        @Assert(ch.cancelleds[0].sessionId, "s111.222.333")
    }

    @TestCase
    public func testUnknownChannelIsIgnoredWithoutCrash(): Unit {
        // 渠道未注册（如断连竞态）：控制帧被安全忽略，不抛异常
        let dir = testTempDir("gw_ctrl_unknown_channel")
        let gateway = buildGateway(dir, None)
        gateway.handleSwitchModel("nope", "chat1", "m", "", "")
        gateway.handleCompact("nope", "chat1")
        gateway.handleCancel("nope", "chat1", "")
        @Assert(true, true)
    }

    @TestCase
    public func testChatOverrideUnavailableModelReportsError(): Unit {
        // chat 帧指定的模型解析失败：如实报错并终止本回合，不静默降级到别的模型
        let dir = testTempDir("gw_ctrl_chat_bad_override")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let factory = StubProviderFactory("ghost-model")
        let gateway = buildGateway(dir, Some(factory))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        // 回合在独立协程里跑（否则 cancel 帧读不到）：轮询等事件
        gateway.handleUserMessage("test", "chat1", "你好",
            Some(ModelOverride("ghost-model", "", "")))
        waitForEvents(ch, 3000)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "model_unavailable")
        @Assert(ch.errors[0].retryable, false)
        // 回合失败也要收尾：done 照发（finish_reason=error），客户端只有一个终局信号
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "error")
        // 错误与 done 属于同一回合：身份齐备且一致
        @Assert(ch.errorMetas[0].turnId.size > 0, true)
        @Assert(ch.errorMetas[0].messageId.size > 0, true)
        @Assert(ch.errorMetas[0].sessionId.size > 0, true)
        @Assert(ch.errorMetas[0].turnId, ch.metas[ch.metas.size - 1].turnId)
    }

    @TestCase
    public func testChatWithoutOverrideRunsNormally(): Unit {
        // 边界：无模型覆盖 = 旧行为（用例不报错，正常跑完并推 done）
        let dir = testTempDir("gw_ctrl_chat_plain")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = buildGateway(dir, Some(StubProviderFactory("")))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "你好", None)
        waitForEvents(ch, 10000)
        @Assert(ch.errors.size, 0)
        @Assert(ch.dones > 0, true)
    }
}

/**
 * 慢 provider 替身：把回合"卡在跑"，直到外部要求中断
 *
 * 为什么不用 MockProvider + CJH_MOCK_DELAY_MS：环境变量是进程级全局，
 * 并发用例会互相污染。这里用一个本地 provider——只有中断到来才返回——
 * 把"回合正在跑"这个窗口造得确定，cancel → finish_reason=cancelled 才断言得住。
 */
public class SlowProvider <: LlmProvider {
    public var emitted: Int64 = 0

    public init() {}

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        isCancelled: () -> Bool): ModelResponse {
        // 每 10ms 吐一帧，最多 500 帧（5s 上限，防用例挂死）；中断到来即返回
        var i: Int64 = 0
        while (i < 500 && !isCancelled()) {
            onDelta("段")
            this.emitted += 1
            sleep(Duration.millisecond * 10)
            i += 1
        }
        return ModelResponse("已停止输出。", ArrayList<ToolCall>())
    }
}

/**
 * 回合身份与结束原因（P0-③：让客户端能归并事件、少写 try/catch）
 */
@Test
public class TurnIdentityTest {

    @TestCase
    public func testTurnFramesCarryConsistentIds(): Unit {
        // 同一回合的 delta / tool_* / done 必须带同一组 session_id/turn_id/message_id
        let dir = testTempDir("gw_turn_ids")
        writeTextFile(dir + "/mock.txt", "line1\nline2\n")
        let gateway = buildGateway(dir, Some(StubProviderFactory("")))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "你好", None)
        waitForEvents(ch, 10000)

        @Assert(ch.dones, 1)
        @Assert(ch.metas.size > 1, true)
        let first = ch.metas[0]
        @Assert(first.sessionId.size > 0, true)
        @Assert(first.turnId.size > 0, true)
        @Assert(first.messageId.size > 0, true)
        // turn_id 与 message_id 前缀不同（同序但可区分：一个回合可能产出多条消息）
        @Assert(first.turnId == first.messageId, false)
        for (m in ch.metas) {
            @Assert(m.sessionId, first.sessionId)
            @Assert(m.turnId, first.turnId)
            @Assert(m.messageId, first.messageId)
        }
        // 正常收尾：finish_reason=stop
        @Assert(ch.doneReasons[0], "stop")
    }

    @TestCase
    public func testFrameIdsJsonShapeIsFixed(): Unit {
        // 结构固定：有身份就输出三字段；无身份输出空串（老客户端读到空串，不崩）
        let meta = FrameMeta("s1.2.3", "s1.2.3#t7", "s1.2.3#m7")

        let delta = DeltaEvent("hi")
        delta.meta = meta
        let p1 = JsonValue.fromStr(delta.toJson()).asObject()
        @Assert(getStr(p1, "type"), "delta")
        @Assert(getStr(p1, "session_id"), "s1.2.3")
        @Assert(getStr(p1, "turn_id"), "s1.2.3#t7")
        @Assert(getStr(p1, "message_id"), "s1.2.3#m7")

        let done = DoneEvent(1, 2, 3, 4, 5)
        done.meta = meta
        done.finishReason = "cancelled"
        let p2 = JsonValue.fromStr(done.toJson()).asObject()
        @Assert(getStr(p2, "type"), "done")
        @Assert(getStr(p2, "finish_reason"), "cancelled")
        @Assert(getStr(p2, "turn_id"), "s1.2.3#t7")

        let plain = ErrorEvent("裸错误")
        let p3 = JsonValue.fromStr(plain.toJson()).asObject()
        @Assert(getStr(p3, "code"), "internal")
        @Assert(getStr(p3, "session_id"), "")
        @Assert(getStr(p3, "turn_id"), "")
        @Assert(getStr(p3, "message_id"), "")
    }

    @TestCase
    public func testCancelDuringTurnReportsFinishReasonCancelled(): Unit {
        // 回合在跑时收到 cancel：done.finish_reason 必须如实报 cancelled（不是 stop / error）
        let dir = testTempDir("gw_turn_cancel_reason")
        let cfg = CjhConfig()
        cfg.systemPrompt = "回合身份测试"
        cfg.maxIterations = 2
        let registry = ToolRegistry()
        registry.register(ReadTool())
        let provider = SlowProvider()
        let gateway = ChannelGateway(cfg, provider, registry,
            Some(StubProviderFactory("")))
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "你好", None)

        // 等到回合真的在跑：以 provider 已开始产字为准（不依赖 delta 转发时序）
        var waited: Int64 = 0
        while (provider.emitted == 0 && waited < 5000) {
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        @Assert(provider.emitted > 0, true)

        gateway.handleCancel("test", "chat1", "")
        @Assert(ch.cancelleds.size, 1)
        @Assert(ch.cancelleds[0].wasRunning, true)

        var waited2: Int64 = 0
        while (ch.dones == 0 && waited2 < 5000) {
            sleep(Duration.millisecond * 10)
            waited2 += 10
        }
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "cancelled")
    }
}

/**
 * JSON 取值辅助（断言用；字段缺失/类型不符返回兜底值）
 */
func getStr(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

func getBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => return false
            }
        case None => return false
    }
}

func getInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => return -1
            }
        case None => return -1
    }
}
