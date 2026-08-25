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

/**
 * 消息类型枚举（对应 JSON "type" 字段的值）
 */
public enum WsMsgType {
    | Chat            // 浏览器 → 服务器：发送聊天消息
    | Abort           // 浏览器 → 服务器：中断当前执行
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
        return req
    }
}

/**
 * 中断请求：浏览器请求中断当前执行
 * { "type": "abort" }
 */
public class AbortRequest {
    public init() {}
}

/**
 * 切换模型请求
 * { "type": "switch_model", "model": "deepseek-v4-flash" }
 */
public class SwitchModelRequest {
    public var model: String = ""

    public init() {}

    public static func fromJson(obj: JsonObject): SwitchModelRequest {
        let req = SwitchModelRequest()
        match (obj.get("model")) {
            case Some(m) =>
                match (m.kind()) {
                    case JsonKind.JsString => req.model = m.asString().getValue()
                    case _ => ()
                }
            case None => ()
        }
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
 * 错误事件
 * { "type": "error", "message": "Provider 连接失败" }
 */
public class ErrorEvent {
    public var message: String = ""

    public init() {}

    public init(message: String) {
        this.message = message
    }

    public func toJson(): String {
        var obj = JsonObject()
        obj.put("type", JsonString("error"))
        obj.put("message", JsonString(this.message))
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
