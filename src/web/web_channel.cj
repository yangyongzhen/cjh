package cjh.web

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
import cjh.gateway.*

public class WebChannel <: Channel {
    private let ws: WebSocket
    private let wsMutex: Mutex

    public init(ws: WebSocket, wsMutex: Mutex) {
        this.ws = ws
        this.wsMutex = wsMutex
    }

    public func channelId(): String { "web" }

    public func sendDelta(chatId: String, text: String): Unit {
        let event = DeltaEvent(text)
        this.sendWs(event.toJson())
    }

    public func sendToolStart(chatId: String, name: String, args: JsonObject): Unit {
        let event = ToolStartEvent(name, args)
        this.sendWs(event.toJson())
    }

    public func sendToolResult(chatId: String, name: String, result: String, isError: Bool): Unit {
        let event = ToolResultEvent(name, result, isError)
        this.sendWs(event.toJson())
    }

    public func sendDone(chatId: String, summary: JsonObject): Unit {
        // 从 summary JsonObject 提取字段构造 DoneEvent
        let rounds = this.getInt(summary, "rounds")
        let tools = this.getInt(summary, "tools")
        let durationMs = this.getInt(summary, "duration_ms")
        let tokens = this.getInt(summary, "tokens")
        let cached = this.getInt(summary, "cached")
        let event = DoneEvent(rounds, tools, durationMs, tokens, cached)
        this.sendWs(event.toJson())
    }

    public func sendError(chatId: String, message: String): Unit {
        let event = ErrorEvent(message)
        this.sendWs(event.toJson())
    }

    public func sendHistory(chatId: String, sessionId: String, messages: JsonArray): Unit {
        var obj = JsonObject()
        obj.put("type", JsonString("history_messages"))
        obj.put("session_id", JsonString(sessionId))
        obj.put("messages", messages)
        this.sendWs(obj.toJsonString())
    }

    public func sendTasks(chatId: String, tasks: JsonArray): Unit {
        var obj = JsonObject()
        obj.put("type", JsonString("tasks"))
        obj.put("tasks", tasks)
        this.sendWs(obj.toJsonString())
    }

    /**
     * 线程安全发送 WebSocket 文本帧
     */
    private func sendWs(json: String): Unit {
        try {
            this.wsMutex.lock()
            let data = json.toArray()
            var byteArr = Array<UInt8>(data.size, repeat: 0)
            for (i in 0..data.size) {
                byteArr[i] = UInt8(data[i])
            }
            this.ws.write(WebSocketFrameType.TextWebFrame, byteArr)
        } finally {
            this.wsMutex.unlock()
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
}
