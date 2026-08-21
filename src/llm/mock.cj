package cjh.llm

import std.collection.*
import stdx.encoding.json.*
import cjh.model.*

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
        onDelta: (String) -> Unit): ModelResponse {
        this.callCount += 1
        match (this.callCount) {
            case 1 =>
                // 工具调用 1：读文件
                var args1 = JsonObject()
                args1.put("path", JsonString(this.scriptedPath))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_1", "read_file", args1))
                return ModelResponse("我来先看看文件内容。", calls)
            case 2 =>
                // 工具调用 2：执行命令统计行数
                var args2 = JsonObject()
                args2.put("command", JsonString("wc -l ${this.scriptedPath}"))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_2", "bash", args2))
                return ModelResponse("再看一下文件行数。", calls)
            case _ =>
                // 最终答复
                return ModelResponse("验证完成：工具调用链工作正常。文件已读取，行数已统计。", ArrayList<ToolCall>())
        }
    }
}
