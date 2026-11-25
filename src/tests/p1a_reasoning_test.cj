package cjh.tests

import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.net.*
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjutil.*

/**
 * P1a reasoning_effort / thinking budget 测试（CI 门禁内，根包 cjh.tests）
 *
 * 协议语义（实现见 libs/cjllm + libs/cjcfg）：
 *  - OpenAI 系：reasoning_effort 原样透传到请求体字段（off 也透传）；
 *    未配置（""）时请求体无该字段（字节级维持现状）
 *  - Anthropic：无 reasoning_effort 字段，映射为 extended thinking budget_tokens
 *    （""/off=不发 / low=1024 / medium=4096 / high=8192）；
 *    thinking 开启时 API 强制 temperature=1.0；
 *    budget >= max_tokens 时降级为 maxTokens/2，仍不满足 1024<=budget<max_tokens 则省略不发
 *  - Ollama：无此概念，setSampling 签名统一但静默忽略（不发字段）
 *  - CjhConfig：settings.json round-trip；合法值 off/low/medium/high 读回并原样落盘（含 off），
 *    未知值忽略（保持 ""，不报错）
 *
 * 请求体断言用 body-capturing mock server（照抄仓内已验证的 startMockServer 单次 accept 模式，
 * 处理完一条连接后 self-close，spawn 自然返回，不阻塞测试进程）：按 Content-Length 精确读
 * POST body 落盘 /tmp，主线程在 chatStream 返回后读取断言（spawn 先写盘再回 SSE，
 * 故 chatStream 返回时盘上必已有 body）。SSE 帧按各协议结束标记收尾（openai: finish_reason/[DONE]；
 * anthropic: message_stop），客户端据此提前结束流。
 * stdx JsonObject.toJsonString 为格式化输出（每字段一行，`"key": value` 冒号后一空格），
 * 断言统一用该子串格式；嵌套对象字段顺序不定（HashMap），不做整段精确匹配。
 * 端口用目录名哈希（20000+）分配，与仓内其他测试端口（18xxx）错开，避免复用冲突。
 */

// ==================== 辅助 ====================

func p1aChatMessages(): ArrayList<ChatMessage> {
    let m = ArrayList<ChatMessage>()
    m.add(ChatMessage("user", "hi"))
    return m
}

/** system + 一轮 tool_call/tool_result：验证缓存断点落在 system 与最后消息块 */
func p1aAnthropicCacheMessages(): ArrayList<ChatMessage> {
    let m = ArrayList<ChatMessage>()
    m.add(ChatMessage("system", "sys"))
    m.add(ChatMessage("user", "hi"))
    var args = JsonObject()
    args.put("path", JsonString("/tmp/x"))
    var calls = ArrayList<ToolCall>()
    calls.add(ToolCall("call_1", "read_file", args))
    m.add(ChatMessage("assistant", "", calls))
    m.add(ChatMessage("tool", "ok", "call_1", "read_file"))
    return m
}

func p1aAnthropicCacheTools(): ArrayList<ToolSpec> {
    let tools = ArrayList<ToolSpec>()
    tools.add(ToolSpec("read_file", "read", JsonObject()))
    return tools
}

/** 由目录名推导稳定端口（20000+；同一目录名跨用例不同后缀 → 不同端口，避免 TIME_WAIT 冲突） */
func p1aPortForDir(dir: String): UInt16 {
    var sum = 0
    for (ch in dir) {
        sum = sum + Int64(ch)
    }
    return UInt16(20000 + (sum % 30000))
}

/** 十六进制（chunked 长度行；独立实现，不依赖 cjllm 测试源的 toHex） */
func p1aHex(n: Int64): String {
    if (n == 0) {
        return "0"
    }
    let digits = "0123456789abcdef".toRuneArray()
    var v = n
    var chars = ArrayList<String>()
    while (v > 0) {
        chars.add(digits[v % 16].toString())
        v = v / 16
    }
    var sb = StringBuilder()
    var i = chars.size - 1
    while (i >= 0) {
        sb.append(chars[i])
        i -= 1
    }
    return sb.toString()
}

/** 轮询等待捕获文件落盘且含 expect（chatStream 返回后盘上必已有 body，此为兜底；返回 false=超时） */
func p1aWaitCapture(path: String, expect: String): Bool {
    let t0 = DateTime.now()
    while ((DateTime.now() - t0).toMilliseconds() < 8000) {
        if (exists(path)) {
            let content = safeFromUtf8(File.readFrom(path))
            if (content.contains(expect)) {
                return true
            }
        }
        sleep(Duration.millisecond * 20)
    }
    return false
}

/**
 * body-capturing mock server（单次 accept，照抄 startMockServer 模式）：
 *  1. accept 一条连接（provider 构造不触发 warmup，故只有 chatStream 这一条 POST）
 *  2. 读请求头 + 按 Content-Length 精确读 POST body → 落盘 capturePath
 *  3. 回固定 SSE（chunked，0 结尾 chunk），关连接
 * 返回 stop 闭包：幂等 close server（spawn 处理完会 self-close，此处仅为兜底清理）。
 */
func p1aStartBodyCaptureServer(port: UInt16, capturePath: String, sseBody: String): () -> Unit {
    let server = TcpServerSocket(bindAt: port)
    server.bind()
    spawn {
        let conn = server.accept()
        try {
            // 读请求头到 \r\n\r\n
            var reqHead = ""
            var buf = Array<Byte>(4096, repeat: 0)
            while (!reqHead.contains("\r\n\r\n")) {
                let r = conn.read(buf)
                if (r <= 0) {
                    break
                }
                reqHead += safeFromUtf8(buf[0..r])
            }
            // 解析 Content-Length
            var need = Int64(0)
            let lines = reqHead.split("\r\n", -1)
            for (l in lines) {
                if (l.toAsciiLower().startsWith("content-length:")) {
                    let cl = l[15..].trimAscii()
                    if (cl.size > 0) {
                        need = Int64.parse(cl)
                    }
                }
            }
            // 请求头可能已带出部分 body：先扣除
            let bodyStart = reqHead.lastIndexOf("\r\n\r\n")
            var headLen = Int64(0)
            if (bodyStart.isSome()) {
                headLen = Int64(bodyStart.getOrThrow() + 4)
            }
            var already = Int64(0)
            if (Int64(reqHead.size) > headLen) {
                already = Int64(reqHead.size) - headLen
            }
            var rest = Int64(0)
            if (need > already) {
                rest = need - already
            }
            var bodyBytes = Array<Byte>(0, repeat: 0)
            if (already > 0 && already <= need && bodyStart.isSome()) {
                bodyBytes = reqHead.toArray()[Int64(bodyStart.getOrThrow() + 4)..Int64(reqHead.size)]
            }
            while (rest > 0) {
                let r = conn.read(buf)
                if (r <= 0) {
                    break
                }
                var nb = Array<Byte>(bodyBytes.size + r, repeat: 0)
                for (i in 0..bodyBytes.size) {
                    nb[i] = bodyBytes[i]
                }
                for (i in 0..r) {
                    nb[bodyBytes.size + i] = buf[i]
                }
                bodyBytes = nb
                rest -= r
            }
            File.writeTo(capturePath, bodyBytes)
            conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())
            let b = sseBody.toArray()
            conn.write((p1aHex(Int64(b.size)) + "\r\n").toArray())
            conn.write(b)
            conn.write("\r\n".toArray())
            conn.write("0\r\n\r\n".toArray())
            sleep(Duration.millisecond * 100)
        } catch (e: Exception) {
            // 客户端提前关闭等异常忽略
        }
        try {
            conn.close()
            server.close()
        } catch (e: Exception) {
            // 忽略
        }
    }
    let stop = { =>
        try {
            server.close()
        } catch (e: Exception) {
        }
    }
    return stop
}

// ==================== OpenAI 系：reasoning_effort 透传 ====================

@Test
public class P1aOpenAiBodyTest {

    @TestCase
    public func testDefaultNoReasoningField(): Unit {
        // 未配置（setSampling 传 ""）：请求体不得出现 reasoning_effort（字节级维持现状）
        let dir = testTempDir("p1a_openai_default")
        let cap = dir + "/req.json"
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n" +
            "data: [DONE]\n\n"
        let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
        try {
            let port = p1aPortForDir(dir)
            let p = OpenAiProvider("http://127.0.0.1:${port}", "k", "m")
            p.setSampling(0.7, 16384, "")
            p.chatStream(p1aChatMessages(), ArrayList<ToolSpec>(),
                { _ => }, { _ => }, { _ => }, { => false })
            @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
            let body = readTextFile(cap)
            @Assert(body.contains("reasoning_effort"), false)
        } finally {
            stop()
            removeTree(dir)
        }
    }

    @TestCase
    public func testReasoningEffortPassThrough(): Unit {
        // 配置后原样透传（含 off）
        for (i in 0..2) {
            let effort = if (i == 0) { "medium" } else { "off" }
            let suffix = if (i == 0) { "a" } else { "b" }
            let dir = testTempDir("p1a_openai_pt" + suffix)
            let cap = dir + "/req.json"
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n" +
                "data: [DONE]\n\n"
            let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
            try {
                let port = p1aPortForDir(dir)
                let p = OpenAiProvider("http://127.0.0.1:${port}", "k", "m")
                p.setSampling(0.7, 16384, effort)
                p.chatStream(p1aChatMessages(), ArrayList<ToolSpec>(),
                    { _ => }, { _ => }, { _ => }, { => false })
                @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
                let body = readTextFile(cap)
                @Assert(body.contains("\"reasoning_effort\": \"${effort}\""), true)
            } finally {
                stop()
                removeTree(dir)
            }
        }
    }
}

// ==================== Anthropic：reasoning_effort → thinking budget ====================

@Test
public class P1aAnthropicBodyTest {

    @TestCase
    public func testBudgetMappingAndBody(): Unit {
        // low=1024 / medium=4096 / high=8192；off/""=不发 thinking；
        // 开启时强制 temperature=1.0，不发时保留配置 temperature
        for (i in 0..5) {
            let effort = if (i == 0) { "low" } else if (i == 1) { "medium" } else if (i == 2) { "high" } else if (i == 3) { "off" } else { "" }
            let budget = if (i == 0) { 1024 } else if (i == 1) { 4096 } else if (i == 2) { 8192 } else { 0 }
            let suffix = if (i == 0) { "low" } else if (i == 1) { "med" } else if (i == 2) { "high" } else if (i == 3) { "off" } else { "empty" }
            let dir = testTempDir("p1a_anth" + suffix)
            let cap = dir + "/req.json"
            let sse = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"text\":\"hi\"}}\n\n" +
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
            try {
                let port = p1aPortForDir(dir)
                let p = AnthropicProvider("http://127.0.0.1:${port}", "k", "m")
                p.setSampling(0.7, 16384, effort)
                @Assert(p.thinkingBudget, Int64(budget))
                p.chatStream(p1aChatMessages(), ArrayList<ToolSpec>(),
                    { _ => }, { _ => }, { _ => }, { => false })
                @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
                let body = readTextFile(cap)
                if (budget > 0) {
                    @Assert(body.contains("\"budget_tokens\": ${budget}"), true)
                    @Assert(body.contains("\"temperature\": 1"), true)  // API 强制 1.0
                } else {
                    @Assert(body.contains("thinking"), false)
                    @Assert(body.contains("\"temperature\": 0.7"), true)
                }
            } finally {
                stop()
                removeTree(dir)
            }
        }
    }

    @TestCase
    public func testPromptCacheBreakpoints(): Unit {
        // 启用缓存：system 转 block 数组并打断点（覆盖 tools+system），
        // 最后一条 tool_result 消息也打断点（下一轮工具循环复用整段历史）
        let dir = testTempDir("p1a_anth_cache")
        let cap = dir + "/req.json"
        let sse = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
        try {
            let port = p1aPortForDir(dir)
            let p = AnthropicProvider("http://127.0.0.1:${port}", "k", "m")
            p.chatStream(p1aAnthropicCacheMessages(), p1aAnthropicCacheTools(),
                { _ => }, { _ => }, { _ => }, { => false })
            @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
            let root = JsonValue.fromStr(readTextFile(cap)).asObject()
            let sys = root.get("system").getOrThrow()
            let sysIsArray = match (sys.kind()) {
                case JsonKind.JsArray => true
                case _ => false
            }
            @Assert(sysIsArray, true)
            let sysBlock = sys.asArray().get(0).getOrThrow().asObject()
            @Assert(sysBlock.containsKey("cache_control"), true)

            let msgs = root.get("messages").getOrThrow().asArray()
            let last = msgs.get(msgs.size() - 1).getOrThrow().asObject()
            let blocks = last.get("content").getOrThrow().asArray()
            let lastBlock = blocks.get(blocks.size() - 1).getOrThrow().asObject()
            @Assert(lastBlock.get("type").getOrThrow().asString().getValue(), "tool_result")
            @Assert(lastBlock.containsKey("cache_control"), true)
            @Assert(root.containsKey("tools"), true)
        } finally {
            stop()
            removeTree(dir)
        }
    }

    @TestCase
    public func testPromptCacheCoversToolsWithoutSystem(): Unit {
        // 无 system 时，断点必须落到最后一个 tool（否则 tools 前缀不进缓存）
        let dir = testTempDir("p1a_anth_cache_tools")
        let cap = dir + "/req.json"
        let sse = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
        try {
            let port = p1aPortForDir(dir)
            let p = AnthropicProvider("http://127.0.0.1:${port}", "k", "m")
            p.chatStream(p1aChatMessages(), p1aAnthropicCacheTools(),
                { _ => }, { _ => }, { _ => }, { => false })
            @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
            let root = JsonValue.fromStr(readTextFile(cap)).asObject()
            let tools = root.get("tools").getOrThrow().asArray()
            let lastTool = tools.get(tools.size() - 1).getOrThrow().asObject()
            @Assert(lastTool.containsKey("cache_control"), true)
        } finally {
            stop()
            removeTree(dir)
        }
    }

    @TestCase
    public func testPromptCacheCanBeDisabled(): Unit {
        // 兼容拒绝 cache_control 的第三方代理：关闭后请求体回到旧形状
        let dir = testTempDir("p1a_anth_cache_off")
        let cap = dir + "/req.json"
        let sse = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
        try {
            let port = p1aPortForDir(dir)
            let p = AnthropicProvider("http://127.0.0.1:${port}", "k", "m")
            p.setPromptCache(false)
            p.chatStream(p1aAnthropicCacheMessages(), p1aAnthropicCacheTools(),
                { _ => }, { _ => }, { _ => }, { => false })
            @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
            let body = readTextFile(cap)
            @Assert(body.contains("cache_control"), false)
            let root = JsonValue.fromStr(body).asObject()
            let sys = root.get("system").getOrThrow()
            let sysIsString = match (sys.kind()) {
                case JsonKind.JsString => true
                case _ => false
            }
            @Assert(sysIsString, true)
        } finally {
            stop()
            removeTree(dir)
        }
    }

    @TestCase
    public func testBudgetConstraintDegrade(): Unit {
        // 约束：budget >= max_tokens → 降级 maxTokens/2；仍不满足 1024<=budget<max_tokens → 省略
        let q0 = AnthropicProvider("http://127.0.0.1:1", "k", "m")
        q0.setSampling(0.7, 2000, "low")
        @Assert(q0.thinkingBudget, 1024)  // 1024 < 2000 且 >=1024 → 不降级
        let q1 = AnthropicProvider("http://127.0.0.1:1", "k", "m")
        q1.setSampling(0.7, 1000, "low")
        @Assert(q1.thinkingBudget, 0)  // 1024 >= 1000 → 降级 500；500 < 1024 → 省略
        let q2 = AnthropicProvider("http://127.0.0.1:1", "k", "m")
        q2.setSampling(0.7, 4096, "high")
        @Assert(q2.thinkingBudget, 2048)  // 8192 >= 4096 → 降级 2048；2048<4096 且 >=1024 → 2048
        let q3 = AnthropicProvider("http://127.0.0.1:1", "k", "m")
        q3.setSampling(0.7, 16384, "medium")
        @Assert(q3.thinkingBudget, 4096)  // 4096 < 16384 → 不降级
    }
}

// ==================== Ollama：静默忽略 ====================

@Test
public class P1aOllamaBodyTest {

    @TestCase
    public func testOllamaIgnoresReasoning(): Unit {
        // setSampling 签名统一但不发 reasoning_effort 字段
        let dir = testTempDir("p1a_ollama")
        let cap = dir + "/req.json"
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n" +
            "data: [DONE]\n\n"
        let stop = p1aStartBodyCaptureServer(p1aPortForDir(dir), cap, sse)
        try {
            let port = p1aPortForDir(dir)
            let p = OllamaProvider("http://127.0.0.1:${port}", "", "m")
            p.setSampling(0.7, 16384, "medium")
            p.chatStream(p1aChatMessages(), ArrayList<ToolSpec>(),
                { _ => }, { _ => }, { _ => }, { => false })
            @Assert(p1aWaitCapture(cap, "\"model\": \"m\""), true)
            let body = readTextFile(cap)
            @Assert(body.contains("reasoning_effort"), false)
            @Assert(body.contains("\"model\": \"m\""), true)
        } finally {
            stop()
            removeTree(dir)
        }
    }
}

// ==================== CjhConfig：settings.json round-trip ====================

@Test
public class P1aConfigTest {

    @TestCase
    public func testReasoningEffortRoundTrip(): Unit {
        // 独立配置目录（CJH_CONFIG_DIR 覆盖），finally 恢复原值
        let orig = getVariable("CJH_CONFIG_DIR")
        let dir = testTempDir("p1a_cfg_rt")
        setVariable("CJH_CONFIG_DIR", dir)
        try {
            let c = CjhConfig()
            c.reasoningEffort = "high"
            c.saveAll()
            let c2 = CjhConfig()
            @Assert(c2.reasoningEffort, "high")
            // 文件里确实有字段（格式化输出：`"reasoning_effort": "high"` 冒号后一空格）
            let raw = readTextFile(c2.settingsPath)
            @Assert(raw.contains("\"reasoning_effort\": \"high\""), true)
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
    public func testOffValueRoundTrips(): Unit {
        // off=合法值：读回 off，saveAll 原样落盘（size>0 即写）
        let orig = getVariable("CJH_CONFIG_DIR")
        let dir = testTempDir("p1a_cfg_off")
        setVariable("CJH_CONFIG_DIR", dir)
        try {
            let c = CjhConfig()
            c.reasoningEffort = "off"
            c.saveAll()
            let raw = readTextFile(c.settingsPath)
            @Assert(raw.contains("\"reasoning_effort\": \"off\""), true)
            let c2 = CjhConfig()
            @Assert(c2.reasoningEffort, "off")
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
    public func testUnknownValueIgnored(): Unit {
        // 未知值（"max"）忽略：保持 ""，不报错
        let orig = getVariable("CJH_CONFIG_DIR")
        let dir = testTempDir("p1a_cfg_unknown")
        setVariable("CJH_CONFIG_DIR", dir)
        try {
            var root = JsonObject()
            root.put("model", JsonString("m"))
            root.put("reasoning_effort", JsonString("max"))
            File.writeTo(dir + "/settings.json", root.toJsonString().toArray())
            let c = CjhConfig()
            @Assert(c.reasoningEffort, "")
        } finally {
            if (orig.isSome()) {
                setVariable("CJH_CONFIG_DIR", orig.getOrThrow())
            } else {
                removeVariable("CJH_CONFIG_DIR")
            }
            removeTree(dir)
        }
    }
}
