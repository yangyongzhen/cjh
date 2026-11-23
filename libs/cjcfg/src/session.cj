package cjcfg

import std.fs.*
import stdx.encoding.json.*
import std.collection.*
import std.time.*
import std.env.*
import cjllm.*

/**
 * 会话级用量快照（持久化到会话文件根的 usage 字段）
 *
 * 不是账单单据，只保留跨回合累计最常用的 6 个数：恢复会话后仍能看到
 * 这轮/历史花了多少 token、跑了几轮工具。字段名与 --mode json/Web done 对齐。
 */
public class SessionUsage {
    public var promptTokens: Int64 = 0
    public var completionTokens: Int64 = 0
    public var cachedTokens: Int64 = 0
    public var rounds: Int64 = 0
    public var tools: Int64 = 0
    public var durationMs: Int64 = 0

    public init() {}

    public init(promptTokens: Int64, completionTokens: Int64, cachedTokens: Int64,
        rounds: Int64, tools: Int64, durationMs: Int64) {
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
        this.cachedTokens = cachedTokens
        this.rounds = rounds
        this.tools = tools
        this.durationMs = durationMs
    }

    /** 是否有可展示的数据（全零视为未记录，不写 usage 字段） */
    public func hasData(): Bool {
        return this.promptTokens > 0 || this.completionTokens > 0 ||
            this.cachedTokens > 0 || this.rounds > 0 || this.tools > 0 ||
            this.durationMs > 0
    }

    public func toJson(): JsonObject {
        var obj = JsonObject()
        obj.put("prompt_tokens", JsonInt(this.promptTokens))
        obj.put("completion_tokens", JsonInt(this.completionTokens))
        obj.put("cached_tokens", JsonInt(this.cachedTokens))
        obj.put("rounds", JsonInt(this.rounds))
        obj.put("tools", JsonInt(this.tools))
        obj.put("duration_ms", JsonInt(this.durationMs))
        return obj
    }
}

/**
 * 会话持久化：agent 消息历史保存/恢复
 *
 * 存储：~/.cjh/sessions/<会话ID>.json
 * 格式：{"id": "...", "created": "...", "cwd": "...", "usage": {...}, "messages": [{role, content, tool_call_id?, name?}, ...]}
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
                                                // internal=true 的新格式提醒：标题不能拿它当首条用户消息
                                                var hidden = false
                                                if (let Some(h) <- mo.get("internal")) {
                                                    match (h.kind()) {
                                                        case JsonKind.JsBool => hidden = h.asBool().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (hidden) {
                                                    continue
                                                }
                                                if (let Some(role) <- mo.get("role") && let Some(content) <- mo.get("content")) {
                                                    match (role.kind()) {
                                                        case JsonKind.JsString =>
                                                            match (content.kind()) {
                                                                case JsonKind.JsString =>
                                                                    if (role.asString().getValue() == "user") {
                                                                        let text = content.asString().getValue()
                                                                        if (ChatMessage.isLegacyInternalNotice(text)) {
                                                                            continue
                                                                        }
                                                                        return this.clipSummary(text)
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
        // 工作区归属：Web/TUI 的会话列表按此过滤，避免在项目 A 看到项目 B 的
        // 上百条历史（用户实锤：890 条混在一起）。旧会话无 cwd 字段，按 legacy 处理。
        try {
            root.put("cwd", JsonString(getWorkingDirectory().toString()))
        } catch (e: Exception) {
            ()
        }
        if (parent.size > 0) {
            root.put("parent", JsonString(parent))
        }
        var msgArr = ArrayList<JsonValue>()
        for (m in messages) {
            if (m.isInternalNotice()) {
                continue
            }
            msgArr.add(m.toSessionJson())
        }
        root.put("messages", JsonArray(msgArr))
        File.writeTo(path, root.toJsonString().toArray())
        return id
    }

    /**
     * 新建会话并写入用量快照，返回会话 ID。
     */
    public func saveWithUsage(messages: ArrayList<ChatMessage>, usage: SessionUsage): String {
        let id = this.newSessionId()
        let _ = this.saveWithIdUsage(id, messages, usage)
        return id
    }

    /**
     * 按指定 ID 覆盖保存消息（保留 created/cwd/title/parent 等根字段）。
     *
     * 恢复会话必须走这里：旧实现无论新会话还是恢复都调 save()，每次都生成
     * 新 ID，导致一次 --resume 就多出一条重复历史（890 条会话的成因之一）。
     * 文件不存在时创建（Web 侧会话 ID 是预生成的）。
     */
    public func saveWithId(id: String, messages: ArrayList<ChatMessage>): Bool {
        return this.saveWithIdUsage(id, messages, SessionUsage())
    }

    /**
     * 按指定 ID 覆盖保存消息 + 用量；usage 全零时保留文件里已有的 usage。
     */
    public func saveWithIdUsage(id: String, messages: ArrayList<ChatMessage>,
        usage: SessionUsage): Bool {
        if (id.size == 0) {
            return false
        }
        this.ensureDir()
        let path = this.dir + "/" + id + ".json"
        var root = JsonObject()
        if (exists(path)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
                match (json.kind()) {
                    case JsonKind.JsObject => root = json.asObject()
                    case _ => ()
                }
            } catch (e: Exception) {
                // 损坏文件按新文件重写（消息仍以当前内存历史为准）
            }
        }
        root.put("id", JsonString(id))
        if (root.get("created").isNone()) {
            root.put("created", JsonString(DateTime.now().toString()))
        }
        if (root.get("cwd").isNone()) {
            try {
                root.put("cwd", JsonString(getWorkingDirectory().toString()))
            } catch (e: Exception) {
                ()
            }
        }
        var msgArr = ArrayList<JsonValue>()
        for (m in messages) {
            if (m.isInternalNotice()) {
                continue
            }
            msgArr.add(m.toSessionJson())
        }
        root.put("messages", JsonArray(msgArr))
        if (usage.hasData()) {
            // 会话级累计：恢复后继续对话不会把总用量清零
            var merged = this.parseUsage(root)
            merged.promptTokens += usage.promptTokens
            merged.completionTokens += usage.completionTokens
            merged.cachedTokens += usage.cachedTokens
            merged.rounds += usage.rounds
            merged.tools += usage.tools
            merged.durationMs += usage.durationMs
            root.put("usage", merged.toJson())
        }
        try {
            File.writeTo(path, root.toJsonString().toArray())
            return true
        } catch (e: Exception) {
            eprintln("[cjh] 会话 ${id} 保存失败: ${e}")
            return false
        }
    }

    /**
     * 读取会话用量快照；无 usage 字段/文件不存在返回 None。
     */
    public func usageOf(id: String): ?SessionUsage {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return None
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    // 缺 usage 字段 = 未记录，返回 None（不伪造成全零）
                    if (obj.get("usage").isNone()) {
                        return None
                    }
                    return Some(this.parseUsage(obj))
                case _ => ()
            }
        } catch (e: Exception) {
            ()
        }
        return None
    }

    /**
     * 解析会话根对象的 usage 字段（缺失/类型不符按全零）
     */
    private func parseUsage(root: JsonObject): SessionUsage {
        var usage = SessionUsage()
        if (let Some(u) <- root.get("usage")) {
            match (u.kind()) {
                case JsonKind.JsObject =>
                    let uo = u.asObject()
                    usage.promptTokens = this.intField(uo, "prompt_tokens")
                    usage.completionTokens = this.intField(uo, "completion_tokens")
                    usage.cachedTokens = this.intField(uo, "cached_tokens")
                    usage.rounds = this.intField(uo, "rounds")
                    usage.tools = this.intField(uo, "tools")
                    usage.durationMs = this.intField(uo, "duration_ms")
                case _ => ()
            }
        }
        return usage
    }

    private func intField(obj: JsonObject, key: String): Int64 {
        if (let Some(v) <- obj.get(key)) {
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => ()
            }
        }
        return 0
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
     * 会话所属工作区（保存时的 cwd）；旧会话/损坏返回 ""。
     */
    public func cwdOf(id: String): String {
        let path = this.dir + "/" + id + ".json"
        if (!exists(path)) {
            return ""
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(c) <- obj.get("cwd")) {
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
     * 按工作区列出会话（按时间倒序）：(id, 摘要)。
     *
     * includeLegacy=true 时包含没有 cwd 字段的旧会话（升级后不丢历史）；
     * 新会话一律带 cwd，因此不会再把其它项目的会话混进来。
     */
    public func listScoped(cwd: String, includeLegacy: Bool): ArrayList<(String, String)> {
        var result = ArrayList<(String, String)>()
        let all = this.list()
        let normalized = if (cwd.size > 0) { cwd } else { "" }
        for ((id, summary) in all) {
            let owner = this.cwdOf(id)
            if (owner == normalized || (includeLegacy && owner.size == 0)) {
                result.add((id, summary))
            }
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
                var hidden = false
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
                if (let Some(h) <- obj.get("internal")) {
                    match (h.kind()) {
                        case JsonKind.JsBool => hidden = h.asBool().getValue()
                        case _ => ()
                    }
                }
                // assistant 的 tool_calls 必须恢复：只留 tool 结果会让配对断裂，
                // 发上游前只能丢弃，模型重启后丢失上一轮查过什么。
                var toolCalls = ArrayList<ToolCall>()
                if (let Some(tcs) <- obj.get("tool_calls")) {
                    match (tcs.kind()) {
                        case JsonKind.JsArray =>
                            let arr = tcs.asArray()
                            for (i in 0..arr.size()) {
                                if (let Some(tv) <- arr.get(i)) {
                                    match (parseToolCall(tv)) {
                                        case Some(tc) => toolCalls.add(tc)
                                        case None => ()
                                    }
                                }
                            }
                        case _ => ()
                    }
                }
                if (toolId.size > 0) {
                    return ChatMessage(role, content, toolId, name)
                }
                if (toolCalls.size > 0) {
                    return ChatMessage(role, content, toolCalls)
                }
                return ChatMessage(role, content, hidden)
            case _ => return ChatMessage("user", "")
        }
    }

    /** 解析持久化的 OpenAI 工具调用；字段残缺返回 None，不伪造参数。 */
    private func parseToolCall(v: JsonValue): Option<ToolCall> {
        match (v.kind()) {
            case JsonKind.JsObject =>
                let obj = v.asObject()
                var id = ""
                var name = ""
                var args = JsonObject()
                if (let Some(i) <- obj.get("id")) {
                    match (i.kind()) {
                        case JsonKind.JsString => id = i.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(f) <- obj.get("function")) {
                    match (f.kind()) {
                        case JsonKind.JsObject =>
                            let fn = f.asObject()
                            if (let Some(n) <- fn.get("name")) {
                                match (n.kind()) {
                                    case JsonKind.JsString => name = n.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(a) <- fn.get("arguments")) {
                                match (a.kind()) {
                                    case JsonKind.JsString =>
                                        try {
                                            let parsed = JsonValue.fromStr(a.asString().getValue())
                                            match (parsed.kind()) {
                                                case JsonKind.JsObject => args = parsed.asObject()
                                                case _ => ()
                                            }
                                        } catch (e: Exception) {
                                            // 参数损坏：保留调用名与 id，参数按空对象恢复
                                        }
                                    case JsonKind.JsObject => args = a.asObject()
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                }
                if (id.size == 0 || name.size == 0) {
                    return None
                }
                return Some(ToolCall(id, name, args))
            case _ => return None
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
