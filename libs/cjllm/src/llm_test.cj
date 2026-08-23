package cjllm

import std.collection.*
import stdx.encoding.json.*

/**
 * StreamAccumulator 单元测试（OpenAI 流式累加）
 * 测试数据用 JsonObject 运行时构造，避免字符串转义地狱
 */
@Test
public class StreamAccumulatorTest {
    @TestCase
    public func testTextAccumulation(): Unit {
        let acc = StreamAccumulator()
        acc.feed(this.choiceJson("你好"))
        acc.feed(this.choiceJson("世界"))
        let resp = acc.finish()
        @Assert(resp.text, "你好世界")
    }

    @TestCase
    public func testTakeDeltaIncremental(): Unit {
        let acc = StreamAccumulator()
        acc.feed(this.choiceJson("abc"))
        @Assert(acc.takeDelta(), "abc")
        @Assert(acc.takeDelta(), "")
        acc.feed(this.choiceJson("def"))
        @Assert(acc.takeDelta(), "def")
    }

    @TestCase
    public func testToolCallComplete(): Unit {
        let acc = StreamAccumulator()
        // 完整工具调用（arguments 为 JSON 字符串）
        var argsJson = JsonObject()
        argsJson.put("path", JsonString("/tmp/x.txt"))
        var fn = JsonObject()
        fn.put("name", JsonString("read_file"))
        fn.put("arguments", JsonString(argsJson.toJsonString()))
        var tc = JsonObject()
        tc.put("id", JsonString("call_1"))
        tc.put("function", fn)
        var arr = ArrayList<JsonValue>()
        arr.add(tc)
        var root = JsonObject()
        root.put("tool_calls", JsonArray(arr))
        acc.feed(root.toJsonString())
        let resp = acc.finish()
        @Assert(resp.toolCalls.size, 1)
        @Assert(resp.toolCalls[0].name, "read_file")
        @Assert(resp.toolCalls[0].arguments.containsKey("path"), true)
    }

    @TestCase
    public func testToolCallParallel(): Unit {
        // 并行工具调用（index 0/1）：两个 bash 调用，参数必须分别解析，
        // 不能被拼成一个非法 JSON（旧实现 bug → _raw 透传 → "缺少参数"）
        let acc = StreamAccumulator()

        // index 0: bash g++ --version
        var args0 = JsonObject()
        args0.put("command", JsonString("g++ --version"))
        var fn0 = JsonObject()
        fn0.put("name", JsonString("bash"))
        fn0.put("arguments", JsonString(args0.toJsonString()))
        var tc0 = JsonObject()
        tc0.put("index", JsonInt(0))
        tc0.put("id", JsonString("call_a"))
        tc0.put("function", fn0)
        var arr0 = ArrayList<JsonValue>()
        arr0.add(tc0)
        var root0 = JsonObject()
        root0.put("tool_calls", JsonArray(arr0))
        acc.feed(root0.toJsonString())

        // index 1: bash gcc --version
        var args1 = JsonObject()
        args1.put("command", JsonString("gcc --version"))
        var fn1 = JsonObject()
        fn1.put("name", JsonString("bash"))
        fn1.put("arguments", JsonString(args1.toJsonString()))
        var tc1 = JsonObject()
        tc1.put("index", JsonInt(1))
        tc1.put("id", JsonString("call_b"))
        tc1.put("function", fn1)
        var arr1 = ArrayList<JsonValue>()
        arr1.add(tc1)
        var root1 = JsonObject()
        root1.put("tool_calls", JsonArray(arr1))
        acc.feed(root1.toJsonString())

        let resp = acc.finish()
        @Assert(resp.toolCalls.size, 2)
        // index 0 调用参数完整可解析
        @Assert(resp.toolCalls[0].name, "bash")
        @Assert(resp.toolCalls[0].arguments.containsKey("command"), true)
        @Assert(resp.toolCalls[0].arguments.containsKey("_raw"), false)
        // index 1 调用参数完整可解析
        @Assert(resp.toolCalls[1].name, "bash")
        @Assert(resp.toolCalls[1].arguments.containsKey("command"), true)
        @Assert(resp.toolCalls[1].arguments.containsKey("_raw"), false)
    }

    /**
     * 构造 {"choices":[{"delta":{"content":X}}]}
     */
    private func choiceJson(content: String): String {
        var delta = JsonObject()
        delta.put("content", JsonString(content))
        var choice = JsonObject()
        choice.put("delta", delta)
        var arr = ArrayList<JsonValue>()
        arr.add(choice)
        var root = JsonObject()
        root.put("choices", JsonArray(arr))
        return root.toJsonString()
    }
}

/**
 * AnthropicAccumulator 单元测试
 */
@Test
public class AnthropicAccumulatorTest {
    @TestCase
    public func testTextAndToolUse(): Unit {
        let acc = AnthropicAccumulator()
        AnthTestState.delta = ""

        // text_delta
        var delta = JsonObject()
        delta.put("type", JsonString("text_delta"))
        delta.put("text", JsonString("处理中"))
        var ev1 = JsonObject()
        ev1.put("type", JsonString("content_block_delta"))
        ev1.put("delta", delta)
        acc.feed(ev1.toJsonString(), { d => AnthTestState.delta += d })

        // tool_use start
        var block = JsonObject()
        block.put("type", JsonString("tool_use"))
        block.put("id", JsonString("tu1"))
        block.put("name", JsonString("grep"))
        block.put("input", JsonObject())
        var ev2 = JsonObject()
        ev2.put("type", JsonString("content_block_start"))
        ev2.put("content_block", block)
        acc.feed(ev2.toJsonString(), { d => AnthTestState.delta += d })

        // input_json_delta
        var partial = JsonObject()
        partial.put("pattern", JsonString("x"))
        var d2 = JsonObject()
        d2.put("type", JsonString("input_json_delta"))
        d2.put("partial_json", JsonString(partial.toJsonString()))
        var ev3 = JsonObject()
        ev3.put("type", JsonString("content_block_delta"))
        ev3.put("delta", d2)
        acc.feed(ev3.toJsonString(), { d => AnthTestState.delta += d })

        let resp = acc.finish()
        @Assert(resp.text, "处理中")
        @Assert(resp.toolCalls.size, 1)
        @Assert(resp.toolCalls[0].name, "grep")
        @Assert(resp.toolCalls[0].arguments.containsKey("pattern"), true)
        @Assert(AnthTestState.delta, "处理中")
    }

    @TestCase
    public func testParallelToolUse(): Unit {
        // 并行 tool_use（content_block index 0/1）：参数必须分别累积解析，
        // 不能被拼成一个非法 JSON（旧实现单一 curToolArgs 的同样 bug）
        let acc = AnthropicAccumulator()
        AnthTestState.delta = ""

        // index 0: tool_use grep
        var block0 = JsonObject()
        block0.put("type", JsonString("tool_use"))
        block0.put("id", JsonString("tu_a"))
        block0.put("name", JsonString("grep"))
        var ev0 = JsonObject()
        ev0.put("type", JsonString("content_block_start"))
        ev0.put("index", JsonInt(0))
        ev0.put("content_block", block0)
        acc.feed(ev0.toJsonString(), { d => AnthTestState.delta += d })
        var partial0 = JsonObject()
        partial0.put("pattern", JsonString("x"))
        var d0 = JsonObject()
        d0.put("type", JsonString("input_json_delta"))
        d0.put("partial_json", JsonString(partial0.toJsonString()))
        var e0 = JsonObject()
        e0.put("type", JsonString("content_block_delta"))
        e0.put("index", JsonInt(0))
        e0.put("delta", d0)
        acc.feed(e0.toJsonString(), { d => AnthTestState.delta += d })

        // index 1: tool_use read_file
        var block1 = JsonObject()
        block1.put("type", JsonString("tool_use"))
        block1.put("id", JsonString("tu_b"))
        block1.put("name", JsonString("read_file"))
        var ev1 = JsonObject()
        ev1.put("type", JsonString("content_block_start"))
        ev1.put("index", JsonInt(1))
        ev1.put("content_block", block1)
        acc.feed(ev1.toJsonString(), { d => AnthTestState.delta += d })
        var partial1 = JsonObject()
        partial1.put("path", JsonString("/tmp/x.txt"))
        var d1 = JsonObject()
        d1.put("type", JsonString("input_json_delta"))
        d1.put("partial_json", JsonString(partial1.toJsonString()))
        var e1 = JsonObject()
        e1.put("type", JsonString("content_block_delta"))
        e1.put("index", JsonInt(1))
        e1.put("delta", d1)
        acc.feed(e1.toJsonString(), { d => AnthTestState.delta += d })

        let resp = acc.finish()
        @Assert(resp.toolCalls.size, 2)
        @Assert(resp.toolCalls[0].name, "grep")
        @Assert(resp.toolCalls[0].arguments.containsKey("pattern"), true)
        @Assert(resp.toolCalls[0].arguments.containsKey("_raw"), false)
        @Assert(resp.toolCalls[1].name, "read_file")
        @Assert(resp.toolCalls[1].arguments.containsKey("path"), true)
        @Assert(resp.toolCalls[1].arguments.containsKey("_raw"), false)
    }
}

class AnthTestState {
    static var delta: String = ""
}

/**
 * MojibakeFix 回归测试：DeepSeek 返回的 Latin-1 误解码乱码应还原为中文
 */
@Test
public class MojibakeFixTest {
    /**
     * 构造 "你好" 的乱码形态：UTF-8 字节 E4 BD A0 E5 A5 BD 按 Latin-1
     * 解释为 ä ½ NBSP å ¥ ½，再以 UTF-8 编码（C3 A4 C2 BD C2 A0 C3 A5 C2 A5 C2 BD）
     */
    private func mojibakeOf(s: String): String {
        // 先取原串的 UTF-8 字节
        let runes = s.toRuneArray()
        var need = 0
        for (cp in runes) {
            let v = UInt32(cp)
            if (v < 0x80) {
                need += 1
            } else if (v < 0x800) {
                need += 2
            } else {
                need += 3
            }
        }
        var ob = Array<UInt8>(need, repeat: 0)
        var oi = 0
        for (cp in runes) {
            let v = UInt32(cp)
            if (v < 0x80) {
                ob[oi] = UInt8(v)
                oi += 1
            } else if (v < 0x800) {
                ob[oi] = UInt8(0xC0 | (v >> 6))
                ob[oi + 1] = UInt8(0x80 | (v & 0x3F))
                oi += 2
            } else {
                ob[oi] = UInt8(0xE0 | (v >> 12))
                ob[oi + 1] = UInt8(0x80 | ((v >> 6) & 0x3F))
                ob[oi + 2] = UInt8(0x80 | (v & 0x3F))
                oi += 3
            }
        }
        // 每个字节按 Latin-1 码点重编码为 UTF-8（乱码形态）
        var mbNeed = 0
        for (b in ob) {
            if (UInt32(b) < 0x80) {
                mbNeed += 1
            } else {
                mbNeed += 2
            }
        }
        var mb = Array<UInt8>(mbNeed, repeat: 0)
        var mi = 0
        for (b in ob) {
            let v = UInt32(b)
            if (v < 0x80) {
                mb[mi] = b
                mi += 1
            } else {
                mb[mi] = UInt8(0xC0 | (v >> 6))
                mb[mi + 1] = UInt8(0x80 | (v & 0x3F))
                mi += 2
            }
        }
        return String.fromUtf8(mb)
    }

    @TestCase
    public func testFixChineseMojibake(): Unit {
        let garbled = this.mojibakeOf("你好")
        @Assert(MojibakeFix.fix(garbled), "你好")
    }

    @TestCase
    public func testFixStreamingChunk(): Unit {
        // 模拟流式分片：乱码串被切在中间字节处
        let garbled = this.mojibakeOf("你好世界")
        let half = garbled.size / 2
        // 找合法字符边界，避免测试自身切坏 UTF-8
        var cut = half
        var first = ""
        while (cut > 0) {
            try {
                first = garbled[0..cut]
                break
            } catch (e: Exception) {
                cut -= 1
            }
        }
        let second = garbled[cut..garbled.size]
        let acc = StreamAccumulator()
        acc.feed(this.choiceJson(first))
        acc.feed(this.choiceJson(second))
        let resp = acc.finish()
        @Assert(resp.text, "你好世界")
    }

    @TestCase
    public func testFixPerCharChunks(): Unit {
        // 最碎分片：每个码点单独一个 chunk（真实流式可在任意位置切分，
        // 逐 chunk 修复必然失败——修复必须在 finish 时对完整串整体做）
        let garbled = this.mojibakeOf("你好世界")
        let runes = garbled.toRuneArray()
        let acc = StreamAccumulator()
        for (r in runes) {
            acc.feed(this.choiceJson(r.toString()))
        }
        let resp = acc.finish()
        @Assert(resp.text, "你好世界")
        // 流式期间 takeDelta 增量不破坏累积
        @Assert(acc.text.size > 0, true)
    }

    @TestCase
    public func testFixMixedText(): Unit {
        // 正常中文与乱码混合（如"好的，"前缀 + 乱码正文）：整体修复失败时
        // 不得破坏已正常的部分——原样返回（安全兜底）
        let garbled = this.mojibakeOf("你好")
        let mixed = "好的，" + garbled
        let fixed = MojibakeFix.fix(mixed)
        // 要么整体修复成功（含"你好"），要么原样返回（不含损坏的控制字符）
        @Assert(fixed == "好的，你好" || fixed == mixed, true)
    }

    @TestCase
    public func testKeepNormalText(): Unit {
        // 正常中文不应被误改
        @Assert(MojibakeFix.fix("你好世界"), "你好世界")
        // 纯 ASCII 不动
        @Assert(MojibakeFix.fix("hello world"), "hello world")
    }

    /**
     * 构造 {"choices":[{"delta":{"content":X}}]}
     */
    private func choiceJson(content: String): String {
        var delta = JsonObject()
        delta.put("content", JsonString(content))
        var choice = JsonObject()
        choice.put("delta", delta)
        var arr = ArrayList<JsonValue>()
        arr.add(choice)
        var root = JsonObject()
        root.put("choices", JsonArray(arr))
        return root.toJsonString()
    }
}
