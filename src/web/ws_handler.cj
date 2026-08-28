package cjh.web

/**
 * WebSocket 消息处理器
 *
 * 职责：
 *   1. WebSocket 握手（upgradeFromServer）
 *   2. 接收浏览器消息，分发到 Agent
 *   3. Agent 三回调（onDelta/onToolStart/onToolResult）→ WS 推送
 *
 * 架构参考：docs/Web支持实现方案.md § 三、架构设计
 */

import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjh.agent.*
import cjh.tools.*
import cjllm.*
import cjcfg.*

/**
 * WebSocket 处理器
 *
 * 每个 WebSocket 连接创建一个 WsSession，负责：
 *   - 消息接收循环
 *   - Agent 回调 → WS 推送（线程安全：用 Mutex 保护 WebSocket write）
 *   - 会话生命周期管理
 */
public class WsHandler <: HttpRequestHandler {
    private let config: CjhConfig
    private let provider: LlmProvider
    private let registry: ToolRegistry
    private let sessionMgr: WebSessionManager
    // WS 连接 ID 自增计数器
    static var nextId: Int64 = 1

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
        this.sessionMgr = WebSessionManager(config, provider, registry)
    }

    /**
     * 处理 HTTP 请求：升级为 WebSocket
     */
    public func handle(ctx: HttpContext): Unit {
        // WebSocket 握手
        let ws = WebSocket.upgradeFromServer(ctx)

        // 生成 WS 连接 ID（自增）
        let wsId = "ws_${WsHandler.nextId}"
        WsHandler.nextId += 1

        // 创建新会话
        let agent = this.sessionMgr.createSession(wsId)

        // 挂接 Agent 三回调 → WS 推送
        // WebSocket write 非线程安全，Agent.run 可能在不同协程触发回调
        // 用 Mutex 保护 write
        let wsMutex = Mutex()

        agent.onDelta = { delta: String =>
            try {
                wsMutex.lock()
                let event = DeltaEvent(delta)
                let json = event.toJson()
                this.sendWsText(ws, json)
            } finally {
                wsMutex.unlock()
            }
        }

        agent.onToolStart = { name: String, args: JsonObject =>
            try {
                wsMutex.lock()
                let event = ToolStartEvent(name, args)
                let json = event.toJson()
                this.sendWsText(ws, json)
            } finally {
                wsMutex.unlock()
            }
        }

        agent.onToolResult = { name: String, result: ToolResult =>
            try {
                wsMutex.lock()
                let event = ToolResultEvent(name, result.content, result.isError)
                let json = event.toJson()
                this.sendWsText(ws, json)
            } finally {
                wsMutex.unlock()
            }
        }

        // 消息接收循环
        this.messageLoop(ws, wsId, agent, wsMutex)

        // WS 断开，销毁会话
        this.sessionMgr.destroySession(wsId)
    }

    /**
     * 消息接收循环
     *
     * 阻塞读取 WebSocket 帧，解析 JSON 消息，分发到 Agent。
     * 收到 Close 帧或读取异常时退出循环。
     */
    private func messageLoop(ws: WebSocket, wsId: String, agent: Agent,
        wsMutex: Mutex): Unit {
        var running = true
        while (running) {
            try {
                let frame = ws.read()
                match (frame.frameType) {
                    case WebSocketFrameType.TextWebFrame =>
                        // 解析文本帧
                        let text = this.frameToText(frame)
                        this.handleWsMessage(ws, wsId, agent, wsMutex, text)
                    case WebSocketFrameType.BinaryWebFrame =>
                        // 忽略二进制帧
                        ()
                    case WebSocketFrameType.CloseWebFrame =>
                        // 收到 Close 帧，退出循环
                        running = false
                    case WebSocketFrameType.PingWebFrame =>
                        // 回复 Pong
                        ws.writePongFrame(frame.payload)
                    case WebSocketFrameType.PongWebFrame =>
                        // 忽略 Pong
                        ()
                    case _ =>
                        ()
                }
            } catch (e: Exception) {
                // 读取异常，退出循环
                running = false
            }
        }
    }

    /**
     * 处理单条 WebSocket 消息
     */
    private func handleWsMessage(ws: WebSocket, wsId: String, agent: Agent,
        wsMutex: Mutex, jsonStr: String): Unit {
        let msgType = parseMsgType(jsonStr)
        match (msgType) {
            case WsMsgType.Chat =>
                // 解析聊天消息
                let v = JsonValue.fromStr(jsonStr)
                match (v.kind()) {
                    case JsonKind.JsObject =>
                        let req = ChatRequest.fromJson(v.asObject())
                        if (req.message.size > 0) {
                            // 执行 Agent 循环（阻塞）
                            let summary = agent.run(req.message)
                            // 发送 DoneEvent
                            try {
                                wsMutex.lock()
                                let event = DoneEvent(
                                    summary.rounds,
                                    summary.toolCalls,
                                    summary.durationMs,
                                    summary.totalTokens(),
                                    summary.cachedTokens)
                                this.sendWsText(ws, event.toJson())
                            } finally {
                                wsMutex.unlock()
                            }
                        }
                    case _ => ()
                }
            case WsMsgType.NewSession =>
                // 新建会话：销毁旧会话，创建新会话
                this.sessionMgr.destroySession(wsId)
                let newAgent = this.sessionMgr.createSession(wsId)
                // 重新挂接回调（简化：复用原 agent 的回调闭包）
                // 实际需要重新设置回调，这里简化处理
                ()
            case WsMsgType.ResumeSession =>
                // 恢复历史会话：加载消息历史，推回前端渲染
                this.handleResumeSession(ws, wsId, wsMutex, jsonStr)
            case WsMsgType.Abort =>
                // 中断当前执行（简化：暂不实现中断）
                ()
            case _ =>
                // 未知消息类型，忽略
                ()
        }
    }

    /**
     * 处理 resume_session 请求：
     * 1. 解析 session_id
     * 2. 从 SessionStore 加载历史消息
     * 3. 把历史消息序列化为 JSON 推回前端
     *    前端收到 history_messages 后渲染对话区
     */
    private func handleResumeSession(ws: WebSocket, wsId: String, wsMutex: Mutex, jsonStr: String): Unit {
        // 解析请求
        let sessionId = match (JsonValue.fromStr(jsonStr).kind()) {
            case JsonKind.JsObject =>
                let obj = JsonValue.fromStr(jsonStr).asObject()
                match (obj.get("session_id")) {
                    case Some(s) =>
                        match (s.kind()) {
                            case JsonKind.JsString => s.asString().getValue()
                            case _ => ""
                        }
                    case None => ""
                }
            case _ => ""
        }

        if (sessionId.size == 0) {
            return
        }

        // 从 SessionStore 加载历史消息
        let store = SessionStore(this.config.sessionsDir)
        let messages = store.load(sessionId)

        // 销毁当前会话，创建新会话并加载历史
        this.sessionMgr.destroySession(wsId)
        let newAgent = this.sessionMgr.resumeSession(wsId, sessionId)

        // 序列化历史消息为 JSON
        var msgArr = JsonArray()
        for (i in 0..messages.size) {
            let m = messages[i]
            var msgObj = JsonObject()
            msgObj.put("role", JsonString(m.role))
            msgObj.put("content", JsonString(m.content))
            if (m.toolCallId.size > 0) {
                msgObj.put("tool_call_id", JsonString(m.toolCallId))
            }
            if (m.name.size > 0) {
                msgObj.put("name", JsonString(m.name))
            }
            msgArr.add(msgObj)
        }

        var respObj = JsonObject()
        respObj.put("type", JsonString("history_messages"))
        respObj.put("session_id", JsonString(sessionId))
        respObj.put("messages", msgArr)

        // 推回前端
        try {
            wsMutex.lock()
            this.sendWsText(ws, respObj.toJsonString())
        } finally {
            wsMutex.unlock()
        }
    }

    /**
     * WebSocket 文本帧 → String
     */
    private func frameToText(frame: WebSocketFrame): String {
        let payload = frame.payload
        // payload 是 Array<UInt8>，Byte 是 UInt8 别名，直接赋值
        var bytes = Array<Byte>(payload.size, repeat: 0)
        for (i in 0..payload.size) {
            bytes[i] = payload[i]
        }
        return String.fromUtf8(bytes)
    }

    /**
     * 发送 WebSocket 文本消息
     */
    private func sendWsText(ws: WebSocket, text: String): Unit {
        let data = text.toArray()
        var byteArr = Array<UInt8>(data.size, repeat: 0)
        for (i in 0..data.size) {
            byteArr[i] = UInt8(data[i])
        }
        ws.write(WebSocketFrameType.TextWebFrame, byteArr)
    }
}
