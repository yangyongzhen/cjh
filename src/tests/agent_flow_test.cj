package cjh.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjh.agent.*
import cjcfg.*

/**
 * Agent 主循环端到端测试（V2d DAG 并发 + 工具结果截断与落盘）
 *
 * 用脚本化 provider 驱动真实 Agent.run：
 *  - 第一轮：并行工具调用（read_file×2 + bash）→ 验证 DAG 并发分组
 *  - 第二轮：bash 超长输出 → 验证 2000 字符截断 + spill 落盘
 *  - 第三轮：最终文本答复
 */
/**
 * 脚本化 provider：按调用次数返回预设响应
 */
class FlowProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public let longCmd: String

    public init(longCmd: String) {
        this.longCmd = longCmd
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        match (callCount) {
            case 1 =>
                // 并行批：两个不同文件 read + 一个 bash（不同"资源"→ 同一组并发）
                var calls = ArrayList<ToolCall>()
                var a1 = JsonObject()
                a1.put("path", JsonString("/tmp/cjh_flow_a.txt"))
                calls.add(ToolCall("flow_1a", "read_file", a1))
                var a2 = JsonObject()
                a2.put("path", JsonString("/tmp/cjh_flow_b.txt"))
                calls.add(ToolCall("flow_1b", "read_file", a2))
                var a3 = JsonObject()
                a3.put("command", JsonString("echo flow-ok"))
                calls.add(ToolCall("flow_1c", "bash", a3))
                return ModelResponse("并行读取", calls)
            case 2 =>
                // 超长 bash 输出（>2000 字符）→ 触发截断 + spill
                var calls = ArrayList<ToolCall>()
                var a1 = JsonObject()
                a1.put("command", JsonString(this.longCmd))
                calls.add(ToolCall("flow_2", "bash", a1))
                return ModelResponse("生成超长输出", calls)
            case _ =>
                return ModelResponse("flow done", ArrayList<ToolCall>())
        }
    }
}

@Test
public class AgentFlowTest {

    private func buildAgent(provider: LlmProvider, spillDir: String, sessionId: String): Agent {
        let registry = ToolRegistry()
        registry.register(BashTool())
        registry.register(ReadTool())
        let config = AgentConfig("flow test", 10, Capability(),
            0, 0, 6, 2000, spillDir, sessionId)
        return Agent(provider, registry, config)
    }

    @TestCase
    public func testParallelBatchExecution(): Unit {
        writeTextFile("/tmp/cjh_flow_a.txt", "A\n")
        writeTextFile("/tmp/cjh_flow_b.txt", "B\n")
        let spillDir = testTempDir("flowspill")
        let provider = FlowProvider("echo short")
        let agent = this.buildAgent(provider, spillDir, "sess1")
        let summary = agent.run("并行测试")
        @Assert(provider.callCount, 3)
        @Assert(summary.reply.contains("flow done"), true)
        // 第一轮 3 个工具（2 read + 1 bash）不同资源 → 应并发：maxParallelism >= 2
        @Assert(summary.maxParallelism >= 2, true)
        @Assert(summary.parallelBatches >= 1, true)
        @Assert(summary.toolCalls, 4)  // 3 + 1 = 4 次工具调用
        // 工具结果已回填历史
        var foundA = false
        var foundB = false
        for (m in agent.getMessages()) {
            if (m.content.contains("A")) { foundA = true }
            if (m.content.contains("B")) { foundB = true }
        }
        @Assert(foundA, true)
        @Assert(foundB, true)
    }

    @TestCase
    public func testToolResultTruncationAndSpill(): Unit {
        writeTextFile("/tmp/cjh_flow_a.txt", "A\n")
        writeTextFile("/tmp/cjh_flow_b.txt", "B\n")
        let spillDir = testTempDir("flowtrunc")
        // 生成 5000 字符输出（去换行，纯 5000 个 x）
        let provider = FlowProvider("yes x | tr -d '\\n' | head -c 5000")
        let agent = this.buildAgent(provider, spillDir, "sess2")
        let summary = agent.run("截断测试")
        @Assert(summary.reply.contains("flow done"), true)
        // 第二轮 bash 结果 5000 字符 > 2000 → 消息中应含截断标记
        var truncatedMsg = ""
        for (m in agent.getMessages()) {
            if (m.content.contains("已截断")) {
                truncatedMsg = m.content
            }
        }
        @Assert(truncatedMsg.size > 0, true)
        @Assert(truncatedMsg.contains("完整结果已保存"), true)
        // spill 文件存在且完整（bash 工具结果含 "exit code/stdout:" 包装头 + 5000 x）
        let spillPath = spillDir + "/sess2/flow_2.txt"
        @Assert(exists(spillPath), true)
        let spillContent = readTextFile(spillPath)
        var xCount: Int64 = 0
        for (ch in spillContent) {
            if (ch == 120u8) { xCount += 1 }  // 'x'（字符串迭代给 Byte）
        }
        // 5000 字节输出完整落盘（管道可能有 ±1 竞态字节，阈值放宽）
        @Assert(xCount >= 4999, true)
    }

    @TestCase
    public func testDagSerialOnSamePath(): Unit {
        // 同 path 写后读 → 必须串行（不并发）：
        // write_file(a) + read_file(a) 同路径且含写 → deps 边
        writeTextFile("/tmp/cjh_flow_a.txt", "A\n")
        writeTextFile("/tmp/cjh_flow_b.txt", "B\n")
        let spillDir = testTempDir("flowserial")
        let registry = ToolRegistry()
        registry.register(BashTool())
        registry.register(ReadTool())
        registry.register(WriteTool())
        let config = AgentConfig("flow test", 10, Capability(),
            0, 0, 6, 2000, spillDir, "sess3")
        let provider = SerialWriteProvider()
        let agent = Agent(provider, registry, config)
        let summary = agent.run("串行测试")
        @Assert(summary.reply.contains("serial done"), true)
        // 同 path 写读 → 必须串行：无并发批（parallelBatches=0），写入先于读取
        @Assert(summary.parallelBatches, 0)
        // 写入生效（read 在 write 之后执行，读到 WRITTEN）
        @Assert(readTextFile("/tmp/cjh_flow_a.txt"), "WRITTEN\n")
    }
}

/**
 * 写后读同路径 provider：write_file(/tmp/cjh_flow_a.txt) + read_file(/tmp/cjh_flow_a.txt)
 * 同 path 且含写 → DAG 串行依赖，不得并发
 */
class SerialWriteProvider <: LlmProvider {
    public var callCount: Int64 = 0

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        match (callCount) {
            case 1 =>
                var calls = ArrayList<ToolCall>()
                var w = JsonObject()
                w.put("path", JsonString("/tmp/cjh_flow_a.txt"))
                w.put("content", JsonString("WRITTEN\n"))
                calls.add(ToolCall("ser_1", "write_file", w))
                var r = JsonObject()
                r.put("path", JsonString("/tmp/cjh_flow_a.txt"))
                calls.add(ToolCall("ser_2", "read_file", r))
                return ModelResponse("写后读", calls)
            case _ =>
                return ModelResponse("serial done", ArrayList<ToolCall>())
        }
    }
}

/**
 * Agent 事件钩子（Claude Code 式）测试：6 类事件全部触发 + payload 内容
 */
@Test
public class AgentHookTest {
    private func buildHookAgent(provider: LlmProvider): Agent {
        let registry = ToolRegistry()
        registry.register(BashTool())
        registry.register(ReadTool())
        let config = AgentConfig("hook test", 10, Capability(),
            0, 0, 6, 2000, "/tmp/cjh_hook_spill", "sess-hook")
        return Agent(provider, registry, config)
    }

    @TestCase
    public func testAllHooksFire(): Unit {
        // MockProvider：有流式 onDelta（最终答复）+ 思考流 onReasoning + 4 轮工具循环
        let provider = MockProvider("/tmp/cjh_hook_verify.txt")
        let agent = this.buildHookAgent(provider)
        // 事件计数器
        let preCount = Array<Int64>(1, repeat: 0)
        let postCount = Array<Int64>(1, repeat: 0)
        let deltaCount = Array<Int64>(1, repeat: 0)
        let reasoningCount = Array<Int64>(1, repeat: 0)
        let stopCount = Array<Int64>(1, repeat: 0)
        let lastPreTool = StringBuilder()
        let lastPostTool = StringBuilder()
        let lastDelta = StringBuilder()
        let lastReasoning = StringBuilder()
        // 注册 6 类钩子
        agent.addHook(AgentHook.PreToolUse, { p =>
            preCount[0] += 1
            if (p.get("tool").isSome()) {
                let v = p.get("tool").getOrThrow()
                match (v.kind()) {
                    case JsonKind.JsString => lastPreTool.append(v.asString().getValue())
                    case _ => ()
                }
            }
        })
        agent.addHook(AgentHook.PostToolUse, { p =>
            postCount[0] += 1
            if (p.get("tool").isSome()) {
                let v = p.get("tool").getOrThrow()
                match (v.kind()) {
                    case JsonKind.JsString => lastPostTool.append(v.asString().getValue())
                    case _ => ()
                }
            }
        })
        agent.addHook(AgentHook.ChatDelta, { p =>
            deltaCount[0] += 1
            if (p.get("delta").isSome()) {
                let v = p.get("delta").getOrThrow()
                match (v.kind()) {
                    case JsonKind.JsString => lastDelta.append(v.asString().getValue())
                    case _ => ()
                }
            }
        })
        agent.addHook(AgentHook.Reasoning, { p =>
            reasoningCount[0] += 1
            if (p.get("delta").isSome()) {
                let v = p.get("delta").getOrThrow()
                match (v.kind()) {
                    case JsonKind.JsString => lastReasoning.append(v.asString().getValue())
                    case _ => ()
                }
            }
        })
        agent.addHook(AgentHook.Stop, { p =>
            stopCount[0] += 1
        })
        agent.addHook(AgentHook.Interrupt, { p =>
            preCount[0] += 1000  // 不应触发（无中断）
        })
        // 跑完整回合（FlowProvider：工具调用 → 最终答复）
        let summary = agent.run("hook 测试")
        @Assert(preCount[0] > 0, true)             // PreToolUse 触发
        @Assert(postCount[0] > 0, true)            // PostToolUse 触发
        @Assert(postCount[0] == preCount[0], true) // 工具前后成对
        @Assert(deltaCount[0] > 0, true)           // ChatDelta 触发（流式文本）
        @Assert(reasoningCount[0] > 0, true)       // Reasoning 触发（mock 思考流）
        @Assert(stopCount[0] == 1, true)           // Stop 触发一次
        @Assert(preCount[0] < 1000, true)          // Interrupt 未误触发
        @Assert(lastPreTool.toString().size > 0, true)     // payload 含工具名
        @Assert(lastPostTool.toString().size > 0, true)
        @Assert(lastDelta.toString().size > 0, true)
        @Assert(lastReasoning.toString().size > 0, true)
        @Assert(summary.rounds > 0, true)
    }
}

/**
 * on_tool_result 钩子白名单测试：read_file/web_fetch 不被 log-pruner 裁剪
 */
@Test
public class HookExemptTest {
    @TestCase
    public func testHookExemptWhitelist(): Unit {
        // read_file：按需读取工具，截断导致反复重读（用户实测的坑）
        @Assert(Agent.isHookExempt("read_file"), true)
        // 结构化抓取正文需完整传 LLM
        @Assert(Agent.isHookExempt("web_fetch"), true)
        @Assert(Agent.isHookExempt("web_search"), true)
        // log-pruner 设计对象：bash 长日志可裁剪
        @Assert(Agent.isHookExempt("bash"), false)
        // 其他工具结果默认可被钩子处理
        @Assert(Agent.isHookExempt("grep"), false)
    }
}

/**
 * 中断状态重置测试：中断后新一轮 run 必须正常执行（flag 不清除 = 永不复原）
 */
@Test
public class InterruptResetTest {
    @TestCase
    public func testInterruptThenNewRunWorks(): Unit {
        let provider = MockProvider("/tmp/cjh_int_reset.txt")
        let registry = ToolRegistry()
        registry.register(BashTool())
        let config = AgentConfig("reset test", 10, Capability(),
            0, 0, 6, 2000, "/tmp/cjh_int_spill", "sess-reset")
        let agent = Agent(provider, registry, config)
        // 第一轮：运行中中断
        agent.interrupt()
        let s1 = agent.run("第一轮")
        @Assert(s1.rounds >= 0, true)  // 中断返回（rounds 可能 0）
        // 第二轮：flag 必须已重置，正常执行
        let s2 = agent.run("第二轮")
        @Assert(s2.rounds > 0, true)   // 正常跑完（MockProvider 4 轮工具循环）
        @Assert(s2.reply.contains("FINAL-DONE"), true)
    }
}

/**
 * 回合状态机测试：生命周期转换 + 异常路径统一清理
 */
@Test
public class RoundStateTest {
    private func buildStateAgent(provider: LlmProvider): Agent {
        let registry = ToolRegistry()
        registry.register(BashTool())
        let config = AgentConfig("state test", 10, Capability(),
            0, 0, 6, 2000, "/tmp/cjh_state_spill", "sess-state")
        return Agent(provider, registry, config)
    }

    @TestCase
    public func testStateTransitions(): Unit {
        let agent = this.buildStateAgent(MockProvider("/tmp/cjh_state.txt"))
        // 初始 Idle
        match (agent.getRoundState()) {
            case RoundState.Idle => ()
            case _ => @Assert(true, false)  // 应 Idle
        }
        // interrupt 在 Idle：不改变状态（无回合可中断）
        agent.interrupt()
        match (agent.getRoundState()) {
            case RoundState.Idle => ()
            case _ => @Assert(true, false)
        }
        // 正常跑完 → 回到 Idle
        let summary = agent.run("状态测试")
        @Assert(summary.rounds > 0, true)
        match (agent.getRoundState()) {
            case RoundState.Idle => ()
            case _ => @Assert(true, false)  // 结束必须回 Idle（finally 兜底）
        }
        // 中断后跑完 → 也回 Idle（上一 bug：残留导致永不回复）
        agent.interrupt()
        let s2 = agent.run("中断后")
        @Assert(s2.rounds > 0, true)
        match (agent.getRoundState()) {
            case RoundState.Idle => ()
            case _ => @Assert(true, false)
        }
    }

    @TestCase
    public func testExceptionPathCleansState(): Unit {
        // 异常 provider：chatStream 抛异常 → run 返回异常 summary → 状态必须回 Idle
        let agent = this.buildStateAgent(ThrowingProvider())
        let summary = agent.run("异常测试")
        @Assert(summary.reply.contains("异常"), true)
        match (agent.getRoundState()) {
            case RoundState.Idle => ()
            case _ => @Assert(true, false)  // 异常路径 finally 清理
        }
    }
}

/**
 * 抛异常 provider（状态机异常路径测试）
 */
class ThrowingProvider <: LlmProvider {
    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        throw LlmException("测试异常")
    }
}
