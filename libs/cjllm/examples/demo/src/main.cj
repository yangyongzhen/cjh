// cjllm 最小示例：MockProvider 流式对话（离线，无需 API Key）
package llm_demo

import cjllm.*
import std.collection.*

main(): Int64 {
    // Mock 离线验证（不联网）
    let provider = MockProvider("/tmp/cjh_mock_demo.txt")

    var msgs = ArrayList<ChatMessage>()
    msgs.add(ChatMessage("user", "用仓颉写冒泡排序"))

    var tools = ArrayList<ToolSpec>()
    let resp = provider.chatStream(msgs, tools,
        { text => print(text) },
        { r => () },
        { est => () },
        { => false })

    println("")
    println("工具调用数: ${resp.toolCalls.size}")
    println("回复内容: ${resp.text}")
    return 0
}
