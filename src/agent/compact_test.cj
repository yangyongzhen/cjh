package cjh.agent

import std.collection.*
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

    public init(usagePromptTokens: Int64) {
        this.usagePromptTokens = usagePromptTokens
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit): ModelResponse {
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
            history.add(ChatMessage("user", "消息 ${i}：" + sb.toString()))
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
        @Assert(a < before, true)
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
        @Assert(a < before, true)
    }

    @TestCase
    public func testRealPromptTokensTriggerCompaction(): Unit {
        // 真实场景回归（实测：61 条短消息估算 ~6.6K，真实 prompt 42.9K token，
        // 纯字符估算触发不了压缩）：provider 返回真实 usage.promptTokens=30000，
        // 消息内容很短（估算远低于阈值），必须靠真实 token 触发。
        let stub = TextStubProvider(30000)
        let agent = this.buildAgent(0, 100, 2, 20, stub)
        // 跑一轮让 agent 记录 provider 返回的真实 prompt token
        let _ = agent.run("测试任务")
        let before = Int64(agent.getMessages().size)

        let (compacted, b, a) = agent.compact(false)
        @Assert(compacted, true)
        @Assert(a < before, true)
    }
}
