package cjllm

import std.collection.*

/**
 * 会话历史修复（OpenAI 兼容协议约束）
 *
 * 上游对 tool 消息有严格配对要求：每条 role="tool" 必须是对**紧邻前文** assistant
 * 消息里 tool_calls 之一的结果；assistant 声明了 tool_calls 也必须跟齐结果。
 * 回合被打断（客户端断开 / 进程被杀 / 工具执行中崩溃）时历史会残缺，此后每次请求
 * 都把整段脏历史重放给上游，于是该会话永久 400：
 *   "Messages with role 'tool' must be a response to a preceding message with 'tool_calls'"
 *
 * 本模块在**发送上游前**做一次幂等修复，把残缺历史整形成上游可接受的形式：
 *   - 丢弃孤儿 tool 消息（前面没有声明对应 tool_call_id）
 *   - 修剪 assistant 里没有结果的 tool_calls（悬空声明）
 *   - 丢弃既无文本又无有效 tool_calls 的空 assistant
 *   - 丢弃同一 tool_call_id 的重复结果
 * 修复是有损的（丢掉的内容无法复原），但保住整个会话可用——优于永久 400。
 */

/**
 * 修复结果：修复后的消息列表 + 修复动作数（0 = 历史本来就合法）
 */
public class HistoryRepair {
    public let messages: ArrayList<ChatMessage>
    public let fixes: Int64

    public init(messages: ArrayList<ChatMessage>, fixes: Int64) {
        this.messages = messages
        this.fixes = fixes
    }
}

/**
 * 修复会话历史，返回修复后的列表与修复动作数。
 *
 * 幂等：对已合法的历史调用返回内容相同、fixes==0 的列表。
 */
public func repairHistory(messages: ArrayList<ChatMessage>): HistoryRepair {
    let out = ArrayList<ChatMessage>()
    var fixes: Int64 = 0
    var i: Int64 = 0
    while (i < messages.size) {
        let m = messages[i]
        // 情况一：assistant 携带 tool_calls → 检查紧随其后的 tool 结果是否齐全
        if (m.role == "assistant" && m.toolCalls.size > 0) {
            let declared = ArrayList<String>()
            for (tc in m.toolCalls) {
                declared.add(tc.id)
            }
            let answered = ArrayList<String>()
            let results = ArrayList<ChatMessage>()
            var j = i + 1
            while (j < messages.size && messages[j].role == "tool") {
                let r = messages[j]
                if (indexOfString(declared, r.toolCallId) >= 0) {
                    if (indexOfString(answered, r.toolCallId) >= 0) {
                        fixes += 1  // 重复结果：丢弃后一条
                    } else {
                        answered.add(r.toolCallId)
                        results.add(r)
                    }
                } else {
                    fixes += 1  // 结果引用了未声明的 tool_call_id：丢弃
                }
                j += 1
            }
            // 只保留真的拿到结果的 tool_calls
            let keptCalls = ArrayList<ToolCall>()
            for (tc in m.toolCalls) {
                if (indexOfString(answered, tc.id) >= 0) {
                    keptCalls.add(tc)
                } else {
                    fixes += 1
                }
            }
            if (keptCalls.size > 0) {
                out.add(ChatMessage("assistant", m.content, keptCalls))
                for (r in results) {
                    out.add(r)
                }
            } else if (m.content.size > 0) {
                // 文本还有价值：留下无 tool_calls 的 assistant
                out.add(ChatMessage("assistant", m.content))
            } else {
                fixes += 1  // 空壳 assistant：整条丢弃
            }
            i = j
            continue
        }
        // 情况二：tool 消息前面没有 assistant 的 tool_calls 声明 → 孤儿
        if (m.role == "tool") {
            fixes += 1
            i += 1
            continue
        }
        out.add(m)
        i += 1
    }
    return HistoryRepair(out, fixes)
}

/**
 * 修复后的消息列表（发送上游前的入口）
 */
public func sanitizeHistory(messages: ArrayList<ChatMessage>): ArrayList<ChatMessage> {
    return repairHistory(messages).messages
}

/**
 * 历史残缺程度：需要修复的动作数（0 = 健康）。
 *
 * 供 /api/sessions 的 corrupted 健康标记与"会话可否安全恢复"预判使用。
 */
public func historyDefectCount(messages: ArrayList<ChatMessage>): Int64 {
    return repairHistory(messages).fixes
}

/**
 * 历史是否残缺（孤儿 tool 消息 / 悬空 tool_calls）
 */
public func historyCorrupted(messages: ArrayList<ChatMessage>): Bool {
    return repairHistory(messages).fixes > 0
}

private func indexOfString(list: ArrayList<String>, target: String): Int64 {
    for (i in 0..list.size) {
        if (list[i] == target) {
            return i
        }
    }
    return -1
}
