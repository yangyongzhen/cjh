package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjh.tools.*

/**
 * 排队输入「回合内边界注入 + 回合结束作新回合」单元测试（方案 2 安全版 steer）
 *
 * 语义（见 loop.cj runLoop 工具批次之后的注入点与 SteerPolicy）：
 *  - 忙时提交只入队，不打断当前回合
 *  - Agent 在**每轮工具批次执行完、下一轮请求前**这个边界取**一条**注入当前回合
 *  - 还没跑过任何工具时不注入（旧 v1.3.22 steer 正是在这里吞任务）
 *  - 已请求中断时不注入，队列原样留给下一回合
 *  - 回合结束后由装配层出队，逐条作为**新回合**发送（FIFO）
 *
 * 回归背景：v1.3.22 的 steer 在每轮 LLM 请求前排空队列注入当前回合，且**第 1 轮
 * （未做任何工具调用前）也会排空**——连发两条时后一条以裸 user 消息混进先发的
 * 任务里，模型按后者作答，先发任务被吞掉（用户实测：先发「生成 h5 小游戏」、
 * 紧接着「郑州天气」，只跑了天气）。v1.6.9 因此整段关闭、改为回合结束才发送；
 * 本方案（方案 2）只在"工具批次确实跑完"的边界注入，且一次只注入一条。
 *
 * 确定性设计：
 *  - DeferMainProvider 前 toolRounds 轮返回 noop 工具调用（驱动多轮），之后返回最终文本；
 *    每轮记录 messages 里 user 消息条数——注入若发生在错误边界，这里立刻多一条
 *  - DeferNoOpTool 在 execute 内入队 / 中断，模拟"工具执行期间用户按 Enter 入队 /
 *    按 Esc 中断"（run 内、轮边界之间，无竞态）
 *  - deferDequeue 复用装配层的同名语义（FIFO 取首）：既当 Agent 的 queuedInputSource，
 *    也模拟 entries.cj 的回合后出队
 */

// ==================== 测试 provider / 工具 / 队列辅助 ====================

/** 主 provider：前 toolRounds 轮返回 noop 工具调用（驱动多轮），之后返回最终文本。 */
class DeferMainProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public let toolRounds: Int64
    /** 每次 chatStream 时 messages 里 user 消息的条数（检测回合内注入复活） */
    public var userCounts: ArrayList<Int64> = ArrayList<Int64>()

    public init(toolRounds: Int64) {
        this.toolRounds = toolRounds
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        this.callCount += 1
        var users: Int64 = 0
        for (m in messages) {
            if (m.role == "user") {
                users += 1
            }
        }
        this.userCounts.add(users)
        if (this.callCount <= this.toolRounds) {
            var calls = ArrayList<ToolCall>()
            calls.add(ToolCall("defer_noop_${this.callCount}", "defernoop", JsonObject()))
            return ModelResponse("调用工具", calls)
        }
        return ModelResponse("FINAL-DEFER", ArrayList<ToolCall>())
    }
}

/** 无副作用测试工具：第 N 次调用时入队（模拟忙时 Enter）并可请求中断（模拟 Esc）。 */
class DeferNoOpTool <: CjhTool {
    public var calls: Int64 = 0
    public var agentRef: ?Agent = None
    public var queueRef: ?ArrayList<String> = None
    /** >0：第 N 次调用时把 enqueueTexts 依次入队（模拟用户此刻连按 Enter） */
    public var enqueueAtCall: Int64 = 0
    /** 到 enqueueAtCall 那一次调用时要入队的消息（FIFO 顺序） */
    public var enqueueTexts: ArrayList<String> = ArrayList<String>()
    /** >0：第 N 次调用时请求中断（模拟用户此刻按 Esc） */
    public var interruptAtCall: Int64 = 0
    /** 工具执行期间看到的 user 消息条数（本轮真实发给模型的会话快照） */
    public var userCountsDuringRun: ArrayList<Int64> = ArrayList<Int64>()

    public override func spec(): ToolSpec {
        return ToolSpec("defernoop", "no-op 测试工具", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        if (this.agentRef.isSome()) {
            var users: Int64 = 0
            for (m in this.agentRef.getOrThrow().getMessages()) {
                if (m.role == "user") {
                    users += 1
                }
            }
            this.userCountsDuringRun.add(users)
        }
        if (this.calls == this.enqueueAtCall) {
            if (this.queueRef.isSome()) {
                let queue = this.queueRef.getOrThrow()
                for (text in this.enqueueTexts) {
                    queue.add(text)
                }
            }
        }
        if (this.calls == this.interruptAtCall && this.agentRef.isSome()) {
            this.agentRef.getOrThrow().interrupt()
        }
        return ToolResult("ok", false)
    }

    public override func isReadOnly(): Bool {
        return true
    }
}

// ==================== 装配层语义辅助 ====================

/** 回合后出队（对齐 entries.cj 的 dequeueInput：FIFO 取首，空则 None）。 */
func deferDequeue(queue: ArrayList<String>): Option<String> {
    if (queue.size == 0) {
        return None
    }
    let first: String = queue[0]
    queue.remove(at: 0)
    return Some(first)
}

func deferBuildAgent(provider: LlmProvider, tool: CjhTool): Agent {
    let registry = ToolRegistry()
    registry.register(tool)
    let config = AgentConfig("defer test", 5, Capability())
    return Agent(provider, registry, config)
}

/** content 完全匹配的 user 消息下标（未找到 -1）。 */
func deferUserMsgIndex(agent: Agent, content: String): Int64 {
    let msgs = agent.getMessages()
    for (i in 0..msgs.size) {
        if (msgs[i].role == "user" && msgs[i].content == content) {
            return i
        }
    }
    return -1
}

/** content 完全匹配的 user 消息条数。 */
func deferCountUserMsg(agent: Agent, content: String): Int64 {
    var n: Int64 = 0
    for (m in agent.getMessages()) {
        if (m.role == "user" && m.content == content) {
            n += 1
        }
    }
    return n
}

/** content **包含** needle 的 user 消息条数（注入消息带框架抬头，不能整串匹配）。 */
func deferCountUserContains(agent: Agent, needle: String): Int64 {
    var n: Int64 = 0
    for (m in agent.getMessages()) {
        if (m.role == "user" && m.content.contains(needle)) {
            n += 1
        }
    }
    return n
}

/** content 包含 needle 的第一条 user 消息下标（未找到 -1）。 */
func deferUserMsgIndexContains(agent: Agent, needle: String): Int64 {
    let msgs = agent.getMessages()
    for (i in 0..msgs.size) {
        if (msgs[i].role == "user" && msgs[i].content.contains(needle)) {
            return i
        }
    }
    return -1
}

/** 第一条 tool 消息下标（无则 -1）——注入必须排在工具结果之后。 */
func deferFirstToolMsgIndex(agent: Agent): Int64 {
    let msgs = agent.getMessages()
    for (i in 0..msgs.size) {
        if (msgs[i].role == "tool") {
            return i
        }
    }
    return -1
}

/** user 消息总条数。 */
func deferUserMsgTotal(agent: Agent): Int64 {
    var n: Int64 = 0
    for (m in agent.getMessages()) {
        if (m.role == "user") {
            n += 1
        }
    }
    return n
}

// ==================== 用例 ====================

@Test
public class PendingInputDeferTest {

    /**
     * 方案 2 核心契约：工具批次执行完、下一轮请求前的边界注入**一条**排队消息。
     * 第 1 轮还没跑工具 → 只有原始指令；第 2 轮起模型立刻看得到补充要求。
     */
    @TestCase
    public func testQueuedInputInjectedAtToolBoundary(): Unit {
        let provider = DeferMainProvider(2)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        tool.enqueueAtCall = 1
        tool.enqueueTexts.add("运行中输入")
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.queuedInputSource = { => deferDequeue(queue) }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-DEFER"), true)
        // 第 1 轮 1 条（还没跑工具，不注入）；第 2/3 轮 2 条（边界注入一次）
        @Assert(provider.userCounts.size, 3)
        @Assert(provider.userCounts[0], 1)
        @Assert(provider.userCounts[1], 2)
        @Assert(provider.userCounts[2], 2)
        // 工具执行期的历史快照：首次 1 条，注入后 2 条
        @Assert(tool.userCountsDuringRun.size, 2)
        @Assert(tool.userCountsDuringRun[0], 1)
        @Assert(tool.userCountsDuringRun[1], 2)
        // 注入恰好一次，且带框架抬头（不是裸 user 消息混进去）
        @Assert(deferCountUserContains(agent, "运行中输入"), 1)
        @Assert(deferCountUserContains(agent, SteerPolicy.NOTICE_HEAD), 1)
        // 原始指令仍在最前、份数不变（先发任务不被吞、不被改写）
        @Assert(deferUserMsgIndex(agent, "原始指令"), 1)
        @Assert(deferCountUserMsg(agent, "原始指令"), 1)
        @Assert(deferUserMsgTotal(agent), 2)
        // 注入排在工具结果之后（边界，不是请求前砸进去）
        @Assert(deferFirstToolMsgIndex(agent) > 1, true)
        @Assert(deferUserMsgIndexContains(agent, "运行中输入") > deferFirstToolMsgIndex(agent), true)
        // 队列被消费（不会在回合结束又被当成新回合重发一次）
        @Assert(queue.size, 0)
    }

    /**
     * 首轮保护（旧 steer 的吞任务根因）：一次工具都没跑过时，队列里的消息不进本回合，
     * 也不会被偷偷消费——留给回合结束后的新回合。
     */
    @TestCase
    public func testNoInjectionBeforeAnyToolRan(): Unit {
        let provider = DeferMainProvider(0)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        queue.add("排队中的任务")
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.queuedInputSource = { => deferDequeue(queue) }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-DEFER"), true)
        for (n in provider.userCounts) {
            @Assert(n, 1)
        }
        @Assert(deferUserMsgTotal(agent), 1)
        @Assert(queue.size, 1)
        @Assert(queue[0], "排队中的任务")
    }

    /**
     * 一次边界只注入一条：连发两条时后一条留在队列，等下个边界或回合结束的新回合，
     * 不会把两条一次性砸进同一轮（那正是旧 steer 打乱任务的形态）。
     */
    @TestCase
    public func testAtMostOneMessagePerBoundary(): Unit {
        let provider = DeferMainProvider(1)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        tool.enqueueAtCall = 1
        tool.enqueueTexts.add("第二条：补单元测试")
        tool.enqueueTexts.add("第三条：更新文档")
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.queuedInputSource = { => deferDequeue(queue) }
        let s = agent.run("第一条：生成 h5 小游戏")
        @Assert(s.reply.contains("FINAL-DEFER"), true)
        @Assert(provider.userCounts.size, 2)
        @Assert(provider.userCounts[0], 1)
        @Assert(provider.userCounts[1], 2)
        @Assert(deferCountUserContains(agent, "第二条：补单元测试"), 1)
        @Assert(deferCountUserContains(agent, "第三条：更新文档"), 0)
        // 先发任务仍在最前
        @Assert(deferUserMsgIndex(agent, "第一条：生成 h5 小游戏"), 1)
        @Assert(queue.size, 1)
        @Assert(queue[0], "第三条：更新文档")
    }

    /** 纯函数策略：中断优先；零工具调用不构成边界（首轮/纯文本回合都不注入）。 */
    @TestCase
    public func testSteerPolicyShouldInject(): Unit {
        @Assert(SteerPolicy.shouldInject(false, 1), true)
        @Assert(SteerPolicy.shouldInject(false, 3), true)
        @Assert(SteerPolicy.shouldInject(false, 0), false)
        @Assert(SteerPolicy.shouldInject(true, 2), false)
        // 注入正文必须带抬头 + 原文，且写明"不要丢弃当前任务"
        let notice = SteerPolicy.injectNotice("补一条单元测试", 4)
        @Assert(notice.contains(SteerPolicy.NOTICE_HEAD), true)
        @Assert(notice.contains("补一条单元测试"), true)
        @Assert(notice.contains("不要丢弃"), true)
    }

    /**
     * 多条排队跨边界逐条注入：FIFO 顺序不变、各一次，原始任务始终最前。
     */
    @TestCase
    public func testFifoInjectionAcrossBoundaries(): Unit {
        let provider = DeferMainProvider(2)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        tool.enqueueAtCall = 1
        tool.enqueueTexts.add("第二条：补单元测试")
        tool.enqueueTexts.add("第三条：更新文档")
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.queuedInputSource = { => deferDequeue(queue) }
        let s = agent.run("第一条：生成 h5 小游戏")
        @Assert(s.reply.contains("FINAL-DEFER"), true)
        @Assert(provider.userCounts.size, 3)
        @Assert(provider.userCounts[0], 1)
        @Assert(provider.userCounts[1], 2)
        @Assert(provider.userCounts[2], 3)
        @Assert(queue.size, 0)
        @Assert(deferCountUserMsg(agent, "第一条：生成 h5 小游戏"), 1)
        @Assert(deferCountUserContains(agent, "第二条：补单元测试"), 1)
        @Assert(deferCountUserContains(agent, "第三条：更新文档"), 1)
        let firstIdx = deferUserMsgIndex(agent, "第一条：生成 h5 小游戏")
        let secondIdx = deferUserMsgIndexContains(agent, "第二条：补单元测试")
        let thirdIdx = deferUserMsgIndexContains(agent, "第三条：更新文档")
        @Assert(firstIdx < secondIdx, true)
        @Assert(secondIdx < thirdIdx, true)
    }

    /**
     * 中断优先于注入：工具批次跑完时若已请求中断，就不把消息塞进被中断的回合，
     * 队列原样保留，交由回合结束后的新回合发送。
     */
    @TestCase
    public func testInterruptSkipsInjection(): Unit {
        let provider = DeferMainProvider(2)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        tool.enqueueAtCall = 1
        tool.enqueueTexts.add("运行中输入")
        tool.interruptAtCall = 1
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.queuedInputSource = { => deferDequeue(queue) }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("已中断"), true)
        @Assert(deferUserMsgTotal(agent), 1)
        @Assert(deferCountUserContains(agent, "运行中输入"), 0)
        @Assert(queue.size, 1)
        @Assert(queue[0], "运行中输入")
    }

    /**
     * 回合结束后逐条出队作新回合：FIFO 顺序进入历史，各自恰好一次，
     * 且每个新回合的模型请求都只带一条"新的" user 消息（不合并、不重复）。
     */
    @TestCase
    public func testQueuedMessagesSentAsNewTurnsInOrder(): Unit {
        let provider = DeferMainProvider(0)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        let agent = deferBuildAgent(provider, tool)
        let first = agent.run("第一条：生成 h5 小游戏")
        @Assert(first.reply.contains("FINAL-DEFER"), true)
        // 忙时（这里模拟为回合结束后才入队）两条排队
        queue.add("第二条：郑州天气怎么样")
        queue.add("第三条：再看下温度")
        // 装配层：回合结束 → 出队 → 作新回合发送，逐条处理
        var guard: Int64 = 0
        while (let Some(next) <- deferDequeue(queue)) {
            guard += 1
            @Assert(guard <= 5, true)  // 防队列异常时死循环
            let s = agent.run(next)
            @Assert(s.reply.contains("FINAL-DEFER"), true)
        }
        @Assert(deferCountUserMsg(agent, "第一条：生成 h5 小游戏"), 1)
        @Assert(deferCountUserMsg(agent, "第二条：郑州天气怎么样"), 1)
        @Assert(deferCountUserMsg(agent, "第三条：再看下温度"), 1)
        // 先发任务仍在最前（没有被后续消息打乱/覆盖）
        @Assert(deferUserMsgIndex(agent, "第一条：生成 h5 小游戏") <
            deferUserMsgIndex(agent, "第二条：郑州天气怎么样"), true)
        @Assert(deferUserMsgIndex(agent, "第二条：郑州天气怎么样") <
            deferUserMsgIndex(agent, "第三条：再看下温度"), true)
        @Assert(deferUserMsgTotal(agent), 3)
    }

    /**
     * 中断（Esc）不改队列：中断只结束当前回合，排队消息留给回合结束后的新回合。
     */
    @TestCase
    public func testInterruptKeepsQueueForNextTurn(): Unit {
        let provider = DeferMainProvider(2)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        tool.enqueueAtCall = 1
        tool.enqueueTexts.add("运行中输入")
        tool.interruptAtCall = 1
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("已中断"), true)
        @Assert(deferCountUserMsg(agent, "运行中输入"), 0)  // 中断后也没混进本轮
        @Assert(queue.size, 1)                             // 队列原样保留
        // 回合结束后照常作为新回合发送
        let next = deferDequeue(queue)
        @Assert(next.isSome(), true)
        @Assert(next.getOrThrow(), "运行中输入")
        @Assert(queue.size, 0)
    }

    /**
     * 边界：队列为空 → 不产生额外回合，历史只有初始 user 消息，
     * 每轮模型请求也只带一条 user 消息（新语义不引入任何额外消息）。
     */
    @TestCase
    public func testEmptyQueueNoExtraTurn(): Unit {
        let provider = DeferMainProvider(2)
        let tool = DeferNoOpTool()
        let queue = ArrayList<String>()
        tool.queueRef = Some(queue)
        let agent = deferBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-DEFER"), true)
        @Assert(deferUserMsgTotal(agent), 1)
        @Assert(provider.userCounts.size, 3)  // 2 轮工具 + 1 轮收尾
        for (n in provider.userCounts) {
            @Assert(n, 1)
        }
        @Assert(deferDequeue(queue).isNone(), true)
    }
}
