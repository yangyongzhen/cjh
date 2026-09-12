package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjh.tools.*

/**
 * 排队输入 drain 单元测试（atomcode 式 "steer"）
 *
 * 行为（见 loop.cj runLoop 的 drain 块）：
 *  - 每轮 LLM 请求前（checkPendingCompact 之后）经 onRequestPendingInput 拉取
 *    TUI 队列，非 None 注入为 user 消息；一次性排空（多条连发合并进本回合）
 *  - 中断优先于注入：Esc 中断后当前 turn 在轮顶 interrupt 检查处提前退出，
 *    drain 被跳过——剩余队列消息由 TUI 在 run 结束后作为新 turn 发送
 *
 * 确定性设计：
 *  - 主 provider 前 toolRounds 轮返回 noop 工具调用（驱动多轮），之后返回最终文本
 *  - SteerQueue 模拟 TUI 队列：FIFO + 拉取计数；skipPulls 让前 N 次拉取返回
 *    None（模拟"该轮边界队列仍空"），用于把注入钉在确定的轮次
 *  - SteerNoOpTool 在 execute 内 queue.add()/agent.interrupt()，模拟"工具执行
 *    期间用户按 Enter 入队 / 按 Esc 中断"（run 内、轮边界之间，无竞态）
 */

// ==================== 测试 provider / 工具 / 队列 ====================

/** 主 provider：前 toolRounds 轮返回 noop 工具调用（驱动多轮），之后返回最终文本。 */
class SteerMainProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public let toolRounds: Int64

    public init(toolRounds: Int64) {
        this.toolRounds = toolRounds
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount <= this.toolRounds) {
            var calls = ArrayList<ToolCall>()
            calls.add(ToolCall("steer_noop_${callCount}", "steernoop", JsonObject()))
            return ModelResponse("调用工具", calls)
        }
        return ModelResponse("FINAL-STEER", ArrayList<ToolCall>())
    }
}

/** 无副作用测试工具：第 steerAtCall 次调用时入队（模拟忙时 Enter）并可中断（模拟 Esc）。 */
class SteerNoOpTool <: CjhTool {
    public var calls: Int64 = 0
    public var agentRef: ?Agent = None
    public var queueRef: ?SteerQueue = None
    // >0：第 N 次调用时先向队列加一条消息，再请求中断（两次动作同一时机，确定发生
    // 在"第 N 轮工具执行"——即上一轮 drain 之后、下一轮 interrupt 检查/drain 之前）
    public var steerAtCall: Int64 = 0

    public override func spec(): ToolSpec {
        return ToolSpec("steernoop", "no-op 测试工具", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        if (this.calls == this.steerAtCall && this.steerAtCall > 0) {
            if (this.queueRef.isSome()) {
                this.queueRef.getOrThrow().add("运行中输入")
            }
            if (this.agentRef.isSome()) {
                this.agentRef.getOrThrow().interrupt()
            }
        }
        return ToolResult("ok", false)
    }

    public override func isReadOnly(): Bool {
        return true
    }
}

/**
 * FIFO 排队输入队列（模拟 TUI 输入队列）。
 * @param skipPulls 前 N 次拉取返回 None（模拟"该轮边界队列仍空"）
 */
class SteerQueue {
    var items: ArrayList<String> = ArrayList<String>()
    public var pullCount: Int64 = 0
    public let skipPulls: Int64

    public init(skipPulls: Int64) {
        this.skipPulls = skipPulls
    }

    public func add(msg: String): Unit {
        this.items.add(msg)
    }

    public func take(): Option<String> {
        this.pullCount += 1
        if (this.pullCount <= this.skipPulls) {
            return None
        }
        if (this.items.size == 0) {
            return None
        }
        let first: String = this.items[0]
        // 移除首元素：重建列表（ArrayList 无 removeAt）
        var rest: ArrayList<String> = ArrayList<String>()
        for (i in 1..this.items.size) {
            rest.add(this.items[i])
        }
        this.items = rest
        return Some(first)
    }
}

// ==================== 测试辅助 ====================

func steerBuildAgent(provider: LlmProvider, tool: CjhTool): Agent {
    let registry = ToolRegistry()
    registry.register(tool)
    let config = AgentConfig("steer test", 5, Capability())
    return Agent(provider, registry, config)
}

/** messages 是否含 content 完全匹配的 user 消息。 */
func steerHasUserMsg(agent: Agent, content: String): Bool {
    for (m in agent.getMessages()) {
        if (m.role == "user" && m.content == content) {
            return true
        }
    }
    return false
}

/** content 完全匹配的 user 消息在 messages 中的下标（未找到 -1）。 */
func steerUserMsgIndex(agent: Agent, content: String): Int64 {
    let msgs = agent.getMessages()
    for (i in 0..msgs.size) {
        if (msgs[i].role == "user" && msgs[i].content == content) {
            return i
        }
    }
    return -1
}

/** content 完全匹配的 user 消息条数（验证"恰好注入一次"无跨轮重复）。 */
func steerCountUserMsg(agent: Agent, content: String): Int64 {
    var n: Int64 = 0
    for (m in agent.getMessages()) {
        if (m.role == "user" && m.content == content) {
            n += 1
        }
    }
    return n
}

/** user 消息总条数。 */
func steerUserMsgTotal(agent: Agent): Int64 {
    var n: Int64 = 0
    for (m in agent.getMessages()) {
        if (m.role == "user") {
            n += 1
        }
    }
    return n
}

/** 最后一条 tool 结果消息下标（无则 -1）。 */
func steerLastToolMsgIndex(agent: Agent): Int64 {
    let msgs = agent.getMessages()
    var last: Int64 = -1
    for (i in 0..msgs.size) {
        if (msgs[i].role == "tool") {
            last = i
        }
    }
    return last
}

/** 首条 assistant 消息下标。 */
func steerFirstAsstMsgIndex(agent: Agent): Int64 {
    let msgs = agent.getMessages()
    for (i in 0..msgs.size) {
        if (msgs[i].role == "assistant") {
            return i
        }
    }
    return -1
}

// ==================== 用例 ====================

@Test
public class PendingInputDrainTest {

    /**
     * 轮顶边界注入：首轮 LLM 请求前排空队列并注入 user 消息——
     * 位置必须在首条 assistant 消息之前（请求发出前），且恰好一次（后续轮次拉取为 None）。
     */
    @TestCase
    public func testDrainInjectsBeforeFirstLlmCall(): Unit {
        let provider = SteerMainProvider(1)
        let tool = SteerNoOpTool()
        let agent = steerBuildAgent(provider, tool)
        let queue = SteerQueue(0)
        queue.add("重点关注错误路径")
        agent.onRequestPendingInput = { => queue.take() }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-STEER"), true)
        @Assert(steerHasUserMsg(agent, "重点关注错误路径"), true)
        // 注入位置：首条 assistant（首轮 LLM 响应）之前
        @Assert(steerUserMsgIndex(agent, "重点关注错误路径") < steerFirstAsstMsgIndex(agent), true)
        // 恰好注入一次（第 2 轮边界拉取已为 None，不重复）
        @Assert(steerCountUserMsg(agent, "重点关注错误路径"), 1)
        @Assert(queue.pullCount >= 2, true)  // 每轮边界都探测
    }

    /**
     * 一次性排空：多条连发全部注入本回合，FIFO 顺序保持，各自恰好一次。
     */
    @TestCase
    public func testDrainMergesMultipleItemsInOrder(): Unit {
        let provider = SteerMainProvider(1)
        let tool = SteerNoOpTool()
        let agent = steerBuildAgent(provider, tool)
        let queue = SteerQueue(0)
        queue.add("第一条：补单元测试")
        queue.add("第二条：更新文档")
        agent.onRequestPendingInput = { => queue.take() }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-STEER"), true)
        @Assert(steerHasUserMsg(agent, "第一条：补单元测试"), true)
        @Assert(steerHasUserMsg(agent, "第二条：更新文档"), true)
        @Assert(steerUserMsgIndex(agent, "第一条：补单元测试") < steerUserMsgIndex(agent, "第二条：更新文档"), true)
        @Assert(steerCountUserMsg(agent, "第一条：补单元测试"), 1)
        @Assert(steerCountUserMsg(agent, "第二条：更新文档"), 1)
    }

    /**
     * "上一次工具调用完成后"边界：第 1 轮边界队列空（skipPulls=1），工具执行中
     * 入队（模拟用户忙时 Enter）→ 第 2 轮边界注入——位置在 tool 结果消息之后。
     */
    @TestCase
    public func testDrainAtBoundaryAfterToolCall(): Unit {
        let provider = SteerMainProvider(1)
        let tool = SteerNoOpTool()
        let queue = SteerQueue(1)
        tool.queueRef = Some(queue)
        tool.steerAtCall = 1  // 第 1 轮工具执行时入队（此刻第 1 轮 drain 已发生）
        let agent = steerBuildAgent(provider, tool)
        agent.onRequestPendingInput = { => queue.take() }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-STEER"), true)
        let steerIdx = steerUserMsgIndex(agent, "运行中输入")
        @Assert(steerIdx >= 0, true)
        // 在 tool 结果之后（第 2 轮请求前注入）
        @Assert(steerIdx > steerLastToolMsgIndex(agent), true)
        @Assert(steerCountUserMsg(agent, "运行中输入"), 1)
    }

    /**
     * 中断优先于注入：工具执行中入队 + 中断（模拟 Esc）→ 第 2 轮轮顶 interrupt
     * 检查先于 drain 退出——消息未被注入（由 TUI 在 run 结束后作为新 turn 发送）。
     */
    @TestCase
    public func testInterruptSkipsDrain(): Unit {
        let provider = SteerMainProvider(1)
        let tool = SteerNoOpTool()
        let queue = SteerQueue(0)
        tool.queueRef = Some(queue)
        tool.steerAtCall = 1  // 第 1 轮工具执行时入队 + 中断
        let agent = steerBuildAgent(provider, tool)
        tool.agentRef = Some(agent)
        agent.onRequestPendingInput = { => queue.take() }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("已中断"), true)
        @Assert(steerHasUserMsg(agent, "运行中输入"), false)  // 中断：drain 被跳过
        @Assert(queue.pullCount, 1)  // 仅第 1 轮边界拉取；第 2 轮在 interrupt 检查处退出
    }

    /**
     * 边界：无排队输入（恒 None）→ 不注入任何消息，回合照常完成。
     */
    @TestCase
    public func testNoQueueNoInjection(): Unit {
        let provider = SteerMainProvider(1)
        let tool = SteerNoOpTool()
        let agent = steerBuildAgent(provider, tool)
        let queue = SteerQueue(0)
        agent.onRequestPendingInput = { => queue.take() }
        let s = agent.run("原始指令")
        @Assert(s.reply.contains("FINAL-STEER"), true)
        @Assert(steerUserMsgTotal(agent), 1)  // 仅初始 user 消息
        @Assert(queue.pullCount >= 2, true)   // 每轮边界探测过一次
    }
}
