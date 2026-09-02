package cjh.agent

import std.collection.*
import cjllm.*
import cjh.tools.*
import cjcfg.*
import cjutil.*

/**
 * summarizeForMemory 回归测试（2026-09-01 僵尸忙态事故）
 *
 * 事故：compaction 注入的首条 user 消息是 673 字节中文 [历史摘要]，
 * summarizeForMemory 内裸字节切片 task[0..60] 的切点（第 60 字节）落在
 * CJK 字符中间（0x8B），抛 IllegalArgumentException: Invalid utf8 byte sequence。
 * 该调用位于 TUI spawn 收尾路径（entries.cj）try/catch 之外，spawn 未捕获异常
 * 只杀收尾线程、进程存活 → setAgentRunning(false) 永不执行 → TUI 永久卡在
 * 忙 "Streaming…" 态、看门狗重复无效中断、排队消息永不发送。
 *
 * 仓颉 String[a..b] 按字节切片且校验 UTF-8 边界：切点落在多字节字符中间即抛。
 * 修复改用 cjutil.truncateUtf8（回退到合法字符边界，不抛）。
 *
 * 本测试用事故真实数据（byte60=0x8B）钉死回归：修复前 testIncidentFullHistory
 * 会抛异常而红；修复后必须全绿。testSlicePremise 自证前提——若仓颉切片语义
 * 变化不再抛异常，前提失效需重新评估本测试。
 */

// summarizeForMemory 不调用 provider；stub 仅满足 Agent 构造接口
class MemoryStubProvider <: LlmProvider {
    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        return ModelResponse("", ArrayList<ToolCall>())
    }
}

@Test
public class SummarizeMemoryTest {

    // 事故真实数据：compaction 后首条 user 消息前缀（250 字节 / 114 字符）。
    // byte60 = 0x8B（CJK 连续字节）→ 旧代码 task[0..60] 必抛异常。
    private func incidentTask(): String {
        return "[历史摘要] 【对话摘要】用户以“cjh 编码助手”身份发起对话。已完成任务：查看当前目录，共 4 项——`cjh` 与 `main`（均为 11MB 仓颉 ELF 可执行文件，内容一致，分别是 cjh 主程序和 cjpm 的 "
    }

    // 构造的长中文回复（211 字节 = "A" + 70×"星"，3 字节/字）。
    // byte200 = 0x98（CJK 连续字节）→ 旧代码 reply[0..200] 必抛异常。
    private func incidentReply(): String {
        return "A星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星星"
    }

    private func buildAgent(): Agent {
        let registry = ToolRegistry()
        let config = AgentConfig("test system", 5, Capability(), 0, 0, 2, 6000, "", "mem-test")
        return Agent(MemoryStubProvider(), registry, config)
    }

    @TestCase
    public func testSlicePremise(): Unit {
        // 前提自证：事故串第 60 字节在多字节字符中间，裸切片抛异常
        var threw = false
        try {
            let _ = this.incidentTask()[0..60]
        } catch (e: Exception) {
            threw = true
        }
        @Assert(threw, true)
        // 对照：合法边界（第 58 字节是 ASCII '的' 前字符起始）不抛
        var ok = true
        try {
            let _ = this.incidentTask()[0..58]
        } catch (e: Exception) {
            ok = false
        }
        @Assert(ok, true)
    }

    @TestCase
    public func testIncidentFullHistory(): Unit {
        // 事故完整路径：user（250B 中文摘要）+ tool（含路径+CJK）+ assistant（211B 中文回复）
        let agent = this.buildAgent()
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", this.incidentTask()))
        history.add(ChatMessage("tool",
            "已写入 /root/test/cj/cjh/src/agent/loop.cj 成功，中文说明跟随",
            "", "read_file"))
        history.add(ChatMessage("assistant", this.incidentReply()))
        agent.loadHistory(history)

        // 回归核心：修复前此处抛 IllegalArgumentException 杀死收尾线程（僵尸忙态）；
        // 修复后 truncateUtf8 回退合法边界，不得抛异常
        let s = agent.summarizeForMemory()

        // task 行：精确等于 truncateUtf8 语义（回退到 ≤60 字节的字符边界 + 省略号）
        let expectedTask = "- 最后任务: " + truncateUtf8(this.incidentTask(), 60) + "…"
        @Assert(s.contains(expectedTask), true)
        // 截断结果不得超 60 字节，且必须是原串前缀
        let t = truncateUtf8(this.incidentTask(), 60)
        @Assert(t.size <= 60, true)
        @Assert(this.incidentTask().startsWith(t), true)
        // reply 行：byte200 在 CJK 中间 → 同样必须安全截断
        let expectedReply = "- 结果: " + truncateUtf8(this.incidentReply(), 200) + "…"
        @Assert(s.contains(expectedReply), true)
        // 工具计数正常
        @Assert(s.contains("- 工具调用: 1 次"), true)
    }

    @TestCase
    public func testAsciiShortNoTruncation(): Unit {
        // 短 ASCII：不触发截断、无省略号（防 truncateUtf8 误伤正常路径）
        let agent = this.buildAgent()
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", "check the directory"))
        history.add(ChatMessage("assistant", "done"))
        agent.loadHistory(history)
        let s = agent.summarizeForMemory()
        @Assert(s.contains("- 最后任务: check the directory\n"), true)
        @Assert(s.contains("- 结果: done\n"), true)
        @Assert(s.contains("…"), false)
    }
}
