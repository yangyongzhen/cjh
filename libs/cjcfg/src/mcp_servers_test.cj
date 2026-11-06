package cjcfg

import std.fs.*
import std.collection.*

/**
 * settings.json "mcp_servers" 段解析测试
 *
 * 覆盖本轮实测发现的坑（2026-11-06 真实 provider E2E）：
 * 模板里的示例键以 `_` 开头（`_example_stdio` / `_example_sse`），它们**只是文档示例**，
 * 但解析循环照样当成真实服务器，于是每次启动都白跑一次 `npx -y …`，
 * 失败后打 4 条 WARN（`_example_stdio initialize 无响应` / `连接服务器 … 失败，跳过`）。
 * 契约：以 `_` 开头的键一律跳过；正常键（含 transport/command/args/url/env）照旧解析。
 *
 * 仓颉测试坑遵守：临时目录 /tmp/cjh_ut_*；Directory.create 不幂等，先清后建。
 */
@Test
public class McpServersConfigTest {

    private static func cleanDir(dir: String): Unit {
        if (!exists(dir)) {
            return
        }
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }

    /** 按名字找服务器（找不到返回 None） */
    private func findServer(cfg: CjhConfig, name: String): Option<McpServerConfig> {
        for (s in cfg.mcpServers) {
            if (s.name == name) {
                return Some(s)
            }
        }
        return None
    }

    /** 契约 1：`_` 开头的示例键不得变成真实服务器 */
    @TestCase
    public func testExampleKeysSkipped(): Unit {
        let dir = testTmpPath("cjh_ut_mcp_skip")
        cleanDir(dir)
        Directory.create(dir)
        var sb = StringBuilder()
        sb.append("{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"mcp_servers\": {")
        // 示例键：形态完全合法（有 command），旧实现会真去启动它
        sb.append("\"_example_stdio\": {\"transport\": \"stdio\", \"command\": \"npx\", ")
        sb.append("\"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"/tmp\"]}, ")
        sb.append("\"_example_sse\": {\"transport\": \"sse\", \"url\": \"http://localhost:9100/sse\"}, ")
        sb.append("\"fs\": {\"transport\": \"stdio\", \"command\": \"npx\", \"args\": [\"-y\", \"fs-server\"]}")
        sb.append("}}")
        File.writeTo("${dir}/settings.json", sb.toString().toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.mcpServers.size, 1)
        @Assert(this.findServer(cfg, "_example_stdio").isNone(), true)
        @Assert(this.findServer(cfg, "_example_sse").isNone(), true)
        @Assert(this.findServer(cfg, "fs").isSome(), true)
        cleanDir(dir)
    }

    /** 契约 2：正常键的 transport / command / args / url / env 照旧解析（防跳过逻辑误伤） */
    @TestCase
    public func testRealServersStillParsed(): Unit {
        let dir = testTmpPath("cjh_ut_mcp_real")
        cleanDir(dir)
        Directory.create(dir)
        var sb = StringBuilder()
        sb.append("{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"mcp_servers\": {")
        sb.append("\"stdio1\": {\"command\": \"node\", \"args\": [\"a.js\"], ")
        sb.append("\"env\": {\"TOKEN\": \"t0\"}}, ")
        sb.append("\"remote1\": {\"transport\": \"sse\", \"url\": \"http://h:9200/sse\"}")
        sb.append("}}")
        File.writeTo("${dir}/settings.json", sb.toString().toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.mcpServers.size, 2)
        let s = this.findServer(cfg, "stdio1").getOrThrow()
        @Assert(s.transport, "stdio")      // 缺省 stdio
        @Assert(s.command, "node")
        @Assert(s.args.size, 1)
        @Assert(s.args[0], "a.js")
        @Assert(s.env.contains("TOKEN"), true)
        @Assert(s.env.get("TOKEN").getOrThrow(), "t0")
        let r = this.findServer(cfg, "remote1").getOrThrow()
        @Assert(r.transport, "sse")
        @Assert(r.url, "http://h:9200/sse")
        cleanDir(dir)
    }
}
