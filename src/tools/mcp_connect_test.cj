package cjh.tools

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import cjcfg.*
import cjutil.*

/**
 * issue #15 回归：
 *   1. stdio 子进程环境必须继承父进程（launch 的 environment 是完整替换）
 *   2. 单个 stdio 服务器握手挂死时必须超时并继续后面的服务器
 *      （旧实现 recv 无预算，connectAll 顺序循环被第一个服务器永久卡住）
 */
@Test
public class McpChildEnvTest {

    @TestCase
    public func testInheritsParentAndAppliesOverrides(): Unit {
        let extra = HashMap<String, String>()
        extra.add("CJH_MCP_TEST", "1")
        let env = mcpChildEnv(extra)
        @Assert(env["CJH_MCP_TEST"], "1")
        // PATH 必须来自父进程：缺了它，python3/node 型服务器的子进程找不到依赖
        @Assert(env.contains("PATH"), true)
        @Assert(env["PATH"].size > 0, true)

        let override = HashMap<String, String>()
        override.add("PATH", "/custom/bin")
        let env2 = mcpChildEnv(override)
        @Assert(env2["PATH"], "/custom/bin")
    }
}

@When[os != "Windows"]
@Test
public class McpStdioTimeoutTest {

    @TestCase
    public func testHangingServerDoesNotBlockFollowingServer(): Unit {
        let script = tmpPath("cjh_ut_mcp_echo.sh")
        // 极简 stdio MCP 服务器：按请求方法回固定 JSON（mailbox 顺序：
        // initialize → notifications/initialized（无 id，不回复）→ tools/list）
        let body = "while IFS= read -r line; do\n" +
            "  case \"$line\" in\n" +
            "    *\\\"method\\\":\\\"initialize\\\"*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\"}}' ;;\n" +
            "    *\\\"method\\\":\\\"tools/list\\\"*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo_tool\",\"description\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}]}}' ;;\n" +
            "  esac\n" +
            "done\n"
        File.writeTo(script, body.toArray())

        let hang = McpServerConfig("hang")
        hang.command = "/bin/sleep"
        hang.args.add("5")
        let echo = McpServerConfig("echo")
        echo.command = "/bin/sh"
        echo.args.add(script)

        let servers = ArrayList<McpServerConfig>()
        servers.add(hang)
        servers.add(echo)

        // 先单独确认 echo 服务器本身可握手、可列工具（把脚本/客户端问题与隔离逻辑分开）
        let probe = McpClient(echo)
        @Assert(probe.connect(connectTimeoutSeconds: 2), true)
        @Assert(probe.listTools(connectTimeoutSeconds: 2).size, 1)
        probe.disconnect()

        let registry = ToolRegistry()
        let mgr = McpManager()
        let t0 = DateTime.now()
        let fut: Future<Unit> = spawn { mgr.connectAll(servers, registry, connectTimeoutSeconds: 1) }
        // 超时回归若复现，这里先失败而不是整个测试进程挂死
        fut.get(Duration.second * 10)
        let elapsed = (DateTime.now() - t0).toMilliseconds()

        @Assert(registry.has("echo_tool"), true)
        @Assert(elapsed < 8000, true)
        mgr.disconnectAll()
        rmFile(script)
    }
}
