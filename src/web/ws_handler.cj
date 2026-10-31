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

import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjh.gateway.*
import cjcfg.*

/**
 * 入站 WebSocket 帧的上限（字节）。
 *
 * 为什么需要它：单帧超过底层实现的上限时，读侧会抛异常，旧代码把异常吞成
 * `running = false` —— 连接看着还在，之后发的消息再没人处理，客户端只能靠"没有回帧"猜。
 * 灵渠迁移台就栽在这上面：4.4 KB 的任务书整段发过来，cjh 静默丢弃，排查了三轮。
 *
 * 现在的语义：超过这个值 → **显式回 error 帧**（code=frame_too_large），并把这个值
 * 通过 `/api/capabilities` 的 `ws.max_frame_bytes` 公告出去，客户端可以提前分段。
 */
public let WS_MAX_INBOUND_BYTES: Int64 = 256 * 1024

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
    private let gateway: ChannelGateway
    // WS 连接 ID 自增计数器
    static var nextId: Int64 = 1

    public init(config: CjhConfig, gateway: ChannelGateway) {
        this.config = config
        this.gateway = gateway
    }

    /**
     * 处理 HTTP 请求：升级为 WebSocket
     *
     * 重构后 WsHandler 只负责 WebSocket 帧读写 + JSON 解析。
     * 业务逻辑（Agent 执行 + 事件分发）全部下沉到 ChannelGateway。
     */
    public func handle(ctx: HttpContext): Unit {
        // 鉴权：配置了 token 时 WS 也必须携带（Authorization: Bearer 或 ?token=）。
        // 校验必须发生在 upgradeFromServer 之前，否则已经 101 升级再回 401 是非法响应。
        if (!Auth.check(ctx, this.config)) {
            return
        }
        // WebSocket 握手
        let ws = WebSocket.upgradeFromServer(ctx)

        // 生成 WS 连接 ID（自增）
        let wsId = "ws_${WsHandler.nextId}"
        WsHandler.nextId += 1

        // WebSocket write 非线程安全，用 Mutex 保护
        let wsMutex = Mutex()

        // 创建 WebChannel（Channel 抽象的 Web 实现）
        // WebChannel 把 Channel 接口方法桥接到 WebSocket 事件 JSON
        let channel = WebChannel(ws, wsMutex)

        // 注册到 ChannelGateway：gateway 负责会话路由 + Agent 生命周期
        this.gateway.registerChannel(wsId, channel)

        // 消息接收循环：阻塞读取 WebSocket 帧，解析 JSON 消息，分发到 Gateway
        this.messageLoop(ws, wsId, wsMutex)

        // WS 断开：先请求中断在跑的回合（连接没了就不该留孤儿执行继续跑），
        // 再注销渠道 + 销毁会话
        this.gateway.interruptSession(wsId, wsId)
        this.gateway.unregisterChannel(wsId)
        this.gateway.destroySession(wsId, wsId)
    }

    /**
     * 消息接收循环
     */
    private func messageLoop(ws: WebSocket, wsId: String,
        wsMutex: Mutex): Unit {
        var running = true
        while (running) {
            try {
                let frame = ws.read()
                match (frame.frameType) {
                    case WebSocketFrameType.TextWebFrame =>
                        let text = this.frameToText(frame)
                        // 超限帧**必须显式回 error**：以前超长帧会让读循环静默结束——连接看着还在，
                        // 客户端发的消息再没人处理，只能靠"没有回帧"猜（灵渠 4.4KB 任务书踩了这坑）。
                        if (Int64(text.size) > WS_MAX_INBOUND_BYTES) {
                            this.replyErrorFrame(ws, wsMutex, "frame_too_large",
                                "入站帧 ${text.size} 字节超过上限 ${WS_MAX_INBOUND_BYTES}（见 /api/capabilities 的 ws.max_frame_bytes）；请分段发送或改写为让 agent 读文件")
                            continue
                        }
                        this.handleWsMessage(wsId, wsMutex, text)
                    case WebSocketFrameType.BinaryWebFrame =>
                        ()
                    case WebSocketFrameType.CloseWebFrame =>
                        running = false
                    case WebSocketFrameType.PingWebFrame =>
                        ws.writePongFrame(frame.payload)
                    case WebSocketFrameType.PongWebFrame =>
                        ()
                    case _ =>
                        ()
                }
            } catch (e: Exception) {
                // 读失败不再静默退出：先把原因回给对端，再收尾
                this.replyErrorFrame(ws, wsMutex, "ws_read_failed",
                    "读取 WebSocket 帧失败（多半是单帧超过实现上限）：${e}")
                running = false
            }
        }
    }

    /** 直接回一个 error 帧（不经过 gateway：这条路径上会话可能已经不可用） */
    private func replyErrorFrame(ws: WebSocket, wsMutex: Mutex, code: String, message: String): Unit {
        var o = JsonObject()
        o.put("type", JsonString("error"))
        o.put("code", JsonString(code))
        o.put("message", JsonString(message))
        o.put("retryable", JsonBool(false))
        let json = o.toJsonString()
        try {
            wsMutex.lock()
            let data = json.toArray()
            var byteArr = Array<UInt8>(data.size, repeat: 0)
            for (i in 0..data.size) {
                byteArr[i] = UInt8(data[i])
            }
            ws.write(WebSocketFrameType.TextWebFrame, byteArr)
        } catch (e: Exception) {
            let _ = e
        } finally {
            wsMutex.unlock()
        }
    }

    /**
     * 处理单条 WebSocket 消息：解析 JSON，分发到 ChannelGateway
     *
     * 重构后此方法只做消息路由，业务逻辑下沉到 Gateway。
     */
    private func handleWsMessage(wsId: String, _: Mutex, jsonStr: String): Unit {
        let msgType = parseMsgType(jsonStr)
        match (msgType) {
            case WsMsgType.Chat =>
                // 解析聊天消息
                let v = JsonValue.fromStr(jsonStr)
                match (v.kind()) {
                    case JsonKind.JsObject =>
                        let req = ChatRequest.fromJson(v.asObject())
                        if (req.message.size > 0) {
                            // 交由 Gateway 处理：channelId = wsId（每个 WS 连接一个 channel）
                            // 可选 model/base_url/api_key：只对本回合生效（不落盘、不粘连）
                            this.gateway.handleUserMessage(wsId, wsId, req.message, req.modelOverride())
                        }
                    case _ => ()
                }
            case WsMsgType.NewSession =>
                // 新建会话：销毁旧会话，创建新会话
                this.gateway.destroySession(wsId, wsId)
                this.gateway.createSession(wsId, wsId)
            case WsMsgType.ResumeSession =>
                // 恢复历史会话：加载消息历史，推回前端渲染
                this.handleResumeSession(wsId, jsonStr)
            case WsMsgType.SwitchModel =>
                // 切换模型（会话级，不落盘）：网关回 ack 或 error，不静默
                let v = JsonValue.fromStr(jsonStr)
                match (v.kind()) {
                    case JsonKind.JsObject =>
                        let req = SwitchModelRequest.fromJson(v.asObject())
                        this.gateway.handleSwitchModel(wsId, wsId, req.model, req.baseUrl, req.apiKey)
                    case _ => ()
                }
            case WsMsgType.Compact =>
                // 压缩历史：网关回 ack（含压缩前后消息数）
                this.gateway.handleCompact(wsId, wsId)
            case WsMsgType.ApprovalResponse =>
                // 审批结果：命中未决请求则唤醒等待中的回合；
                // 未知/过期的 request_id 由网关回结构化错误，不静默
                this.gateway.handleApprovalResponse(wsId, wsId,
                    extractStr(jsonStr, "request_id"), extractBool(jsonStr, "approved"))
            case WsMsgType.Abort | WsMsgType.Cancel =>
                // 中断/取消当前执行：网关回 cancelled（was_running 如实反映）
                this.gateway.handleCancel(wsId, wsId, extractStr(jsonStr, "session_id"))
            case _ =>
                // 未知消息类型，忽略
                ()
        }
    }

    /**
     * 处理 resume_session 请求：
     * 1. 解析 session_id
     * 2. 销毁当前会话，恢复历史会话
     * 3. 加载历史消息，通过 Channel 推回前端
     */
    private func handleResumeSession(wsId: String, jsonStr: String): Unit {
        // 解析 session_id
        let sessionId = extractStr(jsonStr, "session_id")

        if (sessionId.size == 0) {
            return
        }

        // 交由 Gateway 处理：Gateway 加载历史消息，通过 Channel 推回前端
        this.gateway.handleResumeSession(wsId, wsId, sessionId)
    }

    /**
     * 从帧 JSON 里取布尔字段（缺失/类型不符 → false，即"谨慎默认：拒绝"）
     */
    private func extractBool(jsonStr: String, key: String): Bool {
        match (JsonValue.fromStr(jsonStr).kind()) {
            case JsonKind.JsObject => return optBool(JsonValue.fromStr(jsonStr).asObject(), key)
            case _ => return false
        }
    }

    /**
     * 从帧 JSON 里取字符串字段（缺失/类型不符 → 空串）
     */
    private func extractStr(jsonStr: String, key: String): String {
        match (JsonValue.fromStr(jsonStr).kind()) {
            case JsonKind.JsObject => return optStr(JsonValue.fromStr(jsonStr).asObject(), key)
            case _ => return ""
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

}
