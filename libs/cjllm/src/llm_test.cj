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
}

class AnthTestState {
    static var delta: String = ""
}
