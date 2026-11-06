package cjh.web

import cjh.tools.*

/**
 * WebChannel：Web 渠道 Channel 实现
 *
 * 把 Channel 接口方法桥接到现有 WebSocket 事件 JSON：
 *   sendDelta  → DeltaEvent.toJson()  → ws.send
 *   sendToolStart → ToolStartEvent.toJson() → ws.send
 *   ...
 *
 * 每个 WebSocket 连接创建一个 WebChannel 实例，
 * 内部持有 ws 引用 + wsMutex（保护 ws.write 线程安全）。
 */

import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjlog.*
import cjh.gateway.*

public class WebChannel <: Channel {
    private let ws: WebSocket
    private let wsMutex: Mutex
    // 发送守护：连接断开后不再每帧抛异常（见 sendWs 注释与 WsSendGuard）
    private let guard: WsSendGuard = WsSendGuard()

    public init(ws: WebSocket, wsMutex: Mutex) {
        this.ws = ws
        this.wsMutex = wsMutex
    }

    public func channelId(): String { "web" }

    public func sendDelta(_: String, meta: FrameMeta, text: String): Unit {
        let event = DeltaEvent(text)
        event.meta = meta
        this.sendWs(event.toJson())
    }

    public func sendToolStart(_: String, meta: FrameMeta, name: String, args: JsonObject): Unit {
        let event = ToolStartEvent(name, args)
        event.meta = meta
        this.sendWs(event.toJson())
    }

    public func sendToolResult(_: String, meta: FrameMeta, name: String, result: String,
        isError: Bool, diff: ?DiffInfo): Unit {
        let event = ToolResultEvent(name, result, isError)
        event.meta = meta
        event.diff = diff
        this.sendWs(event.toJson())
    }

    public func sendDone(_: String, meta: FrameMeta, summary: JsonObject): Unit {
        // 从 summary JsonObject 提取字段构造 DoneEvent
        let rounds = this.getInt(summary, "rounds")
        let tools = this.getInt(summary, "tools")
        let durationMs = this.getInt(summary, "duration_ms")
        let tokens = this.getInt(summary, "tokens")
        let cached = this.getInt(summary, "cached")
        let event = DoneEvent(rounds, tools, durationMs, tokens, cached)
        event.meta = meta
        let reason = this.getStr(summary, "finish_reason")
        event.finishReason = if (reason.size > 0) { reason } else { "stop" }
        // 截断信号：网关只在真截断时才放进 summary，缺键 = 未截断（不虚报）
        event.truncated = this.getBool(summary, "truncated")
        this.sendWs(event.toJson())
    }

    public func sendError(_: String, message: String): Unit {
        let event = ErrorEvent(message)
        this.sendWs(event.toJson())
    }

    /**
     * 结构化错误：带 code / retryable（客户端据此决定重试 / 换模型 / 新建会话）
     */
    public func sendErrorCode(_: String, meta: FrameMeta, message: String, code: String,
        retryable: Bool): Unit {
        let event = ErrorEvent(message, code, retryable)
        event.meta = meta
        this.sendWs(event.toJson())
    }

    /**
     * 审批类错误：带 request_id，客户端按 id 精确关掉对应审批项（复核 C）
     */
    public func sendApprovalError(_: String, requestId: String, message: String,
        code: String): Unit {
        let event = ErrorEvent(message, code, false)
        event.requestId = requestId
        this.sendWs(event.toJson())
    }

    /**
     * 控制帧回执（switch_model / compact）
     */
    public func sendAck(_: String, ack: AckInfo): Unit {
        let event = AckEvent(ack.action)
        event.sessionId = ack.sessionId
        event.model = ack.model
        event.baseUrl = ack.baseUrl
        event.compacted = ack.compacted
        event.messagesBefore = ack.messagesBefore
        event.messagesAfter = ack.messagesAfter
        this.sendWs(event.toJson())
    }

    /**
     * 取消回执（cancel / abort）
     */
    public func sendCancelled(_: String, info: CancelledInfo): Unit {
        let event = CancelledEvent(info.sessionId, info.wasRunning)
        this.sendWs(event.toJson())
    }

    public func sendHistory(_: String, sessionId: String, messages: JsonArray): Unit {
        this.sendWs(historyMessagesJson(sessionId, messages))
    }

    public func sendTasks(_: String, tasks: JsonArray): Unit {
        this.sendWs(tasksFrameJson(tasks))
    }

    /**
     * 后台任务状态帧（v6）
     *
     * 不进 Channel 接口：后台任务表是进程级全局的，不属于任何一次回合/会话，
     * 而 Channel 的每个方法都以 chatId 为路由键。由 BgTaskBroadcaster 直接广播到
     * 各条存活连接即可，避免为一个全局面板改动整个渠道接口（及其全部实现）。
     */
    public func sendBgTask(info: BgTaskEventInfo): Unit {
        this.sendWs(bgTaskFrameJson(info))
    }

    /** 槽位账帧（v7 `bg_slots`）：两本限量账的全局快照 */
    public func sendBgSlots(bgUsed: Int64, bgMax: Int64, agentsUsed: Int64, agentsMax: Int64): Unit {
        this.sendWs(bgSlotsFrameJson(bgUsed, bgMax, agentsUsed, agentsMax))
    }

    public func sendApprovalRequest(_: String, info: ApprovalRequestInfo): Unit {
        let ev = ApprovalRequestEvent(info.requestId, info.toolName, info.args, info.reason)
        ev.meta = info.meta
        ev.expiresInMs = info.expiresInMs
        this.sendWs(ev.toJson())
    }

    /**
     * 线程安全发送 WebSocket 文本帧
     *
     * **写失败绝不能抛穿**：客户端断开后继续写会抛 SocketException(10053)，
     * 而它的调用方是 agent 的事件回调 —— 异常一路抛到 `Agent.run` 顶层，
     * 整轮 run 当场结束，正在跑的 tool_result 永久丢失（灵渠 0.39.7 实测：
     * 页面永远停在 tool_start:24 / tool_result:23）。这里改成"记一次日志 +
     * 判死连接 + 后续帧直接跳过"，让这一轮把活干完。
     */
    private func sendWs(json: String): Unit {
        if (!this.guard.allowsSend()) {
            return
        }
        try {
            this.wsMutex.lock()
            try {
                let data = json.toArray()
                var byteArr = Array<UInt8>(data.size, repeat: 0)
                for (i in 0..data.size) {
                    byteArr[i] = UInt8(data[i])
                }
                this.ws.write(WebSocketFrameType.TextWebFrame, byteArr)
                this.guard.onSent()
            } finally {
                this.wsMutex.unlock()
            }
        } catch (e: Exception) {
            if (this.guard.onFailed("${e}")) {
                Log.warn("WebChannel 发送失败，连接判定为断开，后续帧跳过（${this.guard.summary()}）")
            }
        }
    }

    /**
     * 从 JsonObject 提取 Int64 字段
     */
    private func getInt(obj: JsonObject, key: String): Int64 {
        match (obj.get(key)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsInt => return v.asInt().getValue()
                    case _ => return 0
                }
            case None => return 0
        }
    }

    /**
     * 从 JsonObject 提取 String 字段（缺失或类型不符 → 空串）
     */
    private func getStr(obj: JsonObject, key: String): String {
        match (obj.get(key)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsString => return v.asString().getValue()
                    case _ => return ""
                }
            case None => return ""
        }
    }

    /**
     * 从 JsonObject 提取 Bool 字段（缺失或类型不符 → false）
     */
    private func getBool(obj: JsonObject, key: String): Bool {
        match (obj.get(key)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsBool => return v.asBool().getValue()
                    case _ => return false
                }
            case None => return false
        }
    }
}
