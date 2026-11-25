package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjcfg.*
import cjllm.*
import cjh.agent.*
import cjh.tools.*

/**
 * task scope（AgentConfig.writeScope）不能只检查带 path 参数的工具：
 * bash 与声明式技能工具都能执行任意命令，必须整类拒绝，否则 scope 形同虚设。
 */
class ScopeProbeProvider <: LlmProvider {
    private let toolName: String
    private let toolArgs: JsonObject
    public var callCount: Int64 = 0

    public init(toolName: String, toolArgs: JsonObject) {
        this.toolName = toolName
        this.toolArgs = toolArgs
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        _: (String) -> Unit, _: (String) -> Unit,
        _: (Int64) -> Unit, _: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount == 1) {
            var calls = ArrayList<ToolCall>()
            calls.add(ToolCall("scope_1", this.toolName, this.toolArgs))
            return ModelResponse("probe", calls)
        }
        return ModelResponse("done", ArrayList<ToolCall>())
    }
}

@Test
public class WriteScopeSurfaceTest {
    private func buildAgentWithScope(provider: LlmProvider, scoped: Bool): Agent {
        let registry = ToolRegistry()
        registry.register(BashTool())
        let specs = HashMap<String, (String, String)>()
        specs.add("x", ("string", "payload"))
        registry.register(DeclarativeTool("scope_decl", "echo", "echo SHOULD-NOT-RUN \${x}", specs))
        // 自报 readOnly 也不能作为 scope 放行依据：MCP 服务端/插件脚本可以谎报，
        // 且参数 schema 里没有可校验的写路径。
        let mcpClient = McpClient(McpServerConfig("scope-mcp"))
        registry.register(McpTool("scope_mcp", "mcp probe", JsonObject(), true, mcpClient))
        registry.register(PluginTool("scope_plugin", "plugin probe", "/bin/false", JsonObject(), true))
        let config = AgentConfig("scope", 5, Capability(), 0, 0, 6, 2000,
            testTempDir("scope_spill"), "scope")
        if (scoped) {
            config.writeScope.add("src/**")
        }
        return Agent(provider, registry, config)
    }

    private func buildAgent(provider: LlmProvider): Agent {
        return this.buildAgentWithScope(provider, true)
    }

    private func lastToolResult(agent: Agent, name: String): String {
        var found = ""
        for (m in agent.getMessages()) {
            if (m.role == "tool" && m.name == name) {
                found = m.content
            }
        }
        return found
    }

    @TestCase
    public func testScopeRejectsBash(): Unit {
        var args = JsonObject()
        args.put("command", JsonString("echo SCOPE-LEAK"))
        let agent = this.buildAgent(ScopeProbeProvider("bash", args))
        let summary = agent.run("scope bash")
        @Assert(summary.reply.contains("done"), true)
        let result = this.lastToolResult(agent, "bash")
        @Assert(result.contains("超出本子代理写域"), true)
        @Assert(result.contains("SCOPE-LEAK"), false)
    }

    @TestCase
    public func testScopeRejectsDeclarativeTool(): Unit {
        var args = JsonObject()
        args.put("x", JsonString("hi"))
        let agent = this.buildAgent(ScopeProbeProvider("scope_decl", args))
        let summary = agent.run("scope decl")
        @Assert(summary.reply.contains("done"), true)
        let result = this.lastToolResult(agent, "scope_decl")
        @Assert(result.contains("超出本子代理写域"), true)
        @Assert(result.contains("SHOULD-NOT-RUN"), false)
    }

    @TestCase
    public func testScopeRejectsMcpToolEvenIfReadOnly(): Unit {
        let agent = this.buildAgent(ScopeProbeProvider("scope_mcp", JsonObject()))
        let summary = agent.run("scope mcp")
        @Assert(summary.reply.contains("done"), true)
        let result = this.lastToolResult(agent, "scope_mcp")
        @Assert(result.contains("超出本子代理写域"), true)
        // 未被转发到 MCP 客户端（未连接时 callTool 会回 "[MCP] 发送 tools/call 失败"）
        @Assert(result.contains("[MCP]"), false)
    }

    @TestCase
    public func testScopeRejectsPluginToolEvenIfReadOnly(): Unit {
        let agent = this.buildAgent(ScopeProbeProvider("scope_plugin", JsonObject()))
        let summary = agent.run("scope plugin")
        @Assert(summary.reply.contains("done"), true)
        let result = this.lastToolResult(agent, "scope_plugin")
        @Assert(result.contains("超出本子代理写域"), true)
        @Assert(result.contains("plugin failed"), false)
        @Assert(result.contains("plugin script not found"), false)
    }

    @TestCase
    public func testMcpToolAllowedWithoutScope(): Unit {
        let agent = this.buildAgentWithScope(ScopeProbeProvider("scope_mcp", JsonObject()), false)
        let summary = agent.run("unscoped mcp")
        @Assert(summary.reply.contains("done"), true)
        let result = this.lastToolResult(agent, "scope_mcp")
        @Assert(result.contains("超出本子代理写域"), false)
        @Assert(result.contains("[MCP]"), true)
    }
}
