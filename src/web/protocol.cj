package cjh.web

/**
 * WebSocket 消息协议定义
 *
 * 浏览器 ↔ cjh web server 之间的 JSON 消息格式。
 * 每条消息是一个 JSON 对象，包含 "type" 字段标识消息类型。
 *
 * 消息方向：
 *   - 浏览器 → 服务器：ChatRequest / AbortRequest / SwitchModelRequest /
 *                      NewSessionRequest / ResumeSessionRequest / CompactRequest
 *   - 服务器 → 浏览器：DeltaEvent / ToolStartEvent / ToolResultEvent /
 *                      DoneEvent / ErrorEvent / TasksUpdateEvent
 *
 * 架构参考：docs/Web支持实现方案.md § 四、消息协议定义
 */

import std.collection.*
import stdx.encoding.json.*
import cjh.gateway.*

/**
 * 消息类型枚举（对应 JSON "type" 字段的值）
 */
public enum WsMsgType {
    | Chat            // 浏览器 → 服务器：发送聊天消息
    | Abort           // 浏览器 → 服务器：中断当前执行
    | Cancel          // 浏览器 → 服务器：取消当前执行（与 Abort 同义，兼容两种命名）
    | SwitchModel     // 浏览器 → 服务器：切换模型
    | NewSession      // 浏览器 → 服务器：新建会话
    | ResumeSession   // 浏览器 → 服务器：恢复历史会话
    | Compact         // 浏览器 → 服务器：压缩历史
    | Delta           // 服务器 → 浏览器：LLM 增量输出
    | ToolStart       // 服务器 → 浏览器：工具调用开始
    | ToolResult      // 服务器 → 浏览器：工具调用结束
    | Done            // 服务器 → 浏览器：回合结束总结
    | Error           // 服务器 → 浏览器：错误
    | Tasks           // 服务器 → 浏览器：任务列表更新
    | Unknown         // 未知类型
}

/**
 * 从 JSON 字符串解析消息类型
 */
public func parseMsgType(jsonStr: String): WsMsgType {
    let v = JsonValue.fromStr(jsonStr)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            match (obj.get("type")) {
                case Some(t) =>
                    match (t.kind()) {
                        case JsonKind.JsString =>
                            match (t.asString().getValue()) {
                                case "chat" => return WsMsgType.Chat
                                case "abort" => return WsMsgType.Abort
                                case "cancel" => return WsMsgType.Cancel
                                case "switch_model" => return WsMsgType.SwitchModel
                                case "new_session" => return WsMsgType.NewSession
                                case "resume_session" => return WsMsgType.ResumeSession
                                case "compact" => return WsMsgType.Compact
                                case "delta" => return WsMsgType.Delta
                                case "tool_start" => return WsMsgType.ToolStart
                                case "tool_result" => return WsMsgType.ToolResult
                                case "done" => return WsMsgType.Done
                                case "error" => return WsMsgType.Error
                                case "tasks" => return WsMsgType.Tasks
                                case _ => return WsMsgType.Unknown
                            }
                        case _ => return WsMsgType.Unknown
                    }
                case None => return WsMsgType.Unknown
            }
        case _ => return WsMsgType.Unknown
    }
}

// ====== 浏览器 → 服务器 消息 ======

/**
 * 聊天请求：浏览器发送消息给 LLM
 * { "type": "chat", "message": "用 echo 工具回显 hello" }
 */
public class ChatRequest {
    public var message: String = ""

    /**
     * 单次执行的模型覆盖（可选）：本次 run 局部生效，不落盘、不粘连
     *
     * 优先级：帧字段 > 会话级 switch_model 覆盖 > 当前配置
     * JSON 字段：model / base_url（亦接受 baseUrl）/ api_key（亦接受 apiKey）；
     * 三者全缺 → 行为与旧客户端完全一致（沿用当前配置），未知字段一律忽略。
     */
    public var model: String = ""
    public var baseUrl: String = ""
    public var apiKey: String = ""

    public init() {}

    /**
     * 从 JSON 对象解析
     */
    public static func fromJson(obj: JsonObject): ChatRequest {
        let req = ChatRequest()
        match (obj.get("message")) {
            case Some(m) =>
                match (m.kind()) {
                    case JsonKind.JsString => req.message = m.asString().getValue()
                    case _ => ()
                }
            case None => ()
        }
        req.model = optStr(obj, "model")
        req.baseUrl = firstNonEmpty(optStr(obj, "base_url"), optStr(obj, "baseUrl"))
        req.apiKey = firstNonEmpty(optStr(obj, "api_key"), optStr(obj, "apiKey"))
        return req
    }

    /**
     * 是否带模型覆盖（三字段全空 = 无覆盖）
     */
    public func hasModelOverride(): Bool {
        return this.model.size > 0 || this.baseUrl.size > 0 || this.apiKey.size > 0
    }

    /**
     * 构造模型覆盖（无覆盖时返回 None）
     */
    public func modelOverride(): ?ModelOverride {
        if (!this.hasModelOverride()) {
            return None
        }
        return Some(ModelOverride(this.model, this.baseUrl, this.apiKey))
    }
}

/**
 * 读取 JSON 字符串字段（字段缺失或类型不符 → 空串）
 */
func optStr(obj: JsonObject, key: String): String {
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
 * 取第一个非空串（兼容 snake_case / camelCase 两种线上字段名）
 */
func firstNonEmpty(a: String, b: String): String {
    if (a.size > 0) {
        return a
    }
    return b
}

/**
 * 中断请求：浏览器请求中断当前执行
 * { "type": "abort" }
 */
public class AbortRequest {
    public init() {}
}

/**
 * 切换模型请求（会话级：只影响本会话后续执行，不落盘）
 *
 * { "type": "switch_model", "model": "deepseek-v4-flash",
 *   "base_url": "https://api.deepseek.com/v1/chat/completions", "api_key": "..." }
 *
 * base_url / api_key 可缺省：缺省时按 model 从配置的模型列表补齐端点与密钥
 * （对齐配置页「模型与端点成对设置」的语义），仍缺省则沿用当前配置。
 */
public class SwitchModelRequest {
    public var model: String = ""
    public var baseUrl: String = ""
    public var apiKey: String = ""

    public init() {}

    public static func fromJson(obj: JsonObject): SwitchModelRequest {
        let req = SwitchModelRequest()
        req.model = optStr(obj, "model")
        req.baseUrl = firstNonEmpty(optStr(obj, "base_url"), optStr(obj, "baseUrl"))
        req.apiKey = firstNonEmpty(optStr(obj, "api_key"), optStr(obj, "apiKey"))
        return req
    }
}

/**
 * 新建会话请求
 * { "type": "new_session" }
 */
public class NewSessionRequest {
    public init() {}
}

/**
 * 恢复历史会话请求
 * { "type": "resume_session", "session_id": "s1787665309.605" }
 */
public class ResumeSessionRequest {
    public var sessionId: String = ""

    public init() {}

    public static func fromJson(obj: JsonObject): ResumeSessionRequest {
        let req = ResumeSessionRequest()
        match (obj.get("session_id")) {
            case Some(s) =>
                match (s.kind()) {
                    case JsonKind.JsString => req.sessionId = s.asString().getValue()
                    case _ => ()
                }
            case None => ()
        }
        return req
    }
}

/**
 * 压缩历史请求
 * { "type": "compact" }
 */
public class CompactRequest {
    public init() {}
}

// ====== 服务器 → 浏览器 消息 ======

/**
 * LLM 增量输出事件
 * { "type": "delta", "text": "已用 echo 工具" }
 */
public class DeltaEvent {
    public var text: String = ""

    public init() {}

    public init(text: String) {
        this.text = text
    }

    /**
     * 序列化为 JSON 字符串
     */
    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("delta"))
        obj.put("text", JsonString(this.text))
        return obj.toJsonString()
    }
}

/**
 * 工具调用开始事件
 * { "type": "tool_start", "name": "echo", "args": {"message": "hello"} }
 */
public class ToolStartEvent {
    public var name: String = ""
    public var args: JsonObject = JsonObject()

    public init() {}

    public init(name: String, args: JsonObject) {
        this.name = name
        this.args = args
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("tool_start"))
        obj.put("name", JsonString(this.name))
        obj.put("args", this.args)
        return obj.toJsonString()
    }
}

/**
 * 工具调用结束事件
 * { "type": "tool_result", "name": "echo", "content": "[echo plugin] message: hello", "is_error": false }
 */
public class ToolResultEvent {
    public var name: String = ""
    public var content: String = ""
    public var isError: Bool = false

    public init() {}

    public init(name: String, content: String, isError: Bool) {
        this.name = name
        this.content = content
        this.isError = isError
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("tool_result"))
        obj.put("name", JsonString(this.name))
        obj.put("content", JsonString(this.content))
        obj.put("is_error", JsonBool(this.isError))
        return obj.toJsonString()
    }
}

/**
 * 回合结束总结事件
 * { "type": "done", "summary": {"rounds": 2, "tools": 1, "duration_ms": 4062, "tokens": 4855, "cached": 4681} }
 */
public class DoneEvent {
    public var rounds: Int64 = 0
    public var tools: Int64 = 0
    public var durationMs: Int64 = 0
    public var tokens: Int64 = 0
    public var cached: Int64 = 0

    public init() {}

    public init(rounds: Int64, tools: Int64, durationMs: Int64,
        tokens: Int64, cached: Int64) {
        this.rounds = rounds
        this.tools = tools
        this.durationMs = durationMs
        this.tokens = tokens
        this.cached = cached
    }

    public func toJson(): String {
        var summary = JsonObject()
        summary.put("rounds", JsonInt(this.rounds))
        summary.put("tools", JsonInt(this.tools))
        summary.put("duration_ms", JsonInt(this.durationMs))
        summary.put("tokens", JsonInt(this.tokens))
        summary.put("cached", JsonInt(this.cached))

        var obj = JsonObject()
        obj.put("type", JsonString("done"))
        obj.put("summary", summary)
        return obj.toJsonString()
    }
}

/**
 * 控制帧回执事件（switch_model / compact 处理后必回）
 *
 * { "type": "ack", "action": "switch_model", "session_id": "s1787665309.605",
 *   "model": "deepseek-v4-flash", "base_url": "https://api.deepseek.com/v1/chat/completions",
 *   "compacted": false, "messages_before": 0, "messages_after": 0 }
 *
 * 字段固定全量输出（不按 action 裁剪），客户端可依赖稳定结构。
 */
public class AckEvent {
    public var action: String = ""
    public var sessionId: String = ""
    public var model: String = ""
    public var baseUrl: String = ""
    public var compacted: Bool = false
    public var messagesBefore: Int64 = 0
    public var messagesAfter: Int64 = 0

    public init() {}

    public init(action: String) {
        this.action = action
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("ack"))
        obj.put("action", JsonString(this.action))
        obj.put("session_id", JsonString(this.sessionId))
        obj.put("model", JsonString(this.model))
        obj.put("base_url", JsonString(this.baseUrl))
        obj.put("compacted", JsonBool(this.compacted))
        obj.put("messages_before", JsonInt(this.messagesBefore))
        obj.put("messages_after", JsonInt(this.messagesAfter))
        return obj.toJsonString()
    }
}

/**
 * 取消回执事件（cancel / abort 处理后必回）
 *
 * { "type": "cancelled", "session_id": "s1787665309.605", "was_running": true }
 *
 * was_running=false 表示这一帧到达时没有正在执行的回合（不是错误，是事实）。
 */
public class CancelledEvent {
    public var sessionId: String = ""
    public var wasRunning: Bool = false

    public init() {}

    public init(sessionId: String, wasRunning: Bool) {
        this.sessionId = sessionId
        this.wasRunning = wasRunning
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("cancelled"))
        obj.put("session_id", JsonString(this.sessionId))
        obj.put("was_running", JsonBool(this.wasRunning))
        return obj.toJsonString()
    }
}

/**
 * 错误事件
 * { "type": "error", "message": "Provider 连接失败", "code": "provider_error", "retryable": true }
 *
 * code / retryable 为后加字段：老客户端只读 message 不受影响，
 * 新客户端据 code 决定「重试 / 换模型 / 新建会话」。code 缺省 "internal"。
 */
public class ErrorEvent {
    public var message: String = ""
    public var code: String = ""
    public var retryable: Bool = false

    public init() {}

    public init(message: String) {
        this.message = message
    }

    public init(message: String, code: String, retryable: Bool) {
        this.message = message
        this.code = code
        this.retryable = retryable
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("error"))
        obj.put("message", JsonString(this.message))
        obj.put("code", JsonString(if (this.code.size > 0) { this.code } else { "internal" }))
        obj.put("retryable", JsonBool(this.retryable))
        return obj.toJsonString()
    }
}

/**
 * 任务列表更新事件
 * { "type": "tasks", "tasks": [{"id": 1, "content": "...", "status": "doing"}] }
 */
public class TasksUpdateEvent {
    public var tasks: ArrayList<TaskItem> = ArrayList<TaskItem>()

    public init() {}

    public init(tasks: ArrayList<TaskItem>) {
        this.tasks = tasks
    }

    public func toJson(): String {
        var tasksArr = JsonArray()
        for (i in 0..this.tasks.size) {
            let t = this.tasks[i]
            var taskObj = JsonObject()
            taskObj.put("id", JsonInt(t.id))
            taskObj.put("content", JsonString(t.content))
            taskObj.put("status", JsonString(t.statusStr))
            tasksArr.add(taskObj)
        }

        var obj = JsonObject()
        obj.put("type", JsonString("tasks"))
        obj.put("tasks", tasksArr)
        return obj.toJsonString()
    }
}

/**
 * 任务项（用于 TasksUpdateEvent）
 */
public class TaskItem {
    public var id: Int64 = 0
    public var content: String = ""
    public var statusStr: String = "pending"  // pending|doing|done

    public init() {}
}
