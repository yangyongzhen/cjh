package cjh.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjh.agent.*
import cjh.tools.*

/**
 * 一个工具在第一批执行中触发中断：后续拓扑组必须整组跳过并回填明确错误，
 * 不能继续 spawn，也不能留空结果冒充成功。
 */
class InterruptOnExecuteTool <: CjhTool {
    public var agentRef: ?Agent = None
    public var calls: Int64 = 0

    public override func spec(): ToolSpec {
        return ToolSpec("probe_interrupt", "interrupt probe", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        match (this.agentRef) {
            case Some(a) => a.interrupt()
            case None => ()
        }
        return ToolResult("FIRST-EXECUTED", false)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

class TwoGroupProvider <: LlmProvider {
    private let readPath: String
    public var callCount: Int64 = 0

    public init(readPath: String) {
        this.readPath = readPath
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount == 1) {
            var calls = ArrayList<ToolCall>()
            var a = JsonObject()
            calls.add(ToolCall("i1", "probe_interrupt", a))
            var r = JsonObject()
            r.put("path", JsonString(this.readPath))
            calls.add(ToolCall("i2", "read_file", r))
            return ModelResponse("two groups", calls)
        }
        return ModelResponse("done", ArrayList<ToolCall>())
    }
}

@Test
public class InterruptGuardTest {
    @TestCase
    public func testInterruptSkipsRemainingGroups(): Unit {
        let dir = testTempDir("interrupt_guard")
        let file = dir + "/x.txt"
        writeTextFile(file, "SHOULD-NOT-BE-READ")
        let probe = InterruptOnExecuteTool()
        let registry = ToolRegistry()
        registry.register(probe)
        registry.register(ReadTool())
        let agent = Agent(TwoGroupProvider(file), registry,
            AgentConfig("interrupt guard", 5, Capability(), 0, 0, 6, 2000, dir + "/spill", "ig"))
        probe.agentRef = agent
        let summary = agent.run("中断后不再执行")
        @Assert(probe.calls, 1)
        // 中断后的第二组不得执行：read_file 结果应是明确错误，而不是文件内容
        var readResult = ""
        for (m in agent.getMessages()) {
            if (m.role == "tool" && m.name == "read_file") {
                readResult = m.content
            }
        }
        @Assert(readResult.contains("未执行"), true)
        @Assert(readResult.contains("SHOULD-NOT-BE-READ"), false)
        @Assert(summary.toolCalls, 2)
    }
}
