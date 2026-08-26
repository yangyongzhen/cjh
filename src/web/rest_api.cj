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
import stdx.encoding.json.*
import stdx.net.http.*
import cjcfg.*

/**
 * REST API 处理器：统一处理所有 /api 路由
 */
public class RestApi <: HttpRequestHandler {
    private let config: CjhConfig

    public init(config: CjhConfig) {
        this.config = config
    }

    public func handle(ctx: HttpContext): Unit {
        let path = ctx.request.url.path
        match (path) {
            case "/api/health" => this.handleHealth(ctx)
            case "/api/sessions" => this.handleListSessions(ctx)
            case "/api/models" => this.handleListModels(ctx)
            case "/api/tasks" => this.handleListTasks(ctx)
            case _ => this.handleNotFound(ctx)
        }
    }

    /**
     * GET /api/health → 健康检查 JSON
     */
    private func handleHealth(ctx: HttpContext): Unit {
        var health = JsonObject()
        health.put("status", JsonString("ok"))
        health.put("version", JsonString("1.3.0"))
        health.put("web_port", JsonInt(Int64(this.config.webPort)))
        let body = health.toJsonString()
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
}
