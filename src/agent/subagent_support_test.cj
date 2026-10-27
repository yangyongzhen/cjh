package cjh.agent

import std.collection.*
import std.time.*
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
    public func testSchedulerStaggerGate(): Unit {
        // 错峰门（修实测"并发派发撞 provider 限流"）：同一波并发派发的起跑时刻
        // 按 staggerMs 错开（第 k 个等 k*staggerMs）；空闲后锚点重置，下一波从 0 起算
        let sched = SubagentScheduler(4)
        sched.setStaggerMs(100)
        sched.staggerGate()                       // 首个 slot（或空闲重置后）：不等
        let t0 = DateTime.now()
        sched.staggerGate()                       // 第二个 slot：等到 100ms 预算
        let cost = (DateTime.now() - t0).toMilliseconds()
        @Assert(cost >= 60, true)                 // 至少等到 slot 预算（留抖动余量）
        // 空闲重置：无运行中节点且超过一个间隔后，门重新从 0 起算
        sleep(Duration.millisecond * 150)
        let t1 = DateTime.now()
        sched.staggerGate()
        let cost2 = (DateTime.now() - t1).toMilliseconds()
        @Assert(cost2 < 50, true)                 // 重置后不再等待
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
        // S4 闸门：每回合派生上限与 token 预算任一触顶 → 拒派（budget_exceeded）；
        // resetTurn（beginRound）一并清零。走原子 tryBeginSpawn（旧两步 API 已移除）
        let sched = SubagentScheduler(4, 2, 100, 0)
        @Assert(sched.tryBeginSpawn(), true)
        @Assert(sched.tryBeginSpawn(), true)
        @Assert(sched.tryBeginSpawn(), false)   // 派生数达上限 2
        sched.addTokens(100)
        sched.resetTurn()
        @Assert(sched.tryBeginSpawn(), true)    // 回合重置后恢复
        sched.resetTurn()
        sched.addTokens(100)                    // 预算 100 已用尽
        @Assert(sched.tryBeginSpawn(), false)   // token 预算触顶
    }

    // ── S3 复核：并发上限 0/负 → 不限（Semaphore(0) 会抛异常，曾导致进程起不来） ──

    @TestCase
    public func testSchedulerNonPositiveConcurrencyMeansUnlimited(): Unit {
        // settings 语义"四键 0 = 不限"；Semaphore(0)/Semaphore(-1) 直接构造会抛
        // IllegalArgumentException（Invalid amount to acquire. / Negative count.），
        // 此前 max_subagents=0 会让整个进程启动失败
        let zero = SubagentScheduler(0)
        var i: Int64 = 0
        while (i < 8) {
            @Assert(zero.acquire({ => false }), true)
            i += 1
        }
        zero.release()  // 不限并发：release 是空操作，不崩
        @Assert(zero.acquire({ => false }), true)
        let negative = SubagentScheduler(-2)
        @Assert(negative.acquire({ => false }), true)
        negative.release()
    }

    // ── S3 复核 #7：派生闸门原子化（修 allowSpawn→acquire→recordSpawn 的 TOCTOU） ──

    @TestCase
    public func testSchedulerTryBeginSpawnIsAtomic(): Unit {
        // DAG 同批并发派生（loop.cj 拓扑组内 spawn）下，旧三步用法会被多线程同时通过
        // 判定而越过 max_tasks_per_turn。原子版：8 路并发抢 2 个名额 → 恰好 2 个成功
        let sched = SubagentScheduler(64, 2, 0, 0)
        let got = ArrayList<Bool>()
        var i: Int64 = 0
        while (i < 8) {
            got.add(false)
            i += 1
        }
        var futures = ArrayList<Future<Unit>>()
        i = 0
        while (i < 8) {
            let idx = i
            futures.add(spawn { got[idx] = sched.tryBeginSpawn() })
            i += 1
        }
        for (f in futures) {
            let _ = f.get()
        }
        var wins: Int64 = 0
        for (r in got) {
            if (r) {
                wins += 1
            }
        }
        @Assert(wins, 2)   // 精确限流：不多不少
    }

    @TestCase
    public func testSchedulerUndoSpawnRefundsQuota(): Unit {
        // 闸门计数在 acquire 之前发生；排队期间被父中断（名额没拿到）必须回退，
        // 否则被取消的排队者白占一个回合名额，后续派生被误拒
        let sched = SubagentScheduler(4, 1, 0, 0)
        @Assert(sched.tryBeginSpawn(), true)
        @Assert(sched.tryBeginSpawn(), false)   // 已用掉唯一名额
        sched.undoSpawn()
        @Assert(sched.tryBeginSpawn(), true)    // 回退后可再派
    }

    @TestCase
    public func testSchedulerChangeDetectionSkipsRedundantNotify(): Unit {
        // 面板刷新靠 onChanged；高频源（曾经的每 SSE 帧）会把主循环淹没，
        // 故 markTool/markRoundUsage 无实际变化时不得触发回调
        let sched = SubagentScheduler(4)
        let fires = ArrayList<Int64>()
        fires.add(0)
        sched.onChanged({ => fires[0] += 1 })
        sched.register(AgentNode(301, 1, "任务A", "explore"))
        @Assert(fires[0], 1)
        sched.markTool(301, "read_file")
        @Assert(fires[0], 2)
        sched.markTool(301, "read_file")        // 同名工具 → 不重绘
        @Assert(fires[0], 2)
        sched.markRoundUsage(301, 1, 100, 10)
        @Assert(fires[0], 3)
        sched.markRoundUsage(301, 1, 100, 10)   // 三项都没变 → 不重绘
        @Assert(fires[0], 3)
        sched.markRoundUsage(301, 2, 200, 20)   // 变了 → 通知
        @Assert(fires[0], 4)
    }

    @TestCase
    public func testSchedulerResetTurnClearsNodes(): Unit {
        // 回合级面板：终态节点保留到本回合结束供总结条归账，下一回合开始清空
        // （此前只增不删，长会话里面板永远显示最早的几个、跑的反而被折叠）
        let sched = SubagentScheduler(4)
        sched.onChanged({ => () })
        sched.register(AgentNode(401, 1, "任务B", "worker"))
        sched.register(AgentNode(402, 1, "任务C", "worker"))
        sched.finish(401, AgentNodeState.Ok, 1, 100, 10)
        @Assert(sched.nodeCount(), 2)
        sched.resetTurn()
        @Assert(sched.nodeCount(), 0)
        @Assert(sched.tokensUsed(), 0)
    }

    // ── S6：task scope → DAG 冲突消解（internal 方法，包内直测） ──

    private func taskCall(scope: String): ToolCall {
        var a = JsonObject()
        a.put("description", JsonString("任务"))
        a.put("prompt", JsonString("做"))
        a.put("subagent_type", JsonString("worker"))
        if (scope.size > 0) {
            a.put("scope", JsonString(scope))
        }
        return ToolCall("t", "task", a)
    }

    @TestCase
    public func testExtractTaskScopeResources(): Unit {
        let agent = this.buildAgent(SubNoopProvider())
        // 有 scope：每项一条写边
        let withScope = agent.extractResourceAccesses(this.taskCall("src/a/*.cj, src/b/*.cj"))
        @Assert(withScope.size, 2)
        @Assert(withScope[0][0], "src/a/*.cj")
        @Assert(withScope[0][1], true)
        // 无 scope：哨兵 "**"（与所有 writer 串行，保守防静默覆盖）
        let noScope = agent.extractResourceAccesses(this.taskCall(""))
        @Assert(noScope.size, 1)
        @Assert(noScope[0][0], "**")
        @Assert(noScope[0][1], true)
    }

    @TestCase
    public func testDagScopeOverlapSerializes(): Unit {
        let agent = this.buildAgent(SubNoopProvider())
        var calls = ArrayList<ToolCall>()
        calls.add(this.taskCall("src/a/*.cj"))
        calls.add(this.taskCall("src/b/*.cj"))   // 不同 scope → 可并行
        calls.add(this.taskCall("src/a/*.cj"))   // 与 #0 重叠 → 串行
        calls.add(this.taskCall(""))             // 无 scope 哨兵 → 与所有 writer 串行
        let deps = agent.buildDependencyGraph(calls)
        @Assert(deps[1].size, 0)                 // b 与 a 无交集
        @Assert(deps[2].size, 1)                 // a 重叠 → 依赖 #0
        @Assert(deps[2][0], 0)
        @Assert(deps[3].size, 3)                 // 哨兵与全部 writer 串行
    }
}
