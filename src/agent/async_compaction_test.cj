package cjh.agent

import std.collection.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjcfg.*

/**
 * P1b compaction 后台异步化单元测试（优化提速方案 G2）
 *
 * 行为（对齐 docs/优化提速方案.md P1b 验收）：
 *  - 轮末真实 prompt token 超阈值 → 后台 spawn 摘要（读快照，不阻塞主循环）
 *  - 下一轮 LLM 请求前 tryGet 已完成 → 换装 messages（主线程独占写，锁守护）
 *  - 未完成 → 顺延（当前轮照常跑，下轮再查）
 *  - 后台失败 → 静默重试一次；再失败回退同步压缩（行为降级不崩）
 *  - 未达阈值不触发；手动 compact(true) 保持同步路径不回归
 *
 * 确定性设计（release-gate + 递减 usage）：
 *  后台摘要走 spawn 线程调用摘要 provider。为让"触发→下轮应用"与"未完成顺延"
 *  两种时序都可确定性构造：
 *  - release-gate：NoOpTool 第 releaseAtCall 次调用写释放文件，摘要 provider
 *    阻塞轮询该文件。闸门打开后 ≤5ms 完成 → 下轮 checkPending 必拿到结果。
 *  - neverRelease：摘要 provider 阻塞 350ms → run（~0ms）返回时 pending 恒未完成 → 顺延。
 *  - 递减 usage：主 provider 首轮报高 token（触发）、后续报低 token（不触发）。
 *    避免换装后 mock 每轮固定报同一 usage 导致反复触发（churn）。
 *  轮次间有真实工具执行（含 100ms sleep）+ LLM 调用，spawn 线程在闸门打开前已完成
 *  调度，故"完成后下轮应用"无竞态；"顺延"靠 350ms 阻塞保证 pending 恒未完成。
 *
 * 用例：
 *  1. 未达阈值不触发（gate 从未被调）
 *  2. 阈值触发 → 下轮换装（异步应用，size 减小，mode=AsyncApplied）
 *  3. 未完成顺延（neverRelease，run 返回时仍 pending，mode=Async，未换装）
 *  4. 后台失败 → 回退同步（mode=SyncFallback，不崩）
 *  5. 手动 compact(true) 仍同步（不改 auto 模式，mode 保持 None）
 */

// ==================== 测试 provider / 工具 ====================

/**
 * 主 provider：前 toolRounds 轮返回 noop 工具调用（驱动多轮），之后返回最终文本。
 * usage 递减：首轮报 firstUsage（高，触发压缩），后续报 restUsage（低，不触发）。
 */
class ScriptedMainProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public let toolRounds: Int64
    public let firstUsage: Int64
    public let restUsage: Int64

    public init(toolRounds: Int64, firstUsage: Int64, restUsage: Int64) {
        this.toolRounds = toolRounds
        this.firstUsage = firstUsage
        this.restUsage = restUsage
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        let usage = if (callCount == 1) { this.firstUsage } else { this.restUsage }
        if (callCount <= this.toolRounds) {
            var calls = ArrayList<ToolCall>()
            calls.add(ToolCall("noop_${callCount}", "noop", JsonObject()))
            var resp = ModelResponse("调用工具", calls)
            resp.usage.promptTokens = usage
            return resp
        }
        var done = ModelResponse("FINAL-DONE", ArrayList<ToolCall>())
        done.usage.promptTokens = usage
        return done
    }
}

/** 摘要 provider：固定文本响应（成功路径）。 */
class SummaryOkProvider <: LlmProvider {
    public var callCount: Int64 = 0

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        return ModelResponse("异步摘要内容", ArrayList<ToolCall>())
    }
}

/**
 * 摘要 provider：阻塞至释放文件出现（release-gate）。
 * neverRelease 时阻塞 350ms——足以保证 run（~0ms）返回时 pending 恒未完成（顺延场景）。
 */
class ReleaseGateSummaryProvider <: LlmProvider {
    public var callCount: Int64 = 0
    let releaseFile: String
    let neverRelease: Bool

    public init(releaseFile: String, neverRelease: Bool) {
        this.releaseFile = releaseFile
        this.neverRelease = neverRelease
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (!this.neverRelease) {
            let t0 = DateTime.now()
            while (!exists(this.releaseFile)) {
                if ((DateTime.now() - t0).toMilliseconds() > 15000) {
                    break  // 安全兜底：超时返回（不应发生）
                }
                sleep(Duration.millisecond * 5)
            }
        } else {
            sleep(Duration.millisecond * 350)
        }
        return ModelResponse("gate 摘要", ArrayList<ToolCall>())
    }
}

/** 摘要 provider：始终抛异常（回退同步路径测试）。 */
class SummaryThrowProvider <: LlmProvider {
    public var callCount: Int64 = 0

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        throw Exception("summary 故意失败（回退测试）")
    }
}

/**
 * 无副作用测试工具（read-only，瞬时返回）。
 * releaseAtCall>0 时第 N 次调用写释放文件并 sleep 100ms（闸门打开 + 等摘要完成）。
 */
class NoOpTool <: CjhTool {
    public var calls: Int64 = 0
    let releaseAtCall: Int64
    let releaseFile: String

    public init(releaseAtCall: Int64, releaseFile: String) {
        this.releaseAtCall = releaseAtCall
        this.releaseFile = releaseFile
    }

    public override func spec(): ToolSpec {
        return ToolSpec("noop", "no-op 测试工具", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        if (this.calls == this.releaseAtCall && this.releaseAtCall > 0) {
            File.writeTo(this.releaseFile, "released".toArray())
            sleep(Duration.millisecond * 100)  // 等摘要 provider（5ms 轮询）完成
        }
        return ToolResult("ok", false)
    }

    public override func isReadOnly(): Bool {
        return true
    }
}

// ==================== 测试辅助 ====================

/**
 * 构造填充了 history 的 Agent。
 * @param tokenThreshold compactTokenThreshold（token 阈值，0=禁用）
 * @param historyCount 注入的历史消息条数（纯 user，无工具消息 → 压缩时 kept 为空）
 * @param contentLen 每条历史消息字符长度
 */
func acBuildAgent(mainProvider: LlmProvider, tool: CjhTool,
    tokenThreshold: Int64, maxIterations: Int64, historyCount: Int64,
    contentLen: Int64, summary: ?LlmProvider): Agent {
    let registry = ToolRegistry()
    registry.register(tool)
    // compactThreshold=0（条数禁用），仅 token 阈值触发；compactKeep=2
    let config = AgentConfig("async compact test", maxIterations, Capability(),
        0, tokenThreshold, 2, 6000, "", "ac-sess")
    let agent = Agent(mainProvider, registry, config)
    if (summary.isSome()) {
        agent.setSummaryProvider(summary.getOrThrow())
    }
    var history = ArrayList<ChatMessage>()
    for (i in 0..historyCount) {
        var sb = StringBuilder()
        for (_ in 0..contentLen) {
            sb.append("y")
        }
        history.add(ChatMessage("user", "历史 ${i}：" + sb.toString()))
    }
    agent.loadHistory(history)
    return agent
}

/** messages 是否含 [历史摘要] 标记（压缩已应用的判据）。 */
func acContainsSummary(agent: Agent): Bool {
    for (m in agent.getMessages()) {
        if (m.content.contains("[历史摘要]")) {
            return true
        }
    }
    return false
}

// ==================== 用例 ====================

@Test
public class AsyncCompactionTest {

    /**
     * 未达阈值不触发：token 阈值 1_000_000，首轮 usage 500 永不超 → 不 spawn 后台摘要。
     * 摘要 provider 从未被调用，无摘要，mode=None。
     */
    @TestCase
    public func testNotTriggeredWhenBelowThreshold(): Unit {
        let mainProvider = ScriptedMainProvider(1, 500, 1)
        let gate = ReleaseGateSummaryProvider("/tmp/cjh_ac_none_f1", true)
        let tool = NoOpTool(0, "")
        let agent = acBuildAgent(mainProvider, tool, 1000000, 5, 5, 50, Some(gate))
        let s = agent.run("ac 未达阈值")
        @Assert(s.reply.contains("FINAL-DONE"), true)
        @Assert(agent.getCompactionMode(), "None")
        @Assert(gate.callCount, 0)  // 摘要 provider 从未被调用
        @Assert(acContainsSummary(agent), false)
    }

    /**
     * 阈值触发 → 下轮换装：token 阈值 3，首轮 usage 500 触发 spawn（读快照）；
     * 第 1 次工具调用写释放文件（闸门打开，摘要 100ms 内完成）→ 第 2 轮请求前
     * checkPending tryGet 完成 → 换装 messages。主循环从不阻塞在摘要上。
     * 断言：摘要恰好 1 次（无 churn）、mode=AsyncApplied、含摘要、size 小于未压缩上界。
     */
    @TestCase
    public func testAsyncTriggersThenAppliedNextRound(): Unit {
        let mainProvider = ScriptedMainProvider(1, 500, 1)
        let gate = ReleaseGateSummaryProvider("/tmp/cjh_ac_async_f2", false)
        let tool = NoOpTool(1, "/tmp/cjh_ac_async_f2")
        let agent = acBuildAgent(mainProvider, tool, 3, 5, 5, 50, Some(gate))
        let before = Int64(agent.getMessages().size)  // 1(system)+5(history)=6
        let s = agent.run("ac 异步")
        @Assert(s.reply.contains("FINAL-DONE"), true)
        @Assert(gate.callCount, 1)  // 摘要请求恰好 1 次（递减 usage 防 churn）
        @Assert(agent.getCompactionMode(), "AsyncApplied")
        @Assert(acContainsSummary(agent), true)
        // 未压缩上界 = before + 1(input) + toolRounds*2(asst+tool) + 1(末轮 asst)
        let uncompacted = before + 1 + 2 + 1
        @Assert(Int64(agent.getMessages().size) < uncompacted, true)
    }

    /**
     * 未完成顺延：neverRelease 摘要 provider 阻塞 350ms → run（~0ms）返回时
     * pending 恒未完成（各轮 checkPending tryGet=None → 顺延）。
     * 断言：mode=Async（pending 在）、未换装（无摘要）、主循环未被摘要阻塞。
     */
    @TestCase
    public func testIncompleteDefersToLaterRound(): Unit {
        let mainProvider = ScriptedMainProvider(1, 500, 1)
        let gate = ReleaseGateSummaryProvider("/tmp/cjh_ac_defer_f3", true)
        let tool = NoOpTool(0, "")
        let agent = acBuildAgent(mainProvider, tool, 3, 5, 5, 50, Some(gate))
        let s = agent.run("ac 顺延")
        @Assert(s.reply.contains("FINAL-DONE"), true)  // 主循环未被摘要阻塞
        @Assert(agent.getCompactionMode(), "Async")  // pending 仍在（未换装）
        @Assert(acContainsSummary(agent), false)  // 摘要未应用（顺延）
        // 顺延期间消息照常增长（未压缩）
        @Assert(Int64(agent.getMessages().size) > 6, true)
    }

    /**
     * 后台失败 → 回退同步：摘要 provider 始终抛异常。spawn 内静默重试一次，
     * 再失败 → 下轮 checkPending 检测 summary 为空 → 置 SyncFallback + 同步压缩
     * （同步路径同样失败 → 静默不崩）。断言：mode=SyncFallback、未换装、不崩。
     */
    @TestCase
    public func testFailureFallsBackToSync(): Unit {
        let mainProvider = ScriptedMainProvider(1, 500, 1)
        // 工具第 1 次调用 sleep 100ms（写 dummy 释放文件）：保证 spawn 内两次瞬时 throw
        // 在 round 2 checkPending 前完成 → tryGet 拿到 ""（空）→ 确定性触发回退，无竞态
        let tool = NoOpTool(1, "/tmp/cjh_ac_fallback_f4")
        let agent = acBuildAgent(mainProvider, tool, 3, 5, 5, 50, Some(SummaryThrowProvider()))
        let s = agent.run("ac 回退")
        @Assert(s.reply.contains("FINAL-DONE"), true)  // 失败不崩，回合正常完成
        @Assert(agent.getCompactionMode(), "SyncFallback")
        @Assert(acContainsSummary(agent), false)  // 摘要始终失败 → 未换装
    }

    /**
     * 手动 compact(true) 仍同步：不跑 run，直接 force 压缩。
     * 换装成功（含摘要、a<b），auto 后台模式不受影响（保持 None）。
     * 验证 P1b 不破坏 /compact 手动路径的确定性 before/after。
     */
    @TestCase
    public func testManualCompactStillSync(): Unit {
        let mainProvider = ScriptedMainProvider(0, 500, 1)
        let tool = NoOpTool(0, "")
        let agent = acBuildAgent(mainProvider, tool, 3, 5, 5, 50, Some(SummaryOkProvider()))
        let before = Int64(agent.getMessages().size)
        let (done, b, a) = agent.compact(true)
        @Assert(done, true)
        @Assert(b, before)
        @Assert(a < before, true)
        @Assert(acContainsSummary(agent), true)
        @Assert(agent.getCompactionMode(), "None")  // 手动路径不改 auto 模式
    }
}
