package cjllm

import std.collection.*
import stdx.encoding.json.*

/**
 * 会话历史修复单元测试（孤儿 tool 消息 / 悬空 tool_calls）
 *
 * 回归背景（AtomGit issue #5 第 1 条）：回合被打断后历史留下没有 tool_calls 声明的
 * tool 消息，此后每次请求都把脏历史重放给上游，上游永久回 400，会话报废。
 */
@Test
public class HistoryRepairTest {
    // 构造一条 assistant 消息（带 n 个 tool_calls，id = call_1..call_n）
    private func assistantWithCalls(text: String, n: Int64): ChatMessage {
        let calls = ArrayList<ToolCall>()
        for (i in 1..=n) {
            calls.add(ToolCall("call_${i}", "read_file", JsonObject()))
        }
        return ChatMessage("assistant", text, calls)
    }

    private func toolResult(id: String): ChatMessage {
        return ChatMessage("tool", "ok", id, "read_file")
    }

    @TestCase
    public func testHealthyHistoryUnchanged(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.assistantWithCalls("", 1))
        msgs.add(this.toolResult("call_1"))
        msgs.add(ChatMessage("assistant", "done"))
        let r = repairHistory(msgs)
        @Assert(r.fixes, 0)
        @Assert(r.messages.size, 4)
        @Assert(historyCorrupted(msgs), false)
    }

    @TestCase
    public func testOrphanToolMessageDropped(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.toolResult("call_9"))          // 孤儿：前面没有声明
        msgs.add(ChatMessage("assistant", "done"))
        let r = repairHistory(msgs)
        @Assert(r.fixes, 1)
        @Assert(r.messages.size, 2)
        var hasTool = false
        for (m in r.messages) {
            if (m.role == "tool") { hasTool = true }
        }
        @Assert(hasTool, false)
        @Assert(historyCorrupted(msgs), true)
        @Assert(historyDefectCount(msgs), 1)
    }

    @TestCase
    public func testDanglingToolCallTrimmed(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.assistantWithCalls("", 2))     // call_1 有结果，call_2 没有
        msgs.add(this.toolResult("call_1"))
        msgs.add(ChatMessage("user", "继续"))
        let r = repairHistory(msgs)
        @Assert(r.fixes, 1)
        @Assert(r.messages.size, 4)
        // assistant 只剩 call_1
        @Assert(r.messages[1].toolCalls.size, 1)
        @Assert(r.messages[1].toolCalls[0].id, "call_1")
        @Assert(r.messages[2].role, "tool")
    }

    @TestCase
    public func testEmptyAssistantWithDanglingCallsDropped(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.assistantWithCalls("", 1))     // 无文本、无结果 → 空壳
        msgs.add(ChatMessage("user", "继续"))
        let r = repairHistory(msgs)
        // 1 处悬空 tool_call + 1 处整条丢弃
        @Assert(r.fixes, 2)
        @Assert(r.messages.size, 2)
        @Assert(r.messages[1].role, "user")
    }

    @TestCase
    public func testAssistantTextKeptWhenCallsDangling(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.assistantWithCalls("我看看文件", 1))
        msgs.add(ChatMessage("user", "继续"))
        let r = repairHistory(msgs)
        @Assert(r.messages.size, 3)
        @Assert(r.messages[1].content, "我看看文件")
        @Assert(r.messages[1].toolCalls.size, 0)
    }

    @TestCase
    public func testDuplicateToolResultDeduped(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.assistantWithCalls("", 1))
        msgs.add(this.toolResult("call_1"))
        msgs.add(this.toolResult("call_1"))          // 重复结果
        let r = repairHistory(msgs)
        @Assert(r.fixes, 1)
        @Assert(r.messages.size, 3)
    }

    @TestCase
    public func testRepairIsIdempotent(): Unit {
        let msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "hi"))
        msgs.add(this.toolResult("call_9"))
        msgs.add(this.assistantWithCalls("", 1))
        msgs.add(ChatMessage("user", "继续"))
        let once = repairHistory(msgs)
        let twice = repairHistory(once.messages)
        @Assert(twice.fixes, 0)
        @Assert(twice.messages.size, once.messages.size)
        // sanitizeHistory 与 repairHistory 结果一致
        @Assert(sanitizeHistory(msgs).size, once.messages.size)
    }
}
