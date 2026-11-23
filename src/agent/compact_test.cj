package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjcfg.*

/**
 * Compaction 双阈值单元测试（疑难问题-LLM工具调用效率低.md 5.1 短期优化 1）
 *
 * 背景：compactThreshold 是消息条数阈值，长 tool_result 时消息条数涨得慢但
 * prompt 已膨胀（实测 30 条消息时 prompt 15-20K token）。新增 compactTokenThreshold
 * token 估算兜底：估算 prompt token 超阈值即触发压缩。
 *
 * 用例：
 *  - 消息条数未超阈值、估算 token 超阈值 → 触发压缩（核心新行为）
 *  - 两个阈值都禁用（0）→ 不压缩
 *  - 消息条数超阈值 → 仍触发压缩（旧行为不回归）
 */
/**
 * 摘要请求专用 stub：任何 chatStream 都返回一段文本（无工具调用）。
 * 压缩流程只需 provider 返回 text，不执行工具。
 * usagePromptTokens 模拟 provider 返回的真实 usage（压缩触发信号）。
 */
class TextStubProvider <: LlmProvider {
    public var usagePromptTokens: Int64 = 0
    // 摘要请求原文：断言内部提醒没有混进摘要
    public var lastMessages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()

    public init(usagePromptTokens: Int64) {
        this.usagePromptTokens = usagePromptTokens
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        this.lastMessages = messages
        var resp = ModelResponse("压缩摘要 stub 文本", ArrayList<ToolCall>())
        resp.usage.promptTokens = this.usagePromptTokens
        return resp
    }
}

@Test
public class CompactThresholdTest {

    /**
     * 构造一个填充了 history 的 Agent。
     * @param compactThreshold 消息条数阈值
     * @param compactTokenThreshold token 估算阈值
     * @param historyCount 注入的历史消息条数
     * @param contentLen 每条历史消息的字符长度（模拟长 tool_result）
     */
    private func buildAgent(compactThreshold: Int64, compactTokenThreshold: Int64,
        historyCount: Int64, contentLen: Int64): Agent {
        return this.buildAgent(compactThreshold, compactTokenThreshold,
            historyCount, contentLen, TextStubProvider(0))
    }

    private func buildAgent(compactThreshold: Int64, compactTokenThreshold: Int64,
        historyCount: Int64, contentLen: Int64, provider: LlmProvider): Agent {
        let registry = ToolRegistry()
        let config = AgentConfig("test system", 5, Capability(),
            compactThreshold, compactTokenThreshold, 2,
            6000, "", "test-session")
        let agent = Agent(provider, registry, config)
        var history = ArrayList<ChatMessage>()
        for (i in 0..historyCount) {
            var sb = StringBuilder()
            for (j in 0..contentLen) {
                sb.append("x")
            }
            // 交替 user/assistant：摘要只取 assistant 文本，纯 user 历史按契约
            // 直接 no-op（防“空摘要 → 反复压缩”），故测试历史必须含 assistant
            let role = if (i % 2 == 0) { "user" } else { "assistant" }
            history.add(ChatMessage(role, "消息 ${i}：" + sb.toString()))
        }
        agent.loadHistory(history)
        return agent
    }

    @TestCase
    public func testTokenThresholdTriggersCompaction(): Unit {
        // 消息条数阈值 100（不触发）；token 阈值 200（估算 >200 即触发）
        // 4 条 × 1000 字符 ≈ 4×250 = 1000 token > 200 → 应压缩
        let agent = this.buildAgent(100, 200, 4, 1000)
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, true)
        @Assert(b, before)
        // 用户消息全保留（失忆修复）：user 指令逐字保留、assistant 文本进摘要。
        // 历史 user/assistant 交替：1 system + 1 摘要 + 1 保留 user + 2 近期 = 5
        @Assert(a, 5)
        // 压缩后应保留 [历史摘要] 标记
        var hasSummary = false
        for (m in agent.getMessages()) {
            if (m.content.contains("[历史摘要]")) {
                hasSummary = true
            }
        }
        @Assert(hasSummary, true)
    }

    @TestCase
    public func testTokenThresholdNotTriggeredWhenSmall(): Unit {
        // token 阈值 10000：4 条 × 20 字符 ≈ 4×5 = 20 token，不触发
        let agent = this.buildAgent(100, 10000, 4, 20)
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, false)
        @Assert(a, before)
    }

    @TestCase
    public func testNoAssistantTextSkipsCompaction(): Unit {
        // 纯 user 历史（如刚启动就手动 /compact）：可压缩区间没有 assistant 文本，
        // 摘要请求会退化成"无内容"，随后反复触发压缩。契约：直接 no-op。
        let agent = this.buildAgent(0, 0, 0, 0)
        var history = ArrayList<ChatMessage>()
        for (i in 0..10) {
            history.add(ChatMessage("user", "纯用户消息 ${i}"))
        }
        agent.loadHistory(history)
        let before = Int64(agent.getMessages().size)
        let (compacted, b, a) = agent.compact(true)
        @Assert(compacted, false)
        @Assert(b, before)
        @Assert(a, before)
        var hasSummary = false
        for (m in agent.getMessages()) {
            if (m.content.contains("[历史摘要]")) {
                hasSummary = true
            }
        }
        @Assert(hasSummary, false)
    }

    @TestCase
    public func testInternalNoticesDroppedByCompaction(): Unit {
        // 长任务实测 [System Notice] 越积越多：它们是调度噪声，既不该进摘要，
        // 也不该作为 user 指令钉在 kept 里永久占上下文。
        let provider = TextStubProvider(0)
        let agent = this.buildAgent(0, 0, 0, 0, provider)
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", "任务目标"))
        history.add(ChatMessage("assistant", "旧进展"))
        history.add(ChatMessage("user", "内部续跑提醒", true))
        history.add(ChatMessage("assistant", "更多旧进展"))
        history.add(ChatMessage("user", "追加任务"))
        history.add(ChatMessage("assistant", "最近进展"))
        agent.loadHistory(history)
        let (compacted, _, _) = agent.compact(true)
        @Assert(compacted, true)
        for (m in agent.getMessages()) {
            @Assert(m.content.contains("内部续跑提醒"), false)
        }
        // 摘要请求里也不能出现内部提醒（否则模型会把调度噪声当用户指令）
        @Assert(provider.lastMessages.size > 0, true)
        for (m in provider.lastMessages) {
            @Assert(m.content.contains("内部续跑提醒"), false)
        }
    }

    @TestCase
    public func testBothDisabledNoCompaction(): Unit {
        // 两个阈值都为 0 = 完全禁用压缩（历史行为）
        let agent = this.buildAgent(0, 0, 10, 2000)
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, false)
        @Assert(a, before)
    }

    @TestCase
    public func testMessageCountStillTriggers(): Unit {
        // 旧行为回归：消息条数超阈值（count=3，历史 10 条）仍触发压缩
        let agent = this.buildAgent(3, 0, 10, 10)
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, true)
        // user 全保留、assistant 进摘要：system + 摘要 + 4 kept user + 2 recent = 8
        @Assert(a, 8)
    }

    @TestCase
    public func testFirstUserTaskKeptVerbatim(): Unit {
        // 失忆缺陷回归：压缩时所有用户指令（首条任务目标 + 中途追加任务）
        // 必须保留原文——进摘要会被"简洁转述"逐次稀释，多轮压缩后
        // agent 忘记目标、任务半途而废
        let agent = this.buildAgent(0, 0, 0, 0)
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", "任务目标：用 cj-tauri 开发 Cyclone DDS 调试助手，可发布订阅主题"))
        history.add(ChatMessage("assistant", "已完成环境核实，正在规划下一步。"))
        history.add(ChatMessage("user", "进度：环境核实完毕，bg-1 sleep 120 已跑完"))
        history.add(ChatMessage("user", "追加任务：装 Cyclone DDS 后跑 DDS-native 全量测试"))
        agent.loadHistory(history)

        let (compacted, b, a) = agent.compact(true)
        @Assert(compacted, true)
        // 原始任务指令与中途追加任务逐字保留在历史里（作为独立消息，而非摘要转述）
        var foundFirst = false
        var foundMid = false
        var inSummary = false
        for (m in agent.getMessages()) {
            if (m.content == "任务目标：用 cj-tauri 开发 Cyclone DDS 调试助手，可发布订阅主题") {
                foundFirst = true
            }
            if (m.content == "追加任务：装 Cyclone DDS 后跑 DDS-native 全量测试") {
                foundMid = true
            }
            if (m.content.startsWith("[历史摘要]") && m.content.contains("cj-tauri")) {
                inSummary = true
            }
        }
        @Assert(foundFirst, true)
        @Assert(foundMid, true)
        @Assert(inSummary, false)
    }

    @TestCase
    public func testToolHeavyHistoryCompactsWithoutAssistantText(): Unit {
        // 长任务实测（54 轮 / 124 条 / 1.77M 累计 prompt）：53 条 assistant 全带
        // tool_calls、只有最后一条纯文本。旧 kept 规则把工具链全部保留，可压缩
        // 区间没有 assistant 文本 → 每次 no-op，上下文无界增长。回归：旧工具链
        // 进摘要，用户任务逐字保留，并避免尾部出现孤立 tool 消息。
        let agent = this.buildAgent(0, 0, 0, 0)
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", "任务目标：实现资产台账"))
        for (i in 0..10) {
            let args = JsonObject()
            args.put("cmd", JsonString("echo step${i}"))
            let call = ToolCall("call${i}", "bash", args)
            let calls = ArrayList<ToolCall>()
            calls.add(call)
            history.add(ChatMessage("assistant", "", calls))
            history.add(ChatMessage("tool", "step${i} ok", "call${i}", "bash"))
        }
        history.add(ChatMessage("assistant", "全部完成"))
        agent.loadHistory(history)
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(true)
        @Assert(compacted, true)
        @Assert(a < before, true)
        var foundTask = false
        var hasSummary = false
        for (m in agent.getMessages()) {
            if (m.content == "任务目标：实现资产台账") {
                foundTask = true
            }
            if (m.content.startsWith("[历史摘要]")) {
                hasSummary = true
            }
        }
        @Assert(foundTask, true)
        @Assert(hasSummary, true)
        // 尾部必须以 assistant tool_calls 开头，不能是孤立 tool 结果
        let msgs = agent.getMessages()
        var tailStart = 0
        for (i in 0..msgs.size) {
            if (msgs[i].content.startsWith("[历史摘要]")) {
                tailStart = i + 1
            }
        }
        @Assert(msgs[tailStart].role, "user")  // 保留的任务目标
        @Assert(msgs[tailStart + 1].toolCalls.size > 0, true)
    }

    @TestCase
    public func testRealPromptTokensTriggerCompaction(): Unit {
        // 真实场景回归（实测：61 条短消息估算 ~6.6K，真实 prompt 42.9K token，
        // 纯字符估算触发不了压缩）：provider 返回真实 usage.promptTokens=30000，
        // 消息内容很短（估算远低于阈值），必须靠真实 token 触发。
        let stub = TextStubProvider(30000)
        let agent = this.buildAgent(0, 100, 2, 2000, stub)
        // 跑一轮让 agent 记录 provider 返回的真实 prompt token
        let _ = agent.run("测试任务")
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, true)
        // user 全保留、assistant 进摘要：system+摘要+1 kept user+input+reply = 5
        @Assert(a, before)
    }
}
