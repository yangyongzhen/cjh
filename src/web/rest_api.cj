package cjh.web

/**
 * REST API 处理器
 *
 * 端点：
 *   GET  /api/health          → 健康检查
 *   GET  /api/sessions        → 列出历史会话
 *   GET  /api/models          → 列出可用模型
 *   POST /api/model/switch    → 切换模型
 *   GET  /api/tasks           → 获取当前任务列表
 *
 * 架构参考：docs/Web支持实现方案.md § 六、REST API
 */

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjcfg.*
import cjllm.*
import cjutil.*
import cjh.tools.*

/**
 * REST API 处理器：统一处理所有 /api 路由
 */
public class RestApi <: HttpRequestHandler {
    private let config: CjhConfig
    // 工具注册表（工作区切换时重置持久 bash 会话 cwd）
    private let registry: ?ToolRegistry

    public init(config: CjhConfig) {
        this.config = config
        this.registry = None
    }

    public init(config: CjhConfig, registry: ToolRegistry) {
        this.config = config
        this.registry = Some(registry)
    }

    public func handle(ctx: HttpContext): Unit {
        // 鉴权中间件：配置了 token 时 /api/* 也必须携带（原实现只给 WebHandler 挂了鉴权，
        // REST 侧裸奔——设了 token 也等于没设）
        if (!Auth.check(ctx, this.config)) {
            return
        }
        let path = ctx.request.url.path
        // 会话项路由：/api/sessions/{id}（重命名 / 删除 / 健康详情）
        if (path.startsWith("/api/sessions/")) {
            this.handleSessionItem(ctx, path[14..])
            return
        }
        match (path) {
            case "/api/health" => this.handleHealth(ctx)
            case "/api/capabilities" => this.handleCapabilities(ctx)
            case "/api/sessions" => this.handleListSessions(ctx)
            case "/api/models" => this.handleListModels(ctx)
            case "/api/tasks" => this.handleListTasks(ctx)
            case "/api/skills" => this.handleListSkills(ctx)
            case "/api/mcp" => this.handleListMcp(ctx)
            case "/api/settings" => this.handleSettings(ctx)
            case "/api/workspaces" => this.handleWorkspaces(ctx)
            case "/api/workspaces/switch" => this.handleWorkspaceSwitch(ctx)
            case "/api/fs/list" => this.handleFsList(ctx)
            case _ => this.handleNotFound(ctx)
        }
    }

    /**
     * GET /api/health → 健康检查 JSON
     */
    private func handleHealth(ctx: HttpContext): Unit {
        var health = JsonObject()
        health.put("status", JsonString("ok"))
        health.put("version", JsonString(CJH_WEB_VERSION))
        health.put("web_port", JsonInt(Int64(this.config.webPort)))
        let body = health.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * GET /api/capabilities → 服务端能力自述
     *
     * 客户端据 ws_in / ws_out / features 决定怎么说话（哪些帧可以发、哪些事件该处理），
     * 不必靠 try/catch 试错。清单与推导逻辑见 src/web/capabilities.cj，
     * 且由单测断言"清单里每一项都真的存在"。
     */
    private func handleCapabilities(ctx: HttpContext): Unit {
        let body = capabilitiesJson().toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * GET /api/sessions → 列出历史会话
     *
     * 返回格式：
     * { "sessions": [ {"id": "s1787665309", "title": "hello", "created_at": 1787665309}, ... ] }
     */
    private func handleListSessions(ctx: HttpContext): Unit {
        let store = SessionStore(this.config.sessionsDir)
        let sessions = store.list()

        var sessionsArr = JsonArray()
        for (i in 0..sessions.size) {
            let (id, title) = sessions[i]
            var sessionObj = JsonObject()
            sessionObj.put("id", JsonString(id))
            sessionObj.put("title", JsonString(title))
            // 从 ID 提取时间戳（格式 s<timestamp>）
            var timestamp: Int64 = 0
            if (id.startsWith("s") && id.size > 1) {
                try {
                    timestamp = Int64.parse(id[1..])
                } catch (e: Exception) {}
            }
            sessionObj.put("created_at", JsonInt(timestamp))
            // 会话健康：被打断的回合会留下孤儿 tool 消息，历史残缺的会话发消息必 400。
            // 提前标记，客户端可在恢复前提示「建议修复/删除」而不是撞上 400 才知道。
            let defects = store.defectCount(id)
            sessionObj.put("corrupted", JsonBool(defects > 0))
            sessionObj.put("defects", JsonInt(defects))
            sessionsArr.add(sessionObj)
        }

        var obj = JsonObject()
        obj.put("sessions", sessionsArr)
        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * /api/sessions/{id} → 单个会话
     *
     *   GET    → {id, title, created_at, messages, corrupted, defects}
     *   PATCH  → 重命名（body: {"title": "新标题"}）
     *   DELETE → 删除该会话文件
     *
     * 会话 ID 只允许 字母/数字/._-（见 isValidSessionId），杜绝 ../ 之类的路径穿越。
     */
    private func handleSessionItem(ctx: HttpContext, id: String): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        let method = ctx.request.method
        if (!isValidSessionId(id)) {
            res.body(apiError("invalid session id: 只允许字母/数字/./_/-").toArray())
            return
        }
        let store = SessionStore(this.config.sessionsDir)
        match (method) {
            case "GET" =>
                let msgs = store.load(id)
                var obj = JsonObject()
                obj.put("id", JsonString(id))
                obj.put("title", JsonString(store.titleOf(id)))
                obj.put("messages", JsonInt(Int64(msgs.size)))
                let defects = historyDefectCount(msgs)
                obj.put("corrupted", JsonBool(defects > 0))
                obj.put("defects", JsonInt(defects))
                res.body(obj.toJsonString().toArray())
            case "PATCH" =>
                let bodyStr = readBody(ctx)
                var title = ""
                try {
                    let parsed = JsonValue.fromStr(bodyStr)
                    if (isObj(parsed)) {
                        if (let Some(v) <- parsed.asObject().get("title")) {
                            if (isStr(v)) {
                                title = v.asString().getValue().trimAscii()
                            }
                        }
                    }
                } catch (e: Exception) {
                    res.body(apiError("JSON 解析失败: ${e}").toArray())
                    return
                }
                if (title.size == 0) {
                    res.body(apiError("缺少 title 或 title 为空").toArray())
                    return
                }
                if (!store.rename(id, title)) {
                    res.body(apiError("会话不存在: ${id}").toArray())
                    return
                }
                var ok = JsonObject()
                ok.put("ok", JsonBool(true))
                ok.put("id", JsonString(id))
                ok.put("title", JsonString(title))
                res.body(ok.toJsonString().toArray())
            case "DELETE" =>
                if (!store.removeSession(id)) {
                    res.body(apiError("会话不存在: ${id}").toArray())
                    return
                }
                var ok = JsonObject()
                ok.put("ok", JsonBool(true))
                ok.put("id", JsonString(id))
                res.body(ok.toJsonString().toArray())
            case _ => this.handleNotFound(ctx)
        }
    }

    /**
     * GET /api/models → 列出可用模型
     *
     * 返回格式：
     * { "current": "deepseek-v4-flash", "models": [{"id": "deepseek-v4-flash", "name": "DeepSeek V4 Flash"}, ...] }
     */
    private func handleListModels(ctx: HttpContext): Unit {
        var modelsArr = JsonArray()
        // 从配置的 models 列表构造
        for (i in 0..this.config.models.size) {
            let modelEntry = this.config.models[i]
            var modelObj = JsonObject()
            modelObj.put("id", JsonString(modelEntry.id))
            modelObj.put("name", JsonString(modelEntry.name))
            // ModelEntry 没有 provider 字段，用 baseUrl 表示
            modelObj.put("baseUrl", JsonString(modelEntry.baseUrl))
            modelsArr.add(modelObj)
        }

        var obj = JsonObject()
        obj.put("current", JsonString(this.config.model))
        obj.put("models", modelsArr)
        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * GET /api/tasks → 获取当前任务列表
     *
     * 返回格式：
     * { "tasks": [{"id": 1, "content": "...", "status": "doing"}, ...] }
     */
    private func handleListTasks(ctx: HttpContext): Unit {
        // 当前无全局任务管理器，返回空列表
        // 后续接入 Agent.getTodos() 时填充
        var tasksArr = JsonArray()
        var obj = JsonObject()
        obj.put("tasks", tasksArr)
        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * 未知路由 → 404
     */
    private func handleNotFound(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        var err = JsonObject()
        err.put("error", JsonString("Not Found"))
        res.body(err.toJsonString().toArray())
    }

    /**
     * GET /api/skills → 列出技能
     *
     * 扫描 skillsDir 下的 *.md 文件，解析 frontmatter（name/description/tools）。
     * 返回格式：
     * { "skills": [{"name":"git", "description":"...", "tools": 2, "enabled": true}, ...] }
     */
    private func handleListSkills(ctx: HttpContext): Unit {
        var skillsArr = JsonArray()
        if (exists(this.config.skillsDir)) {
            let files = ArrayList<String>()
            Directory.walk(this.config.skillsDir, { fi =>
                if (fi.name.endsWith(".md")) {
                    files.add(fi.name)
                }
                return true
            })
            for (f in files) {
                try {
                    let content = safeFromUtf8(File.readFrom(this.config.skillsDir + "/" + f))
                    var name = f[0..f.size - 3]
                    var desc = ""
                    var toolCount: Int64 = 0
                    if (content.startsWith("---")) {
                        let endFm = content.indexOf("\n---")
                        if (endFm.isSome()) {
                            let fm = content[3..endFm.getOrThrow()]
                            // 简单 frontmatter 解析（key: value 逐行）
                            for (line in fm.split("\n", -1)) {
                                let trimmed = line.trimAscii()
                                if (trimmed.startsWith("name:")) {
                                    let v = trimmed[5..].trimAscii()
                                    if (v.size > 0) { name = v }
                                } else if (trimmed.startsWith("description:")) {
                                    let v = trimmed[12..].trimAscii()
                                    if (v.size > 0) { desc = v }
                                } else if (trimmed.startsWith("tools:")) {
                                    // 统计 tools JSON 数组里的对象数
                                    let v = trimmed[6..].trimAscii()
                                    toolCount = countJsonObjects(v)
                                }
                            }
                        }
                    }
                    let enabled = isSkillEnabled(name, this.config.enabledSkills)
                    var skillObj = JsonObject()
                    skillObj.put("name", JsonString(name))
                    skillObj.put("description", JsonString(desc))
                    skillObj.put("tools", JsonInt(toolCount))
                    skillObj.put("enabled", JsonBool(enabled))
                    skillsArr.add(skillObj)
                } catch (e: Exception) {}
            }
        }
        var obj = JsonObject()
        obj.put("skills", skillsArr)
        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * GET /api/mcp → 列出 MCP 服务器配置
     *
     * 返回格式：
     * { "servers": [{"name":"...", "transport":"stdio", "command":"...", "url":"...", "connected": false}, ...] }
     */
    private func handleListMcp(ctx: HttpContext): Unit {
        var serversArr = JsonArray()
        for (i in 0..this.config.mcpServers.size) {
            let s = this.config.mcpServers[i]
            var serverObj = JsonObject()
            serverObj.put("name", JsonString(s.name))
            serverObj.put("transport", JsonString(s.transport))
            serverObj.put("command", JsonString(s.command))
            serverObj.put("url", JsonString(s.url))
            // connected 状态需 McpManager 查询；web 模式暂未持有 McpManager，返回 false
            serverObj.put("connected", JsonBool(false))
            serversArr.add(serverObj)
        }
        var obj = JsonObject()
        obj.put("servers", serversArr)
        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * GET/POST /api/settings → 读取/写入 settings.json
     *
     * GET 返回当前配置的可编辑字段（敏感字段如 apiKey 脱敏）。
     * POST 接收部分字段更新，写回 settings.json。
     */
    private func handleSettings(ctx: HttpContext): Unit {
        let method = ctx.request.method
        if (method == "GET") {
            this.handleGetSettings(ctx)
        } else if (method == "POST") {
            this.handlePostSettings(ctx)
        } else {
            this.handleNotFound(ctx)
        }
    }

    /**
     * GET /api/settings → 返回可编辑配置字段
     */
    private func handleGetSettings(ctx: HttpContext): Unit {
        var obj = JsonObject()
        // Provider 端点
        obj.put("baseUrl", JsonString(this.config.baseUrl))
        obj.put("model", JsonString(this.config.model))
        obj.put("apiKey", JsonString(maskApiKey(this.config.apiKey)))
        // 行为参数
        obj.put("maxIterations", JsonInt(this.config.maxIterations))
        obj.put("systemPrompt", JsonString(this.config.systemPrompt))
        obj.put("temperature", JsonFloat(this.config.temperature))
        obj.put("maxTokens", JsonInt(this.config.maxTokens))
        obj.put("compactThreshold", JsonInt(this.config.compactThreshold))
        obj.put("compactKeep", JsonInt(this.config.compactKeep))
        obj.put("toolResultMaxChars", JsonInt(this.config.toolResultMaxChars))
        obj.put("theme", JsonString(this.config.theme))
        // 启用列表
        obj.put("enabledSkills", jsonArrFromStrings(this.config.enabledSkills))
        obj.put("enabledPlugins", jsonArrFromStrings(this.config.enabledPlugins))
        // Web 配置
        obj.put("webPort", JsonInt(Int64(this.config.webPort)))
        obj.put("webBindAddr", JsonString(this.config.webBindAddr))
        obj.put("webAuthToken", JsonString(this.config.webAuthToken))
        // web search
        obj.put("webSearchEnabled", JsonBool(this.config.webSearchEnabled))
        obj.put("webSearchProvider", JsonString(this.config.webSearchProvider))
        obj.put("webSearchMaxResults", JsonInt(this.config.webSearchMaxResults))
        obj.put("webFetchEnabled", JsonBool(this.config.webFetchEnabled))
        obj.put("webFetchMaxChars", JsonInt(this.config.webFetchMaxChars))
        // MCP 服务器（数组形态；env 值脱敏，避免密钥回显）
        obj.put("mcpServers", mcpServersToJsonArray(this.config.mcpServers, true))

        let body = obj.toJsonString()
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.body(body.toArray())
    }

    /**
     * POST /api/settings → 更新配置字段，写回 settings.json
     *
     * 请求体：JSON 对象，仅含要更新的字段。
     * 响应：{ "ok": true } 或 { "ok": false, "error": "..." }
     */
    private func handlePostSettings(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        // 读取请求体
        var bodyBytes = ArrayList<UInt8>()
        try {
            let stream = ctx.request.body
            var buf = Array<Byte>(4096, repeat: 0)
            while (true) {
                let n = stream.read(buf)
                if (n <= 0) { break }
                for (i in 0..n) {
                    bodyBytes.add(UInt8(buf[i]))
                }
            }
        } catch (e: Exception) {
            var err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("error", JsonString("读取请求体失败: ${e}"))
            res.body(err.toJsonString().toArray())
            return
        }
        var bodyArr = Array<UInt8>(bodyBytes.size, repeat: 0u8)
        for (i in 0..bodyBytes.size) {
            bodyArr[i] = bodyBytes[i]
        }
        let bodyStr = safeFromUtf8(bodyArr)
        // 解析 JSON
        var updates: JsonObject = JsonObject()
        try {
            let parsed = JsonValue.fromStr(bodyStr)
            var isObj = false
            match (parsed.kind()) {
                case JsonKind.JsObject => isObj = true
                case _ => ()
            }
            if (!isObj) {
                var err = JsonObject()
                err.put("ok", JsonBool(false))
                err.put("error", JsonString("请求体必须是 JSON 对象"))
                res.body(err.toJsonString().toArray())
                return
            }
            updates = parsed.asObject()
        } catch (e: Exception) {
            var err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("error", JsonString("JSON 解析失败: ${e}"))
            res.body(err.toJsonString().toArray())
            return
        }
        // mcpServers：先整体校验，失败即拒绝（不写任何字段，避免落半截配置）
        var mcpUpdate: ?ArrayList<McpServerConfig> = None
        if (let Some(mv) <- updates.get("mcpServers")) {
            let (parsed, perr) = parseMcpServersJson(mv)
            if (perr.size > 0) {
                var errObj = JsonObject()
                errObj.put("ok", JsonBool(false))
                errObj.put("error", JsonString(perr))
                res.body(errObj.toJsonString().toArray())
                return
            }
            // 脱敏占位合并：env 值为 *** 的项沿用磁盘原值，避免"读出来再存回去"抹掉密钥
            mcpUpdate = Some(reconcileMaskedEnv(parsed, this.config.mcpServers))
        }
        // 应用更新到 config
        applySettingsUpdate(updates)
        match (mcpUpdate) {
            case Some(l) => this.config.replaceMcpServers(l)
            case None => ()
        }
        // 保存到 settings.json
        try {
            this.config.saveAll()
            var ok = JsonObject()
            ok.put("ok", JsonBool(true))
            if (mcpUpdate.isSome()) {
                ok.put("note", JsonString("MCP 配置已保存；新增/修改的服务器需重启 cjh 后建立连接"))
            }
            res.body(ok.toJsonString().toArray())
        } catch (e: Exception) {
            var err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("error", JsonString("保存失败: ${e}"))
            res.body(err.toJsonString().toArray())
        }
    }

    /**
     * 将 JSON 更新应用到 config 字段（仅已知字段，忽略未知键）
     */
    private func applySettingsUpdate(updates: JsonObject): Unit {
        let fields = updates.getFields()
        for ((k, v) in fields) {
            match (k) {
                case "baseUrl" => if (isStr(v)) { this.config.baseUrl = v.asString().getValue() }
                case "model" => if (isStr(v)) { this.config.model = v.asString().getValue() }
                case "apiKey" => if (isStr(v)) {
                    let val = v.asString().getValue()
                    // 空字符串或脱敏占位符 → 不更新
                    if (val.size > 0 && !val.contains("***")) { this.config.apiKey = val }
                }
                case "maxIterations" => if (isInt(v)) { this.config.maxIterations = v.asInt().getValue() }
                case "systemPrompt" => if (isStr(v)) { this.config.systemPrompt = v.asString().getValue() }
                case "temperature" =>
                    if (isFloat(v)) { this.config.temperature = v.asFloat().getValue() }
                    else if (isInt(v)) { this.config.temperature = Float64(v.asInt().getValue()) }
                case "maxTokens" => if (isInt(v)) { this.config.maxTokens = v.asInt().getValue() }
                case "compactThreshold" => if (isInt(v)) { this.config.compactThreshold = v.asInt().getValue() }
                case "compactKeep" => if (isInt(v)) { this.config.compactKeep = v.asInt().getValue() }
                case "toolResultMaxChars" => if (isInt(v)) { this.config.toolResultMaxChars = v.asInt().getValue() }
                case "theme" => if (isStr(v)) { this.config.theme = v.asString().getValue() }
                case "webPort" => if (isInt(v)) { this.config.webPort = UInt16(v.asInt().getValue()) }
                case "webBindAddr" => if (isStr(v)) { this.config.webBindAddr = v.asString().getValue() }
                case "webAuthToken" => if (isStr(v)) { this.config.webAuthToken = v.asString().getValue() }
                case "webSearchEnabled" => if (isBool(v)) { this.config.webSearchEnabled = v.asBool().getValue() }
                case "webSearchProvider" => if (isStr(v)) { this.config.webSearchProvider = v.asString().getValue() }
                case "webSearchMaxResults" => if (isInt(v)) { this.config.webSearchMaxResults = v.asInt().getValue() }
                case "webFetchEnabled" => if (isBool(v)) { this.config.webFetchEnabled = v.asBool().getValue() }
                case "webFetchMaxChars" => if (isInt(v)) { this.config.webFetchMaxChars = v.asInt().getValue() }
                case _ => ()  // 忽略未知字段
            }
        }
    }

    /**
     * GET /api/workspaces → 列出工作区（按最近访问倒序）
     * POST /api/workspaces → 添加/更新工作区（body: {path, name?}）
     * DELETE /api/workspaces → 删除工作区（body: {path}）
     */
    private func handleWorkspaces(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        let mgr = WorkspaceManager(this.config.configDir)
        let method = ctx.request.method
        if (method == "GET") {
            let list = mgr.list()
            var arr = JsonArray()
            for (i in 0..list.size) {
                let w = list[i]
                var obj = JsonObject()
                obj.put("path", JsonString(w.path))
                obj.put("name", JsonString(w.name))
                obj.put("lastAccess", JsonInt(w.lastAccess))
                arr.add(obj)
            }
            var root = JsonObject()
            root.put("workspaces", arr)
            res.body(root.toJsonString().toArray())
        } else if (method == "POST") {
            // 读取请求体
            let bodyStr = readBody(ctx)
            if (bodyStr.size == 0) {
                res.body("{\"ok\":false,\"error\":\"empty body\"}".toArray())
                return
            }
            try {
                let parsed = JsonValue.fromStr(bodyStr)
                if (!isObj(parsed)) {
                    res.body("{\"ok\":false,\"error\":\"body must be object\"}".toArray())
                    return
                }
                let obj = parsed.asObject()
                var path = ""
                var name = ""
                if (let Some(v) <- obj.get("path")) {
                    if (isStr(v)) { path = v.asString().getValue() }
                }
                if (let Some(v) <- obj.get("name")) {
                    if (isStr(v)) { name = v.asString().getValue() }
                }
                var create = false
                if (let Some(cv) <- obj.get("create")) {
                    match (cv.kind()) {
                        case JsonKind.JsBool => create = cv.asBool().getValue()
                        case _ => ()
                    }
                }
                if (path.size == 0) {
                    res.body("{\"ok\":false,\"error\":\"path required\"}".toArray())
                    return
                }
                // 目录不存在时：create=true 递归新建；create=false 明确拒绝（不登记死路径）
                let (pathOk, pathErr) = ensureWorkspaceDir(path, create)
                if (!pathOk) {
                    var errObj = JsonObject()
                    errObj.put("ok", JsonBool(false))
                    errObj.put("error", JsonString(pathErr))
                    res.body(errObj.toJsonString().toArray())
                    return
                }
                mgr.add(path, name)
                mgr.save()
                res.body("{\"ok\":true}".toArray())
            } catch (e: Exception) {
                res.body("{\"ok\":false,\"error\":\"parse failed\"}".toArray())
            }
        } else if (method == "DELETE") {
            let bodyStr = readBody(ctx)
            if (bodyStr.size == 0) {
                res.body("{\"ok\":false,\"error\":\"empty body\"}".toArray())
                return
            }
            try {
                let parsed = JsonValue.fromStr(bodyStr)
                if (!isObj(parsed)) {
                    res.body("{\"ok\":false,\"error\":\"body must be object\"}".toArray())
                    return
                }
                let obj = parsed.asObject()
                var path = ""
                if (let Some(v) <- obj.get("path")) {
                    if (isStr(v)) { path = v.asString().getValue() }
                }
                if (path.size == 0) {
                    res.body("{\"ok\":false,\"error\":\"path required\"}".toArray())
                    return
                }
                let removed = mgr.remove(path)
                if (removed) {
                    mgr.save()
                    res.body("{\"ok\":true}".toArray())
                } else {
                    res.body("{\"ok\":false,\"error\":\"not found\"}".toArray())
                }
            } catch (e: Exception) {
                res.body("{\"ok\":false,\"error\":\"parse failed\"}".toArray())
            }
        } else {
            res.body("{\"error\":\"method not allowed\"}".toArray())
        }
    }

    /**
     * POST /api/workspaces/switch → 切换工作区（真正生效）
     *
     * body: {path}。执行：
     * 1. chdir 切换进程 cwd（后续相对路径工具立即生效）
     * 2. 更新工作区 lastAccess（最近访问排序）
     * 3. 重置持久 bash 会话（其 cwd 独立于进程 chdir）
     */
    private func handleWorkspaceSwitch(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        let bodyStr = readBody(ctx)
        if (bodyStr.size == 0) {
            res.body("{\"ok\":false,\"error\":\"empty body\"}".toArray())
            return
        }
        var path = ""
        try {
            let parsed = JsonValue.fromStr(bodyStr)
            if (!isObj(parsed)) {
                res.body("{\"ok\":false,\"error\":\"body must be object\"}".toArray())
                return
            }
            let obj = parsed.asObject()
            if (let Some(v) <- obj.get("path")) {
                if (isStr(v)) { path = v.asString().getValue() }
            }
        } catch (e: Exception) {
            res.body("{\"ok\":false,\"error\":\"parse failed\"}".toArray())
            return
        }
        if (path.size == 0 || !exists(path) || FileInfo(path).isDirectory() == false) {
            res.body("{\"ok\":false,\"error\":\"invalid path: ${path}\"}".toArray())
            return
        }
        // 1. chdir 切换进程 cwd
        if (!EnvFfi.changeWorkingDirectory(path)) {
            res.body("{\"ok\":false,\"error\":\"chdir failed: ${path}\"}".toArray())
            return
        }
        // 2. 更新工作区访问时间
        let mgr = WorkspaceManager(this.config.configDir)
        mgr.add(path, "")
        mgr.touch(path)
        mgr.save()
        // 3. 重置持久 bash 会话（cwd 独立于进程 chdir）
        match (this.registry) {
            case Some(r) =>
                match (r.getTool("bash")) {
                    case Some(t: BashTool) => t.resetSession()
                    case _ => ()
                }
            case None => ()
        }
        res.body("{\"ok\":true}".toArray())
    }

    /**
     * GET /api/fs/list?path=/xxx → 列出目录（供前端工作区目录选择器）
     *
     * 返回：{ "path": "/xxx", "dirs": ["a","b"], "files": ["f.txt"] }
     * 每项含绝对路径：dirs 返回 {name, path}，files 返回 {name, path}
     */
    private func handleFsList(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        // 解析 query 参数 path（默认当前 cwd）
        var dirPath = getWorkingDirectory().toString()
        let queryOpt = ctx.request.url.query
        if (queryOpt.isSome()) {
            let query = queryOpt.getOrThrow()
            if (query.contains("path=")) {
                let idx = query.indexOf("path=")
                if (idx.isSome()) {
                    dirPath = query[(idx.getOrThrow() + 5)..query.size]
                }
            }
        }
        if (!exists(dirPath) || FileInfo(dirPath).isDirectory() == false) {
            var err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("error", JsonString("not a directory: ${dirPath}"))
            res.body(err.toJsonString().toArray())
            return
        }
        let dirsArr = JsonArray()
        let filesArr = JsonArray()
        try {
            Directory.walk(dirPath, { fi =>
                if (fi.name.startsWith(".")) {
                    return true  // 跳过隐藏
                }
                var item = JsonObject()
                item.put("name", JsonString(fi.name))
                item.put("path", JsonString("${fi.path}"))
                if (fi.isDirectory()) {
                    dirsArr.add(item)
                } else {
                    filesArr.add(item)
                }
                return true
            })
        } catch (e: Exception) {
            var err = JsonObject()
            err.put("ok", JsonBool(false))
            err.put("error", JsonString("list failed: ${e}"))
            res.body(err.toJsonString().toArray())
            return
        }
        var obj = JsonObject()
        obj.put("path", JsonString(dirPath))
        obj.put("dirs", dirsArr)
        obj.put("files", filesArr)
        res.body(obj.toJsonString().toArray())
    }

    /**
     * 读取 HTTP 请求体为 String
     */
    private func readBody(ctx: HttpContext): String {
        var bytes = ArrayList<UInt8>()
        try {
            let stream = ctx.request.body
            var buf = Array<Byte>(4096, repeat: 0)
            while (true) {
                let n = stream.read(buf)
                if (n <= 0) { break }
                for (i in 0..n) {
                    bytes.add(UInt8(buf[i]))
                }
            }
        } catch (e: Exception) {
            return ""
        }
        var arr = Array<UInt8>(bytes.size, repeat: 0u8)
        for (i in 0..bytes.size) {
            arr[i] = bytes[i]
        }
        return safeFromUtf8(arr)
    }
}

/**
 * API 辅助函数
 */

/**
 * 会话 ID 合法性：仅字母/数字/./_/-，长度 1..128
 *
 * 会话 ID 会直接拼进文件路径（sessions/<id>.json），必须挡掉 "/" 与 ".."
 * 之类的字符，否则 PATCH/DELETE 就变成任意文件改写/删除。
 */
public func isValidSessionId(id: String): Bool {
    if (id.size == 0 || id.size > 128) {
        return false
    }
    for (i in 0..id.size) {
        let c = id[i]
        let isDigit = (c >= 48u8 && c <= 57u8)
        let isLower = (c >= 97u8 && c <= 122u8)
        let isUpper = (c >= 65u8 && c <= 90u8)
        if (!(isDigit || isLower || isUpper || c == 46u8 || c == 95u8 || c == 45u8)) {
            return false
        }
    }
    return true
}

/**
 * API 错误响应体（{"error": "..."}）
 */
public func apiError(msg: String): String {
    var err = JsonObject()
    err.put("error", JsonString(msg))
    return err.toJsonString()
}

/**
 * JsonKind 判断辅助（仓颉 enum 不能直接 ==）
 */
public func isObj(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsObject => return true
        case _ => ()
    }
    return false
}

public func isStr(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsString => return true
        case _ => ()
    }
    return false
}

public func isInt(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsInt => return true
        case _ => ()
    }
    return false
}

public func isFloat(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsFloat => return true
        case _ => ()
    }
    return false
}

public func isBool(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsBool => return true
        case _ => ()
    }
    return false
}

/**
 * 统计 JSON 数组字符串里的对象数（技能 tools 字段）
 * 简单实现：数 '{' 的个数（顶层）
 */
public func countJsonObjects(s: String): Int64 {
    var count: Int64 = 0
    var depth: Int64 = 0
    for (i in 0..s.size) {
        let ch = s[i]
        if (ch == UInt8(123)) {  // '{'
            if (depth == 0) { count += 1 }
            depth += 1
        } else if (ch == UInt8(125)) {  // '}'
            depth -= 1
        }
    }
    return count
}

/**
 * 判断技能是否启用（enabled 为空时全部启用）
 */
public func isSkillEnabled(name: String, enabled: ArrayList<String>): Bool {
    if (enabled.size == 0) {
        return true
    }
    for (i in 0..enabled.size) {
        if (enabled[i] == name) {
            return true
        }
    }
    return false
}

/**
 * API Key 脱敏：保留前 4 后 4，中间用 **** 替换
 */
public func maskApiKey(key: String): String {
    if (key.size <= 8) {
        return if (key.size == 0) { "" } else { "****" }
    }
    return key[0..4] + "****" + key[key.size - 4..key.size]
}

/**
 * ArrayList<String> → JsonArray
 */
public func jsonArrFromStrings(list: ArrayList<String>): JsonArray {
    let arr = JsonArray()
    for (i in 0..list.size) {
        arr.add(JsonString(list[i]))
    }
    return arr
}
