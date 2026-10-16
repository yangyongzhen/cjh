package cjh.tests

import std.collection.*
import cjcfg.*
import cjllm.*
import cjh.gateway.*
import cjh.tools.*
import cjh.web.*

/**
 * 回合收尾的截断信号（done 帧的可选布尔 truncated）
 *
 * 为什么要它：上游因 max_tokens 截断时，内容确实不完整，但收尾一律报 finish_reason=stop
 * ——客户端分不清"说完了"和"被砍了"。
 *
 * 设计取直：**不**扩充 finish_reason（三值封闭，加第四个取值对老客户端是破坏性扩展），
 * 而是加一个可选键——只在真截断时出现，缺键即"未截断"，老客户端忽略未知键即可。
 *
 * 覆盖两层：
 * 1. 帧级：DoneEvent 序列化——true 出现、默认（false）缺键
 * 2. 网关级：截断回合的 done 带键；正常回合不虚报（不把"没截断"说成截断）
 *
 * 为什么另写 provider 替身：MockProvider 不支持截断，而 CJH_MOCK_* 环境变量是进程级全局，
 * 并发用例会互相污染（与 SlowProvider 同一理由）。
 */

/**
 * 固定输出的 provider 替身：可控 truncated
 */
public class TruncatingProvider <: LlmProvider {
    private let text: String
    private let truncated: Bool

    public init(text: String, truncated: Bool) {
        this.text = text
        this.truncated = truncated
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        _: () -> Bool): ModelResponse {
        onDelta(this.text)
        let r = ModelResponse(this.text, ArrayList<ToolCall>())
        r.truncated = this.truncated
        return r
    }
}

/**
 * ProviderFactory 替身：一律解析成功，create 给出固定输出的 provider
 */
public class TruncatingFactory <: ProviderFactory {
    private let text: String
    private let truncated: Bool

    public init(text: String, truncated: Bool) {
        this.text = text
        this.truncated = truncated
    }

    public func resolve(model: String, baseUrl: String, apiKey: String): ModelTarget {
        let target = ModelTarget()
        target.model = if (model.size > 0) { model } else { "trunc-model" }
        target.baseUrl = if (baseUrl.size > 0) { baseUrl } else { "http://stub.local/v1/chat/completions" }
        target.apiKey = if (apiKey.size > 0) { apiKey } else { "stub-key" }
        return target
    }

    public func create(_: ModelTarget): LlmProvider {
        return TruncatingProvider(this.text, this.truncated)
    }
}

/**
 * @Test 类：done 帧的截断信号
 */
@Test
public class TruncatedDoneFrameTest {

    /**
     * 去掉空白后的紧凑 JSON：可选键的**存在性**只能靠原文判定
     * （"缺键"与"值为 false"在取值辅助函数下长得一样）
     */
    private func compact(json: String): String {
        return json.replace(" ", "").replace("\n", "")
    }

    private func buildGateway(truncated: Bool): ChannelGateway {
        let cfg = CjhConfig()
        cfg.systemPrompt = "截断信号测试"
        cfg.maxIterations = 2
        let registry = ToolRegistry()
        registry.register(ReadTool())
        return ChannelGateway(cfg, TruncatingProvider("截断测试回复", truncated), registry,
            Some(TruncatingFactory("截断测试回复", truncated)))
    }

    // ---- 帧级 ----

    @TestCase
    public func testDoneFrameOmitsKeyWhenNotTruncated(): Unit {
        var ev = DoneEvent(2, 1, 100, 10, 5)
        ev.truncated = false
        let js = this.compact(ev.toJson())
        @Assert(js.contains("\"truncated\""), false)
        // 封闭三值不受影响
        @Assert(js.contains("\"finish_reason\":\"stop\""), true)
    }

    @TestCase
    public func testDoneFrameCarriesTrueWhenTruncated(): Unit {
        var ev = DoneEvent(2, 1, 100, 10, 5)
        ev.truncated = true
        let js = this.compact(ev.toJson())
        @Assert(js.contains("\"truncated\":true"), true)
        // 截断不是失败：结束原因仍是 stop
        @Assert(js.contains("\"finish_reason\":\"stop\""), true)
    }

    // ---- 网关级（端到端：agent 截断 → summary → done 帧）----

    @TestCase
    public func testTruncatedTurnEmitsFlag(): Unit {
        let gateway = this.buildGateway(true)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "回复 OK", None)
        waitForEvents(ch, 5000)
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "stop")
        @Assert(this.compact(ch.doneRawJson[0]).contains("\"truncated\":true"), true)
    }

    @TestCase
    public func testNormalTurnOmitsFlag(): Unit {
        // 不虚报：没截断就不许出现这个键
        let gateway = this.buildGateway(false)
        let ch = CaptureChannel()
        gateway.registerChannel("test", ch)
        gateway.handleUserMessage("test", "chat1", "回复 OK", None)
        waitForEvents(ch, 5000)
        @Assert(ch.dones, 1)
        @Assert(ch.doneReasons[0], "stop")
        @Assert(this.compact(ch.doneRawJson[0]).contains("\"truncated\""), false)
    }
}
