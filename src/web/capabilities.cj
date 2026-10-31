package cjh.web

import std.collection.*
import stdx.encoding.json.*
import cjterm.*

/**
 * 服务端能力自述（GET /api/capabilities）
 *
 * 为什么要有：客户端想知道"这台服务端支持什么"，否则只能靠试错——发一个帧、
 * 等超时、猜是不是不支持，于是客户端里长出一堆 try/catch 与兜底分支。
 * 把能力做成数据，客户端开场问一次，之后按清单决定怎么说话。
 *
 * 不虚报原则（本文件的存在意义）：
 *   - ws_in 的每一项都必须能被 parseMsgType 认出来（单测断言）
 *   - ws_out 的每一项都必须真能构造出同 type 的帧（单测断言）
 *   - features 里能从清单推导的一律推导（如 approval_over_ws），不留手写开关
 *   - 做不到的能力报 false，而不是报"即将支持"：如 finish_reason 不含 length
 *     （provider 层的 max_tokens 截断尚未透传到 agent，报它只会让客户端
 *      写出永远不命中的分支）
 */

/**
 * WS 协议版本
 *
 * v1：回合级帧无身份（客户端只能按到达顺序猜归属）
 * v2：回合级帧带 session_id/turn_id/message_id；done 带 finish_reason
 * v3：新增 approval_request / approval_response（危险操作经 WS 人工确认）
 * v4：tool_result 增可选 diff 字段（文件改动的结构化 diff：path / unified_diff /
 *     before_sha / after_sha，客户端据此渲染 diff 视图）
 * v5：tool_start / tool_result 增可选 agent_id / agent_label（子代理身份；
 *     缺省不序列化 = 父回合，字段不虚报）
 *     （每次帧形状或帧集合变化都递增，客户端按版本决定要不要读新字段）
 */
public func capabilityProtocolVersion(): Int64 {
    return 5
}

/**
 * 入站帧名（浏览器 → 服务端）：与 ws_handler.handleWsMessage 的分发分支一一对应
 */
public func inboundFrameNames(): ArrayList<String> {
    let names = ArrayList<String>()
    names.add("chat")            // 发消息（可带 model/base_url/api_key 做单回合覆盖）
    names.add("cancel")          // 取消当前回合（回 cancelled）
    names.add("abort")           // 取消当前回合（与 cancel 同义）
    names.add("switch_model")    // 会话级切模型（回 ack）
    names.add("compact")         // 压缩历史（回 ack）
    names.add("approval_response") // 审批结果（同意/拒绝危险操作）
    names.add("new_session")     // 新建会话
    names.add("resume_session")  // 恢复历史会话（回 history_messages）
    return names
}

/**
 * 出站事件名（服务端 → 浏览器）：与 web_channel 实际发送的帧类型一一对应
 */
public func outboundEventNames(): ArrayList<String> {
    let names = ArrayList<String>()
    names.add("delta")
    names.add("tool_start")
    names.add("tool_result")
    names.add("done")
    names.add("error")
    names.add("ack")
    names.add("cancelled")
    names.add("approval_request")  // 危险操作需人工确认（回合阻塞等 approval_response）
    names.add("tasks")
    names.add("history_messages")
    return names
}

/**
 * HTTP 端点（"方法 路径"）：与 RestApi.handle 的路由分支一一对应
 */
public func httpEndpointNames(): ArrayList<String> {
    let names = ArrayList<String>()
    names.add("GET /api/health")
    names.add("GET /api/capabilities")
    names.add("GET /api/sessions")
    names.add("GET /api/sessions/{id}")
    names.add("PATCH /api/sessions/{id}")
    names.add("DELETE /api/sessions/{id}")
    names.add("GET /api/models")
    names.add("GET /api/tasks")
    names.add("GET /api/skills")
    names.add("GET /api/mcp")
    names.add("GET /api/settings")
    names.add("POST /api/settings")
    names.add("GET /api/workspaces")
    names.add("POST /api/workspaces/switch")
    names.add("GET /api/fs/list")
    return names
}

/**
 * 名字是否在清单里（不依赖集合类型的额外能力，纯手写更稳）
 */
func listHas(list: ArrayList<String>, name: String): Bool {
    for (i in 0..list.size) {
        if (list[i] == name) {
            return true
        }
    }
    return false
}

/**
 * 构造能力文档（GET /api/capabilities 的响应体）
 */
public func capabilitiesJson(): JsonObject {
    let inbound = inboundFrameNames()
    let outbound = outboundEventNames()
    let endpoints = httpEndpointNames()

    var wsIn = JsonArray()
    for (i in 0..inbound.size) {
        wsIn.add(JsonString(inbound[i]))
    }
    var wsOut = JsonArray()
    for (i in 0..outbound.size) {
        wsOut.add(JsonString(outbound[i]))
    }
    var http = JsonArray()
    for (i in 0..endpoints.size) {
        http.add(JsonString(endpoints[i]))
    }

    // done.finish_reason 的取值域：只列真报得出的（不含 length，见文件头说明）
    var reasons = JsonArray()
    reasons.add(JsonString("stop"))
    reasons.add(JsonString("cancelled"))
    reasons.add(JsonString("error"))

    var features = JsonObject()
    // 能从帧清单推导的一律推导：清单变了，能力位自动跟着变，不会与实现漂移
    features.put("control_frame_acks",
        JsonBool(listHas(inbound, "switch_model") && listHas(inbound, "compact")))
    features.put("cancel_receipt", JsonBool(listHas(inbound, "cancel")))
    features.put("history_replay", JsonBool(listHas(inbound, "resume_session")))
    features.put("approval_over_ws", JsonBool(listHas(inbound, "approval_response")))
    features.put("turn_ids", JsonBool(true))            // v2 起：回合级帧带三件套身份
    features.put("finish_reasons", reasons)
    features.put("structured_errors", JsonBool(true))   // error.code / error.retryable
    features.put("per_turn_model_override", JsonBool(true))     // chat 帧字段（一次性）
    features.put("session_model_switch", JsonBool(true))        // switch_model 帧（会话级）
    features.put("diff_in_tool_result", JsonBool(true))         // tool_result.diff（文件改动类工具）
    features.put("tool_result_truncation", JsonInt(2000))       // bash 结果截断阈值
    // ws 段的硬限制要公告：客户端据此发送前分段，而不是发出去被丢
    // （超限帧现在会显式回 error.code=frame_too_large，但提前知道上限才最省事）
    var wsLimits = JsonObject()
    wsLimits.put("max_frame_bytes", JsonInt(WS_MAX_INBOUND_BYTES))
    features.put("ws", wsLimits)

    // shell 自述（v1.6.2）：没装 Git Bash 的机器会降级 PowerShell，而模型的命令语法
    // 必须跟着变。客户端据此提示用户、或调整它自己发的命令；排障时也能一眼看到用的是哪个 shell。
    let shell = ShellProvider()
    var shellInfo = JsonObject()
    shellInfo.put("path", JsonString(shell.shellPath))
    shellInfo.put("mode", JsonString(if (shell.isBash) { "bash" } else { "powershell" }))
    shellInfo.put("source", JsonString(shell.source))
    features.put("shell", shellInfo)

    var obj = JsonObject()
    obj.put("protocol", JsonInt(capabilityProtocolVersion()))
    obj.put("ws_in", wsIn)
    obj.put("ws_out", wsOut)
    obj.put("http", http)
    obj.put("features", features)
    return obj
}
