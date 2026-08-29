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
        onTokenEstimate: (Int64) -> Unit): ModelResponse {
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
        onTokenEstimate: (Int64) -> Unit): ModelResponse {
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
