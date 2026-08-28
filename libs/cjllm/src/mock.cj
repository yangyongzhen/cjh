package cjllm

import std.collection.*
import stdx.encoding.json.*

/**
 * Mock LLM Provider：用于离线验证 agent 工具调用链（无 API Key 环境）
 *
 * 行为序列（按调用次数）：
 * 1. 第一次：返回工具调用 read_file → 验证工具执行
 * 2. 第二次：返回工具调用 bash → 验证命令执行
 * 3. 之后：返回最终文本答复
 */
public class MockProvider <: LlmProvider {
    private var callCount: Int64 = 0
    public let scriptedPath: String

    public init(scriptedPath: String) {
        this.scriptedPath = scriptedPath
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit): ModelResponse {
        this.callCount += 1
        match (this.callCount) {
            case 1 =>
                // 工具调用 1：并发 2 个 read-only 工具（V2d 并发执行引擎验证）
                var args1 = JsonObject()
                args1.put("path", JsonString(this.scriptedPath))
                var args1b = JsonObject()
                args1b.put("pattern", JsonString("line"))
                args1b.put("path", JsonString(this.scriptedPath))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_1a", "read_file", args1))
                calls.add(ToolCall("call_1b", "grep", args1b))
                return ModelResponse("我来先看看文件内容。", calls)
            case 2 =>
                // 工具调用 2：grep 搜索
                var args2 = JsonObject()
                args2.put("pattern", JsonString("line"))
                args2.put("path", JsonString(this.scriptedPath))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_2", "grep", args2))
                return ModelResponse("再用 grep 搜索。", calls)
            case 3 =>
                // 工具调用 3：列出目录
                var args3 = JsonObject()
                args3.put("path", JsonString("/tmp"))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_3", "list_dir", args3))
                return ModelResponse("再看看目录。", calls)
            case _ =>
                // 最终答复：分帧回调模拟流式
                let finalText = "FINAL-DONE: 验证完成，工具链正常"
                // 整体回调（避免逐字节/码点重建的 mojibake 风险）
                onDelta(finalText)
                return ModelResponse(finalText, ArrayList<ToolCall>())
        }
    }
}
