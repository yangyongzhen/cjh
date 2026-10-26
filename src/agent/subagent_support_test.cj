package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjcfg.*

/**
 * 并行子代理 + 上下文隔离 · Agent 侧支撑测试（方案 §5/§7）
 *
 * 覆盖：
 * - taskBriefContext：触碰文件表 + 会话摘要（D1 简报的上下文块），空会话边界
 * - registerChild/unregisterChild + interrupt() 中断传播（杀整棵树）
 *
 * 仓颉测试坑遵守：零参 lambda { => }；字符串迭代是 Byte。
 */

// 脚本化 provider：第 1 轮发一个 read_file 调用，第 2 轮给最终答复
class BriefScriptProvider <: LlmProvider {
    public var callCount: Int64 = 0

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount == 1) {
            var calls = ArrayList<ToolCall>()
            var a1 = JsonObject()
            a1.put("path", JsonString("/tmp/cjh_ut_brief/alpha.cj"))
            calls.add(ToolCall("b1", "read_file", a1))
            return ModelResponse("去读文件", calls)
        }
        return ModelResponse("brief done", ArrayList<ToolCall>())
    }
}

// 空响应 provider（只满足构造接口，不参与断言）
class SubNoopProvider <: LlmProvider {
    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        return ModelResponse("", ArrayList<ToolCall>())
    }
}

@Test
public class SubagentSupportTest {

    private func buildAgent(provider: LlmProvider): Agent {
        let registry = ToolRegistry()
        // 9 参构造：(sysPrompt, maxIter, cap, compactThreshold, compactTokenThreshold,
        //           compactKeep, toolResultMaxChars, spillDir, sessionId)
        let config = AgentConfig("test system", 5, Capability(), 0, 0, 6, 6000, "", "subtest")
        return Agent(provider, registry, config)
    }

    @TestCase
    public func testBriefContextHasTouchedFilesAndSummary(): Unit {
        let agent = this.buildAgent(BriefScriptProvider())
        let summary = agent.run("跑一轮")
        @Assert(summary.errorCode, "")
        let brief = agent.taskBriefContext()
        // D1：上下文块 = 触碰文件表 + 会话摘要
        @Assert(brief.contains("--- 父会话上下文"), true)
        @Assert(brief.contains("/tmp/cjh_ut_brief/alpha.cj"), true)
        @Assert(brief.contains("会话摘要"), true)
        @Assert(brief.contains("最后任务"), true)
    }

    @TestCase
    public func testBriefContextFreshAgentNoTouchedFiles(): Unit {
        // 边界：未跑过任何工具的会话，简报只有摘要段、没有触碰文件段
        let agent = this.buildAgent(SubNoopProvider())
        let brief = agent.taskBriefContext()
        @Assert(brief.contains("--- 父会话上下文"), true)
        @Assert(brief.contains("已触碰文件"), false)
        @Assert(brief.contains("会话摘要"), true)
    }

    @TestCase
    public func testInterruptPropagatesToRegisteredChild(): Unit {
        let parent = this.buildAgent(SubNoopProvider())
        let child = this.buildAgent(SubNoopProvider())
        @Assert(child.isInterrupted(), false)
        parent.registerChild(child)
        parent.interrupt()
        // 中断传播（方案 §7）：父 interrupt 下传登记中的子代理
        @Assert(child.isInterrupted(), true)
    }

    @TestCase
    public func testUnregisteredChildNotInterrupted(): Unit {
        // 边界：注销后的子代理不再接收中断（登记表不泄漏、不误杀）
        let parent = this.buildAgent(SubNoopProvider())
        let child = this.buildAgent(SubNoopProvider())
        parent.registerChild(child)
        parent.unregisterChild(child)
        parent.interrupt()
        @Assert(child.isInterrupted(), false)
    }
}
