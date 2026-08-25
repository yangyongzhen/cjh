package cjcfg

import std.fs.*
import stdx.encoding.json.*
import std.collection.*
import std.time.*
import cjllm.*

/**
 * 会话持久化：agent 消息历史保存/恢复
 *
 * 存储：~/.cjh/sessions/<会话ID>.json
 * 格式：{"id": "...", "created": "...", "messages": [{role, content, tool_call_id?, name?}, ...]}
 */
public class SessionStore {
    private let dir: String

    public init(dir: String) {
        this.dir = dir
    }

    /**
     * 列出所有会话（按时间倒序），返回 (id, 首条用户消息摘要)
     */
    public func list(): ArrayList<(String, String)> {
        var result = ArrayList<(String, String)>()
        if (!exists(this.dir)) {
            return result
        }
        let files = ArrayList<String>()
        Directory.walk(this.dir, { fi =>
            if (fi.name.endsWith(".json")) {
                files.add(fi.name)
            }
            return true
        })
        for (e in files) {
            let id = e[0..e.size - 5]
            let summary = this.summary(e)
            result.add((id, summary))
        }
        return result
    }

    private func summary(file: String): String {
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.dir + "/" + file)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(msgs) <- obj.get("messages")) {
                        match (msgs.kind()) {
                            case JsonKind.JsArray =>
                                let arr = msgs.asArray()
                                // 找第一条 user 消息
                                for (i in 0..arr.size()) {
                                    if (let Some(m) <- arr.get(i)) {
                                        match (m.kind()) {
                                            case JsonKind.JsObject =>
                                                let mo = m.asObject()
                                                if (let Some(role) <- mo.get("role") && let Some(content) <- mo.get("content")) {
                                                    match (role.kind()) {
                                                        case JsonKind.JsString =>
                                                            match (content.kind()) {
                                                                case JsonKind.JsString =>
                                                                    if (role.asString().getValue() == "user") {
                                                                        let c = content.asString().getValue()
                                                                        return if (c.size > 40) { c[0..40] + "…" } else { c }
                                                                    }
                                                                case _ => ()
                                                            }
                                                        case _ => ()
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            return ""
        }
        return ""
    }

    /**
     * 保存消息历史到新会话文件，返回会话 ID（无父会话）
     */
    public func save(messages: ArrayList<ChatMessage>): String {
        return this.saveFork(messages, "")
    }

    /**
     * 保存分支会话（树形）：parent 为来源会话 ID（空=根会话），
     * forkAt 为分支点的消息条数（从第 0 条到 forkAt 条属于该分支前缀）。
     */
    public func saveFork(messages: ArrayList<ChatMessage>, parent: String): String {
        this.ensureDir()
        let id = this.newSessionId()
        let path = this.dir + "/" + id + ".json"

        var root = JsonObject()
        root.put("id", JsonString(id))
        root.put("created", JsonString(DateTime.now().toString()))
        if (parent.size > 0) {
            root.put("parent", JsonString(parent))
        }
        var msgArr = ArrayList<JsonValue>()
        for (m in messages) {
            msgArr.add(m.toOpenAiJson())
        }
        root.put("messages", JsonArray(msgArr))
        File.writeTo(path, root.toJsonString().toArray())
        return id
    }

    /**
     * 会话的父会话 ID（树形分支链）；无父返回 ""
     */
    public func parentOf(id: String): String {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return ""
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(p) <- obj.get("parent")) {
                        match (p.kind()) {
                            case JsonKind.JsString => return p.asString().getValue()
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            ()
        }
        return ""
    }

    /**
     * 列出所有会话（树形视图数据）：(id, 摘要, parent)
     */
    public func listTree(): ArrayList<(String, String, String)> {
        var result = ArrayList<(String, String, String)>()
        if (!exists(this.dir)) {
            return result
        }
        let files = ArrayList<String>()
        Directory.walk(this.dir, { fi =>
            if (fi.name.endsWith(".json")) {
                files.add(fi.name)
            }
            return true
        })
        for (e in files) {
            let id = e[0..e.size - 5]
            let summary = this.summary(e)
            let parent = this.parentOf(id)
            result.add((id, summary, parent))
        }
        return result
    }

    /**
     * 恢复会话消息历史；不存在返回空
     */
    public func load(id: String): ArrayList<ChatMessage> {
        var messages = ArrayList<ChatMessage>()
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return messages
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(msgs) <- obj.get("messages")) {
                        match (msgs.kind()) {
                            case JsonKind.JsArray =>
                                let arr = msgs.asArray()
                                for (i in 0..arr.size()) {
                                    if (let Some(m) <- arr.get(i)) {
                                        messages.add(this.parseMessage(m))
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            eprintln("[cjh] 会话 ${id} 加载失败: ${e}")
        }
        return messages
    }

    private func parseMessage(v: JsonValue): ChatMessage {
        match (v.kind()) {
            case JsonKind.JsObject =>
                let obj = v.asObject()
                var role = "user"
                var content = ""
                var toolId = ""
                var name = ""
                if (let Some(r) <- obj.get("role")) {
                    match (r.kind()) {
                        case JsonKind.JsString => role = r.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(c) <- obj.get("content")) {
                    match (c.kind()) {
                        case JsonKind.JsString => content = c.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(t) <- obj.get("tool_call_id")) {
                    match (t.kind()) {
                        case JsonKind.JsString => toolId = t.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(n) <- obj.get("name")) {
                    match (n.kind()) {
                        case JsonKind.JsString => name = n.asString().getValue()
                        case _ => ()
                    }
                }
                if (toolId.size > 0) {
                    return ChatMessage(role, content, toolId, name)
                }
                return ChatMessage(role, content)
            case _ => return ChatMessage("user", "")
        }
    }

    private func ensureDir(): Unit {
        if (!exists(this.dir)) {
            Directory.create(this.dir, recursive: true)
        }
    }

    /**
     * 生成新会话 ID（时间戳格式 s<秒>.<毫秒>）
     * 供外部预生成（如工具结果落盘需要会话 ID 时）
     */
    public func newSessionId(): String {
        let now = DateTime.now()
        let ts = now.toUnixTimeStamp()
        // 紧凑：秒.毫秒
        let secs = ts.toSeconds()
        let millis = ts.toMilliseconds() - secs * 1000
        return "s" + secs.toString() + "." + millis.toString()
    }
}
