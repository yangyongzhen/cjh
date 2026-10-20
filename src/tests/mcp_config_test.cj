package cjh.tests

import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import cjcfg.*
import cjutil.*

/**
 * MCP 服务器配置读写测试（settings.json "mcp_servers" 段）
 *
 * 锁定 Web 侧缺口修复：`POST /api/settings` 原先**不能写** mcpServers
 * （applySettingsUpdate 对未知键静默忽略），GET 也不返回该字段。本组用例覆盖：
 *  - parseMcpServersJson：解析 + 校验（缺 name / stdio 缺 command / sse 缺 url /
 *    非法 transport / 重名 / 非数组）均返回可读错误且列表为空
 *  - mcpServersToJsonArray：GET 用数组形态返回，env 值可脱敏
 *  - CjhConfig.replaceMcpServers + saveAll：落盘并可重新加载，读-改-写保留未知字段
 */
@Test
public class McpConfigTest {

    @TestCase
    public func testParseStdioServer(): Unit {
        let raw = "[{\"name\":\"fs\",\"transport\":\"stdio\",\"command\":\"npx\"," +
            "\"args\":[\"-y\",\"server-filesystem\",\"/tmp\"],\"env\":{\"K\":\"V\"}}]"
        let (list, err) = parseMcpServersJson(JsonValue.fromStr(raw))
        @Assert(err, "")
        @Assert(list.size, 1)
        @Assert(list[0].name, "fs")
        @Assert(list[0].transport, "stdio")
        @Assert(list[0].command, "npx")
        @Assert(list[0].args.size, 3)
        @Assert(list[0].args[2], "/tmp")
    }

    @TestCase
    public func testParseSseAndDefaultTransport(): Unit {
        // sse 显式 transport + 缺省 transport（默认 stdio）
        let raw = "[{\"name\":\"remote\",\"transport\":\"sse\",\"url\":\"http://127.0.0.1:9/sse\"}," +
            "{\"name\":\"plain\",\"command\":\"node\"}]"
        let (list, err) = parseMcpServersJson(JsonValue.fromStr(raw))
        @Assert(err, "")
        @Assert(list.size, 2)
        @Assert(list[0].url, "http://127.0.0.1:9/sse")
        @Assert(list[1].transport, "stdio")
        @Assert(list[1].command, "node")
    }

    @TestCase
    public func testParseRejectsInvalidEntries(): Unit {
        let cases = ArrayList<String>()
        cases.add("{}")                                                      // 非数组
        cases.add("[1]")                                                     // 元素非对象
        cases.add("[{\"transport\":\"stdio\",\"command\":\"npx\"}]")          // 缺 name
        cases.add("[{\"name\":\"\"}]")                                        // name 为空
        cases.add("[{\"name\":\"a\"}]")                                       // stdio 缺 command
        cases.add("[{\"name\":\"a\",\"transport\":\"sse\"}]")                  // sse 缺 url
        cases.add("[{\"name\":\"a\",\"transport\":\"http\",\"url\":\"u\"}]")   // 非法 transport
        cases.add("[{\"name\":\"a\",\"command\":\"x\"},{\"name\":\"a\",\"command\":\"y\"}]")  // 重名
        for (i in 0..cases.size) {
            let (list, err) = parseMcpServersJson(JsonValue.fromStr(cases[i]))
            @Assert(err.size > 0, true)
            @Assert(list.size, 0)
        }
    }

    @TestCase
    public func testToJsonArrayMasksEnv(): Unit {
        let raw = "[{\"name\":\"fs\",\"command\":\"npx\",\"env\":{\"TOKEN\":\"sk-secret\"}}]"
        let (list, err) = parseMcpServersJson(JsonValue.fromStr(raw))
        @Assert(err, "")
        // 脱敏（GET /api/settings 用）：密钥不外泄
        var masked = JsonObject()
        masked.put("servers", mcpServersToJsonArray(list, true))
        let maskedText = masked.toJsonString()
        @Assert(maskedText.contains("sk-secret"), false)
        @Assert(maskedText.contains("***"), true)
        // 不脱敏（落盘 / 内部用）：原值保留
        var plain = JsonObject()
        plain.put("servers", mcpServersToJsonArray(list, false))
        @Assert(plain.toJsonString().contains("sk-secret"), true)
    }

    @TestCase
    public func testReplaceAndSaveRoundTrip(): Unit {
        let orig = getVariable("CJH_CONFIG_DIR")
        let dir = testTempDir("mcp_cfg_rt")
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        setVariable("CJH_CONFIG_DIR", dir)
        try {
            // 预置一个未知字段：saveAll 是读-改-写，必须保留
            var root = JsonObject()
            root.put("_custom_keep", JsonString("keep-me"))
            File.writeTo(dir + "/settings.json", root.toJsonString().toArray())
            let c = CjhConfig()
            let raw = "[{\"name\":\"fs\",\"command\":\"npx\",\"args\":[\"-y\",\"s\"],\"env\":{\"K\":\"V\"}}," +
                "{\"name\":\"remote\",\"transport\":\"sse\",\"url\":\"http://127.0.0.1:9/sse\"}]"
            let (list, err) = parseMcpServersJson(JsonValue.fromStr(raw))
            @Assert(err, "")
            c.replaceMcpServers(list)
            c.saveAll()
            // 重新加载：内存与磁盘都被写通
            let c2 = CjhConfig()
            @Assert(c2.mcpServers.size, 2)
            @Assert(c2.mcpServers[0].name, "fs")
            @Assert(c2.mcpServers[0].command, "npx")
            @Assert(c2.mcpServers[0].args.size, 2)
            @Assert(c2.mcpServers[1].url, "http://127.0.0.1:9/sse")
            let text = readTextFile(c2.settingsPath)
            @Assert(text.contains("_custom_keep"), true)   // 未知字段保留
            @Assert(text.contains("\"K\": \"V\""), true)   // 落盘保留真实 env 值
        } finally {
            if (orig.isSome()) {
                setVariable("CJH_CONFIG_DIR", orig.getOrThrow())
            } else {
                removeVariable("CJH_CONFIG_DIR")
            }
            removeTree(dir)
        }
    }

    @TestCase
    public func testMaskedEnvWriteBackKeepsSecret(): Unit {
        // 磁盘上已有的真实配置
        let existingRaw = "[{\"name\":\"fs\",\"command\":\"npx\",\"env\":{\"TOKEN\":\"sk-real\",\"HOME\":\"/root\"}}]"
        let (existing, e1) = parseMcpServersJson(JsonValue.fromStr(existingRaw))
        @Assert(e1, "")
        // 客户端做的是 GET→改→回写：env 值全是脱敏占位
        let incomingRaw = "[{\"name\":\"fs\",\"command\":\"npx\",\"env\":{\"TOKEN\":\"***\",\"HOME\":\"***\"}}]"
        let (incoming, e2) = parseMcpServersJson(JsonValue.fromStr(incomingRaw))
        @Assert(e2, "")
        let merged = reconcileMaskedEnv(incoming, existing)
        @Assert(merged.size, 1)
        @Assert(merged[0].env.get("TOKEN").getOrThrow(), "sk-real")
        @Assert(merged[0].env.get("HOME").getOrThrow(), "/root")
        // 落盘后仍然是真值
        var probe = JsonObject()
        probe.put("servers", mcpServersToJsonObject(merged))
        let text = probe.toJsonString()
        @Assert(text.contains("sk-real"), true)
        @Assert(text.contains("***"), false)
    }

    @TestCase
    public func testMaskedEnvWithoutOriginalDropped(): Unit {
        // 全新服务器带 ***：没有原值可恢复 → 丢弃该键，绝不把 *** 当密钥落盘
        let (existing, _) = parseMcpServersJson(JsonValue.fromStr("[]"))
        let incomingRaw = "[{\"name\":\"fresh\",\"command\":\"x\",\"env\":{\"TOKEN\":\"***\",\"PLAIN\":\"v\"}}]"
        let (incoming, e) = parseMcpServersJson(JsonValue.fromStr(incomingRaw))
        @Assert(e, "")
        let merged = reconcileMaskedEnv(incoming, existing)
        @Assert(merged.size, 1)
        @Assert(merged[0].env.get("TOKEN").isNone(), true)
        @Assert(merged[0].env.get("PLAIN").getOrThrow(), "v")
        // 混合场景：同名服务器但新增了一个 *** 键（原配置里没有）同样丢弃
        let (old, _) = parseMcpServersJson(JsonValue.fromStr(
            "[{\"name\":\"fs\",\"command\":\"npx\",\"env\":{\"A\":\"1\"}}]"))
        let (mixed, _) = parseMcpServersJson(JsonValue.fromStr(
            "[{\"name\":\"fs\",\"command\":\"npx\",\"env\":{\"A\":\"***\",\"B\":\"***\"}}]"))
        let m2 = reconcileMaskedEnv(mixed, old)
        @Assert(m2[0].env.get("A").getOrThrow(), "1")
        @Assert(m2[0].env.get("B").isNone(), true)
    }
}
