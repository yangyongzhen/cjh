package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjcfg.*
import cjutil.*

/**
 * 「任务没做完就收场」防护（continuation guard）测试
 *
 * 实测背景（用户 h5 小游戏会话，日志 `Agent.run 正常结束: 2 rounds, 1 tools`）：
 * 模型回一条**只有文本、没有工具调用**的答复（"测试已重写，现在运行验证："），
 * agent 便把它当回合正常结束；待办 #3 还挂在 InProgress，用户不得不追问
 * "结束了吗"才继续跑。这类"静默收场"不是看门狗、不是轮次上限，是退出判定缺一道闸。
 *
 * 契约（本文件锁定）：
 *  1. 回合以纯文本收束时，若**有待办处于 InProgress**（模型自己声明"正在做"）→ 注入
 *     续跑指令并要求模型继续调用工具，不算回合结束
 *  2. 待办全部 Completed → 立即正常结束（不得凭空续跑）
 *  3. 没有任何待办、但文本以冒号收尾（"现在运行验证："这种承接句）→ 也注入续跑
 *  4. 续跑有硬预算（maxContinuationNudges），预算耗尽必须结束，不能自旋
 *  5. 历史遗留的 Pending 待办（本轮没碰过、也没声明进行中）不触发续跑——
 *     否则用户在同一会话里问无关的新问题会被强行拉回旧任务
 *  6. 轮次软顶已注入收尾指令（wrapUp）时**不得**再续跑，避免"要求收尾"与
 *     "要求继续"两条指令打架
 *
 * 仓颉测试坑遵守：零参 lambda { => }；字符串迭代给 Byte；ArrayList 逐项 add 不假定拷贝构造。
 */

/** 脚本化 provider：每轮返回一条纯文本（无工具调用），记录调用次数与收到的消息 */
class TextOnlyProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public var lastMessages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    private let replies: ArrayList<String>

    public init(replies: ArrayList<String>) {
        this.replies = replies
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        this.callCount += 1
        this.lastMessages = ArrayList<ChatMessage>()
        for (m in messages) {
            this.lastMessages.add(m)
        }
        var idx = this.callCount - 1
        if (idx >= this.replies.size) {
            idx = this.replies.size - 1
        }
        let text = this.replies[idx]
        if (text.size > 0) {
            onDelta(text)
        }
        return ModelResponse(text, ArrayList<ToolCall>())
    }
}

/** 必失败探针工具：模拟 bash 非零退出（isError=true，正是实测贪吃蛇自测 `exit code: 1` 的形态） */
class FailingProbeTool <: CjhTool {
    public override func spec(): ToolSpec {
        return ToolSpec("failingprobe", "总是失败的测试探针", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        return ToolResult("exit code: 1\nstdout:\n❌ spawnWalls 段数 6~9 got=4\n结果: 14 通过, 1 失败", true)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

/** 成功探针工具（防误触发的对照） */
class OkProbeTool <: CjhTool {
    public override func spec(): ToolSpec {
        return ToolSpec("okprobe", "总是成功的测试探针", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        return ToolResult("exit code: 0\nstdout:\n15 通过, 0 失败", false)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

/**
 * 脚本化 provider：第 1 次调用返回一个 tool_call，之后一律纯文本。
 * 文本刻意**不**以冒号收尾、也**不**建待办——模拟真实模型的"承诺句"收场：
 * 「发现真实 bug，修复 spawnWalls。」
 */
class ToolThenTextProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public var lastMessages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    private let toolName: String
    private let text: String

    public init(toolName: String, text: String) {
        this.toolName = toolName
        this.text = text
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        this.callCount += 1
        this.lastMessages = ArrayList<ChatMessage>()
        for (m in messages) {
            this.lastMessages.add(m)
        }
        if (this.callCount == 1) {
            let calls = ArrayList<ToolCall>()
            calls.add(ToolCall("t1", this.toolName, JsonObject()))
            return ModelResponse("", calls)
        }
        onDelta(this.text)
        return ModelResponse(this.text, ArrayList<ToolCall>())
    }
}

@Test
public class ContinuationGuardTest {

    private func buildAgent(provider: LlmProvider, maxIter: Int64): Agent {
        let registry = ToolRegistry()
        let config = AgentConfig("test system", maxIter, Capability(), 0, 0, 6, 6000, "", "contguard")
        return Agent(provider, registry, config)
    }

    private func replies(items: Array<String>): ArrayList<String> {
        let list = ArrayList<String>()
        for (s in items) {
            list.add(s)
        }
        return list
    }

    /** 最后一次 user 消息内容（续跑指令就注在这里） */
    private func lastUserText(messages: ArrayList<ChatMessage>): String {
        var text = ""
        for (m in messages) {
            if (m.role == "user") {
                text = m.content
            }
        }
        return text
    }

    /** 契约 1：InProgress 待办未完成 → 注入续跑指令；待办始终没标完成 → 用满预算才收场 */
    @TestCase
    public func testInProgressTodoKeepsRunning(): Unit {
        let provider = TextOnlyProvider(this.replies(["现在运行验证：", "全部通过，任务完成"]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        let id = agent.addTask("跑测试验证合并规则")
        agent.updateTaskStatus(id, TodoStatus.InProgress)
        agent.run("生成 h5 小游戏")
        // 1 次原始答复 + MAX_NUDGES 次续跑（待办一直 InProgress，预算用完才结束）
        @Assert(provider.callCount, 1 + ContinuationPolicy.MAX_NUDGES)      // 不会自旋
        @Assert(this.lastUserText(provider.lastMessages).contains("还没有完成"), true)   // 指令确实注入
        agent.clearTodos()
    }

    /** 契约 2：待办全部 Completed → 立即正常结束，不凭空续跑 */
    @TestCase
    public func testAllTodosCompletedEndsImmediately(): Unit {
        let provider = TextOnlyProvider(this.replies(["任务完成，19/20 通过"]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        let id = agent.addTask("跑测试验证合并规则")
        agent.updateTaskStatus(id, TodoStatus.Completed)
        let summary = agent.run("生成 h5 小游戏")
        @Assert(provider.callCount, 1)
        @Assert(summary.reply, "任务完成，19/20 通过")
        agent.clearTodos()
    }

    /** 契约 3：无待办但文本以冒号收尾（承接句）→ 也续跑 */
    @TestCase
    public func testLeadInColonNudgesContinuation(): Unit {
        let provider = TextOnlyProvider(this.replies(["现在运行验证：", "跑完了，全绿"]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        agent.run("跑一下测试")
        @Assert(provider.callCount, 2)
        @Assert(this.lastUserText(provider.lastMessages).contains("还没有完成"), true)
        agent.clearTodos()
    }

    /** 契约 4：续跑预算有上限——模型一直交承接句也必须收场，不得自旋 */
    @TestCase
    public func testNudgeBudgetIsBounded(): Unit {
        let provider = TextOnlyProvider(this.replies(["现在运行验证："]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        let id = agent.addTask("跑测试")
        agent.updateTaskStatus(id, TodoStatus.InProgress)
        agent.run("生成 h5 小游戏")
        @Assert(provider.callCount, 1 + ContinuationPolicy.MAX_NUDGES)
        agent.clearTodos()
    }

    /** 契约 5：历史遗留 Pending 待办（本轮没碰）不触发续跑，避免拽回旧任务 */
    @TestCase
    public func testStalePendingTodoDoesNotNudge(): Unit {
        let provider = TextOnlyProvider(this.replies(["郑州今天多云，18~25℃"]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        agent.addTask("旧的未完成任务（上一轮遗留）")   // 保持 Pending，本轮不碰
        let summary = agent.run("郑州天气怎么样")
        @Assert(provider.callCount, 1)
        @Assert(summary.reply.contains("郑州"), true)
        agent.clearTodos()
    }

    /** 契约 6：轮次软顶已要求收尾时不得再续跑（两条指令不能打架） */
    @TestCase
    public func testNoNudgeAtSoftCap(): Unit {
        let provider = TextOnlyProvider(this.replies(["现在运行验证："]))
        let agent = this.buildAgent(provider, 1)     // 软顶 1 轮：本轮结束即到软顶
        agent.clearTodos()
        let id = agent.addTask("跑测试")
        agent.updateTaskStatus(id, TodoStatus.InProgress)
        agent.run("生成 h5 小游戏")
        // 到软顶就直接收场：只 1 次调用，不再续跑
        @Assert(provider.callCount, 1)
        agent.clearTodos()
    }

    /**
     * 契约 7：只有 Pending 待办（模型先列计划再干活）不算"未收尾"。
     *
     * 这条专门锁 `--mock` 端到端：mock 先 todo_write 三条 Pending 再派子代理，
     * 收尾是纯文本答复——若把 Pending 当未完成，每轮会多续跑两次，
     * pty 断言的 `4 rounds` 全部失真。
     */
    @TestCase
    public func testPendingOnlyTodosDoNotNudge(): Unit {
        let provider = TextOnlyProvider(this.replies(["所有工具已执行完毕，任务完成。"]))
        let agent = this.buildAgent(provider, 10)
        agent.clearTodos()
        agent.addTask("汇总1：项目结构和主要模块")
        agent.addTask("汇总2：配置文件的组成")
        agent.addTask("汇总3：测试的组织方式")
        let summary = agent.run("跑 mock 端到端")
        @Assert(provider.callCount, 1)
        @Assert(summary.reply.contains("任务完成"), true)
        agent.clearTodos()
    }

    /**
     * 契约 8：最后一次工具调用**失败**、随后只回纯文本 → 必须续跑。
     *
     * 真实会话铁证（2026-11-06 贪吃蛇 E2E，真实 provider）：模型跑自测拿到
     * `exit code: 1`（`❌ spawnWalls 段数 6~9 got=4`），随后只回一句
     * 「发现真实 bug：…修复 spawnWalls，要求整段有效才计入并重试。」就收场——
     * 工具没再调、bug 没修、也没给用户最终答复。
     *
     * 它同时漏过旧判据的两条腿：本轮模型**从未建待办**（推理型模型常态），
     * 那句承诺句又以**句号**收尾而非冒号。所以要有一条不依赖措辞的
     * 结构性判据：**上一批工具结果里有失败，模型却只回文本 → 视为未收尾**。
     */
    @TestCase
    public func testToolFailureThenTextNudges(): Unit {
        let provider = ToolThenTextProvider("failingprobe", "发现真实 bug，修复 spawnWalls。")
        let registry = ToolRegistry()
        registry.register(FailingProbeTool())
        let config = AgentConfig("test system", 10, Capability(), 0, 0, 6, 6000, "", "contguard")
        let agent = Agent(provider, registry, config)
        agent.clearTodos()
        agent.run("做一个贪吃蛇小游戏并自测")
        // 1 次工具轮 + 1 次纯文本收束 + MAX_NUDGES 次续跑（失败信号未消除，用满预算才收场）
        @Assert(provider.callCount, 2 + ContinuationPolicy.MAX_NUDGES)
        @Assert(this.lastUserText(provider.lastMessages).contains("还没有完成"), true)   // 指令确实注入
        @Assert(this.lastUserText(provider.lastMessages).contains("工具"), true)         // 且点明了"工具失败"
        agent.clearTodos()
    }

    /**
     * 契约 9：最后一次工具调用**成功**、随后纯文本收束 → 照旧正常结束，不得凭空续跑。
     *
     * 没有这条对照，契约 8 可以靠"无条件续跑"作弊，`--mock` 与 pty 的轮数全失真。
     */
    @TestCase
    public func testToolSuccessThenTextDoesNotNudge(): Unit {
        let provider = ToolThenTextProvider("okprobe", "文件已写入，任务完成。")
        let registry = ToolRegistry()
        registry.register(OkProbeTool())
        let config = AgentConfig("test system", 10, Capability(), 0, 0, 6, 6000, "", "contguard")
        let agent = Agent(provider, registry, config)
        agent.clearTodos()
        let summary = agent.run("做一个贪吃蛇小游戏并自测")
        @Assert(provider.callCount, 2)          // 工具轮 + 收尾答复，没有多余续跑
        @Assert(summary.reply.contains("任务完成"), true)
        agent.clearTodos()
    }
}
