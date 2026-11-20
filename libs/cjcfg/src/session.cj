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
        // 按 created 倒序（旧实现按目录遍历顺序，Recent sessions 既不新也不旧）。
        // 排序用插入排序：会话数量小，避免引入额外依赖/比较器。
        var rows = ArrayList<(String, String, String)>()  // (id, summary, created)
        for (e in files) {
            let id = e[0..e.size - 5]
            rows.add((id, this.summary(e), this.createdOf(e)))
        }
        for (i in 1..rows.size) {
            let cur = rows[i]
            var j = i
            while (j > 0 && rows[j - 1][2].compare(cur[2]) == Ordering.LT) {
                rows[j] = rows[j - 1]
                j -= 1
            }
            rows[j] = cur
        }
        for (r in rows) {
            result.add((r[0], r[1]))
        }
        return result
    }

    /** 会话创建时间字符串（缺失/损坏返回空，排序时排到最后） */
    private func createdOf(file: String): String {
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.dir + "/" + file)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(c) <- obj.get("created")) {
                        match (c.kind()) {
                            case JsonKind.JsString => return c.asString().getValue()
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
     * 会话摘要安全截断：按 rune 截 40 个字符，控制字符转空格。
     * 旧实现 `c[0..40]` 按字节切，中文 3 字节/字时切点落在字符中间 →
     * cjh 启动读会话列表直接抛 UTF-8 异常，整个 TUI 起不来（用户实锤）。
     */
    private func clipSummary(raw: String): String {
        let maxChars: Int64 = 40
        var sb = StringBuilder()
        var n: Int64 = 0
        var truncated = false
        for (r in raw.toRuneArray()) {
            if (n >= maxChars) {
                truncated = true
                break
            }
            let ch = r.toString()
            if (ch == "\n" || ch == "\r" || ch == "\t") {
                sb.append(" ")
            } else {
                sb.append(ch)
            }
            n += 1
        }
        let text = sb.toString().trimAscii()
        return if (truncated) { text + "…" } else { text }
    }

    private func summary(file: String): String {
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.dir + "/" + file)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    // 重命名过的会话：title 字段优先于首条 user 消息
                    if (let Some(t) <- obj.get("title")) {
                        match (t.kind()) {
                            case JsonKind.JsString =>
                                let name = t.asString().getValue()
                                if (name.size > 0) {
                                    return this.clipSummary(name)
                                }
                            case _ => ()
                        }
                    }
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
                                                                        return this.clipSummary(content.asString().getValue())
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

    // 会话 ID 进程内计数器：时间戳秒.毫秒在同毫秒内会碰撞
    // （实测 save 与 saveFork 连续调用生成相同 ID，后者覆盖前者）
    private static var idCounter: Int64 = 0

    /**
     * 会话标题（重命名过用 title 字段，否则首条 user 消息摘要）；不存在返回 ""
     */
    public func titleOf(id: String): String {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return ""
        }
        return this.summary(id + ".json")
    }

    /**
     * 重命名会话（写入会话文件根的 title 字段），成功返回 true
     *
     * 原消息历史原样保留——重命名只动展示名，不碰 messages。
     */
    public func rename(id: String, title: String): Bool {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return false
        }
        let name = title.trimAscii()
        if (name.size == 0) {
            return false
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    obj.put("title", JsonString(name))
                    File.writeTo(path, obj.toJsonString().toArray())
                    return true
                case _ => return false
            }
        } catch (e: Exception) {
            eprintln("[cjh] 会话 ${id} 重命名失败: ${e}")
            return false
        }
    }

    /**
     * 删除会话文件，成功返回 true（不存在返回 false）
     *
     * 只删本会话自己；分支子会话保持原样（parent 指向已删 ID 时按根会话展示）。
     */
    public func removeSession(id: String): Bool {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return false
        }
        try {
            remove(path)
            return true
        } catch (e: Exception) {
            eprintln("[cjh] 会话 ${id} 删除失败: ${e}")
            return false
        }
    }

    /**
     * 会话历史残缺度（0 = 健康；>0 表示需要修复的处数）
     *
     * 残缺来源：回合被打断留下孤儿 tool 消息 / 悬空 tool_calls。这类会话
     * 发消息必然被上游判 400，客户端可据此提示用户。
     */
    public func defectCount(id: String): Int64 {
        return historyDefectCount(this.load(id))
    }

    /**
     * 生成新会话 ID（时间戳格式 s<秒>.<毫秒>.<计数器>）
     * 供外部预生成（如工具结果落盘需要会话 ID 时）
     */
    public func newSessionId(): String {
        let now = DateTime.now()
        let ts = now.toUnixTimeStamp()
        // 紧凑：秒.毫秒.计数器（计数器保证进程内唯一）
        let secs = ts.toSeconds()
        let millis = ts.toMilliseconds() - secs * 1000
        SessionStore.idCounter += 1
        return "s" + secs.toString() + "." + millis.toString() + "." + SessionStore.idCounter.toString()
    }
}
