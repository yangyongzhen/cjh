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

    @TestCase
    public func testSchedulerRegisterFinishSnapshot(): Unit {
        // S3：节点登记 → 终态回写 → 快照深拷贝（面板只读，不共享可变态）
        let sched = SubagentScheduler(4)
        let node = AgentNode(101, 1, "调查任务", "explore")
        sched.register(node)
        sched.markTool(101, "read_file")
        @Assert(sched.nodeCount(), 1)
        // 终态回写：iterations/tokens/state 落齐，currentTool 清空
        sched.finish(101, AgentNodeState.Ok, 2, 1200, 300)
        let snap = sched.snapshot()
        @Assert(snap.size, 1)
        @Assert(snap[0].state.name(), "Ok")
        @Assert(snap[0].iterations, 2)
        @Assert(snap[0].promptTokens, 1200)
        @Assert(snap[0].completionTokens, 300)
        @Assert(snap[0].currentTool, "")
        // 快照深拷贝：改快照不影响原节点
        snap[0].state = AgentNodeState.Failed
        @Assert(sched.snapshot()[0].state.name(), "Ok")
    }

    @TestCase
    public func testSchedulerOnChangedFires(): Unit {
        let sched = SubagentScheduler(4)
        let fires = ArrayList<String>()
        sched.onChanged({ => fires.add("x") })
        sched.register(AgentNode(201, 1, "任务A", "worker"))
        sched.markTool(201, "grep")
        sched.finish(201, AgentNodeState.Ok, 1, 10, 5)
        @Assert(fires.size, 3)  // register / markTool / finish 各触发一次
    }

    @TestCase
    public func testSchedulerAcquireQueueAndInterruptCancel(): Unit {
        // 信号量：占满后排队阻塞；排队期间父中断 → 返回 false（cancelled 出口）
        let sched = SubagentScheduler(1)
        let parent = this.buildAgent(SubNoopProvider())
        @Assert(sched.acquire({ => false }), true)   // 占住唯一名额
        let holder = ArrayList<Bool>()
        holder.add(false)
        let t = spawn {
            // 排队中：父中断后 acquire 返回 false（不丢任务、不永久阻塞）
            holder[0] = sched.acquire({ => parent.isInterrupted() })
        }
        parent.interrupt()
        let _ = t.get()
        @Assert(holder[0], false)
        sched.release()
        @Assert(sched.acquire({ => false }), true)   // 释放后可再获取
        sched.release()
    }

    @TestCase
    public func testSchedulerPerTurnCapAndTokenBudget(): Unit {
        // S4 闸门：每回合派生上限与 token 预算任一触顶 → allowSpawn=false；
        // resetTurn（beginRound）一并清零
        let sched = SubagentScheduler(4, 2, 100, 0)
        @Assert(sched.allowSpawn(), true)
        sched.recordSpawn()
        @Assert(sched.allowSpawn(), true)
        sched.recordSpawn()
        @Assert(sched.allowSpawn(), false)   // 派生数达上限 2
        sched.addTokens(100)
        sched.resetTurn()
        @Assert(sched.allowSpawn(), true)    // 回合重置后恢复
        sched.addTokens(100)                 // 预算 100 已用尽
        @Assert(sched.allowSpawn(), false)   // token 预算触顶
    }
}
