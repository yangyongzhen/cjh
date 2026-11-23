package cjh.agent

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjcfg.*

/**
 * 工具审批闸门测试
 *
 * 契约：一次工具调用只向用户确认一次。capability.approval 命中工具名时，
 * 工具域已经确认；后续命令域/文件域的 NeedApproval 不得重复弹窗，否则
 * TUI 里一次 bash 要按两次 y（实测用户以为陷入审批循环）。
 *
 * 但**安全规则不因确认而失效**：命令黑名单、路径排除等 Deny 仍必须拒绝。
 */

/** 假 bash 工具：只记录调用次数，不真正 spawn。 */
class GateProbeTool <: CjhTool {
    public var calls: Int64 = 0

    public override func spec(): ToolSpec {
        return ToolSpec("bash", "审批闸门测试探针", JsonObject())
    }

    public override func execute(_: JsonObject): ToolResult {
        this.calls += 1
        return ToolResult("probe-ran", false)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

/** 第 1 轮发一次 bash 调用，第 2 轮收场。 */
class GateProvider <: LlmProvider {
    private let command: String

    public init(command: String) {
        this.command = command
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        _: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        _: () -> Bool): ModelResponse {
        // 用内部计数判断轮次：provider 实例只服务一次 run
        this.rounds += 1
        if (this.rounds == 1) {
            let args = JsonObject()
            args.put("command", JsonString(this.command))
            let calls = ArrayList<ToolCall>()
            calls.add(ToolCall("call_gate", "bash", args))
            return ModelResponse("执行命令", calls)
        }
        return ModelResponse("GATE-DONE", ArrayList<ToolCall>())
    }

    private var rounds: Int64 = 0
}

/** 假文件工具:按给定工具名记录调用次数,不落盘。 */
class GateFileProbeTool <: CjhTool {
    public var calls: Int64 = 0
    private let name: String

    public init(name: String) {
        this.name = name
    }

    public override func spec(): ToolSpec {
        return ToolSpec(this.name, "文件审批闸门测试探针", JsonObject())
    }

    public override func execute(_: JsonObject): ToolResult {
        this.calls += 1
        return ToolResult("file-probe-ran", false)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

/** 第 1 轮发一次任意工具调用,第 2 轮收场。 */
class GateCallProvider <: LlmProvider {
    private let name: String
    private let args: JsonObject
    private var rounds: Int64 = 0

    public init(name: String, args: JsonObject) {
        this.name = name
        this.args = args
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        _: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        _: () -> Bool): ModelResponse {
        this.rounds += 1
        if (this.rounds == 1) {
            let calls = ArrayList<ToolCall>()
            calls.add(ToolCall("call_gate_fs", this.name, this.args))
            return ModelResponse("动一下文件", calls)
        }
        return ModelResponse("GATE-DONE", ArrayList<ToolCall>())
    }
}

func gateCapability(): Capability {
    let cap = Capability()
    cap.enabled = true
    cap.tools.add("bash")
    cap.approval.add("bash")
    cap.commands.add("echo")
    return cap
}

func toolMessages(agent: Agent): ArrayList<String> {
    let out = ArrayList<String>()
    for (m in agent.getMessages()) {
        if (m.role == "tool") {
            out.add(m.content)
        }
    }
    return out
}

@Test
public class ApprovalGateTest {

    @TestCase
    public func testToolApprovalCoversCommandLayer(): Unit {
        let tool = GateProbeTool()
        let registry = ToolRegistry()
        registry.register(tool)
        let agent = Agent(GateProvider("echo hi"), registry, AgentConfig("gate", 4, gateCapability()))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            true
        }
        let summary = agent.run("跑一次 bash")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        @Assert(tool.calls, 1)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0], "probe-ran")
    }

    @TestCase
    public func testRejectedToolApprovalRunsNothing(): Unit {
        let tool = GateProbeTool()
        let registry = ToolRegistry()
        registry.register(tool)
        let agent = Agent(GateProvider("echo hi"), registry, AgentConfig("gate", 4, gateCapability()))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            false
        }
        let summary = agent.run("跑一次 bash")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        @Assert(tool.calls, 0)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0].contains("操作被用户拒绝"), true)
    }

    @TestCase
    public func testDenyRulesStillApplyAfterToolApproval(): Unit {
        let tool = GateProbeTool()
        let registry = ToolRegistry()
        registry.register(tool)
        let cap = gateCapability()
        cap.procDeny.add("rm")
        let agent = Agent(GateProvider("rm -rf /tmp/nope"), registry, AgentConfig("gate", 4, cap))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            true
        }
        let summary = agent.run("跑一次 bash")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        @Assert(tool.calls, 0)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0].contains("被安全策略拒绝"), true)
    }

    @TestCase
    public func testToolApprovalCoversPathLayer(): Unit {
        // 工具域与文件域同时命中审批:一次 write_file 只能问一次。
        let tool = GateFileProbeTool("write_file")
        let registry = ToolRegistry()
        registry.register(tool)
        let cap = Capability()
        cap.enabled = true
        cap.tools.add("write_file")
        cap.approval.add("write_file")
        cap.approval.add("fs:write")
        cap.fsAllow.add("/tmp/cjh_gate_*")
        var args = JsonObject()
        args.put("path", JsonString("/tmp/cjh_gate_probe.txt"))
        args.put("content", JsonString("x"))
        let agent = Agent(GateCallProvider("write_file", args), registry,
            AgentConfig("gate", 4, cap))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            true
        }
        let summary = agent.run("写一个文件")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        // 第一次命中的是工具域(文件域必须因"已确认该工具"而跳过)
        @Assert(asked[0].contains("工具 write_file"), true)
        @Assert(tool.calls, 1)
    }

    /**
     * 无人值守策略：unattended_approval=tests 时，改测试断言不再弹审批，
     * 但工具结果必须带审计前缀（模型最终答复要解释改了哪条断言）。
     * 反之默认 deny 仍走审批；这里用"回调返回 false"证明它确实问了。
     */
    @TestCase
    public func testUnattendedPolicyAutoApprovesTestContract(): Unit {
        let path = "/tmp/cjh_ut_unattended_gate_test.py"
        removeIfExists(path)
        File.writeTo(path, "def test_x():\n    assert 1 == 1\n".toArray())
        let tool = GateFileProbeTool("write_file")
        let registry = ToolRegistry()
        registry.register(tool)
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("def test_x():\n    assert 1 == 2\n"))
        let config = AgentConfig("gate", 4, Capability())
        config.unattendedApproveTests = true
        let agent = Agent(GateCallProvider("write_file", args), registry, config)
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            false
        }
        let summary = agent.run("改测试断言")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 0)
        @Assert(tool.calls, 1)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0].contains("无人值守审批"), true)
        @Assert(msgs[0].contains("file-probe-ran"), true)
        removeIfExists(path)
    }

    @TestCase
    public func testUnattendedPolicyDefaultsToDeny(): Unit {
        let path = "/tmp/cjh_ut_unattended_gate_deny_test.py"
        removeIfExists(path)
        File.writeTo(path, "def test_x():\n    assert 1 == 1\n".toArray())
        let tool = GateFileProbeTool("write_file")
        let registry = ToolRegistry()
        registry.register(tool)
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("def test_x():\n    assert 1 == 2\n"))
        let agent = Agent(GateCallProvider("write_file", args), registry,
            AgentConfig("gate", 4, Capability()))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            false
        }
        let summary = agent.run("改测试断言")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        @Assert(tool.calls, 0)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0].contains("操作被用户拒绝"), true)
        removeIfExists(path)
    }

    @TestCase
    public func testPathDenyStillAppliesAfterToolApproval(): Unit {
        // 已确认"允许用 write_file"不等于放弃路径排除:fsDeny 仍必须拒绝。
        let tool = GateFileProbeTool("write_file")
        let registry = ToolRegistry()
        registry.register(tool)
        let cap = Capability()
        cap.enabled = true
        cap.tools.add("write_file")
        cap.approval.add("write_file")
        cap.fsDeny.add("/etc/*")
        var args = JsonObject()
        args.put("path", JsonString("/etc/passwd"))
        args.put("content", JsonString("x"))
        let agent = Agent(GateCallProvider("write_file", args), registry,
            AgentConfig("gate", 4, cap))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            asked.add(reason)
            true
        }
        let summary = agent.run("写系统文件")
        @Assert(summary.reply.contains("GATE-DONE"), true)
        @Assert(asked.size, 1)
        @Assert(tool.calls, 0)
        let msgs = toolMessages(agent)
        @Assert(msgs.size, 1)
        @Assert(msgs[0].contains("被安全策略拒绝"), true)
    }
}
