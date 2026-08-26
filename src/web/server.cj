package cjh.web

/**
 * Web 服务器：HTTP + WebSocket
 *
 * 入口：cjh web [--port n] [--bind addr] [--token t]
 *
 * 路由：
 *   GET  /            → 聊天界面（index.html）
 *   GET  /assets/app.js, /assets/styles.css → 静态资源
 *   GET  /api/health  → 健康检查
 *   GET  /ws          → WebSocket 升级（流式通信）
 *
 * 架构参考：docs/Web支持实现方案.md
 */

import std.collection.HashMap
import std.console.*
import std.fs.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjcfg.CjhConfig
import cjllm.LlmProvider
import cjh.tools.ToolRegistry

/**
 * Web 服务器主类
 */
public class WebServer {
    private let config: CjhConfig
    private let provider: LlmProvider
    private let registry: ToolRegistry

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
    }

    /**
     * 启动 HTTP 服务器，阻塞直到收到关闭信号
     * @return 退出码（0=正常关闭）
     */
    public func serve(): Int64 {
        let port = this.config.webPort
        let bindAddr = this.config.webBindAddr

        // 构建请求分发器（自定义实现 HttpRequestDistributor 接口）
        let distributor = WebDistributor(this.config, this.provider, this.registry)

        // 构建并启动服务器
        let server = ServerBuilder()
            .addr(bindAddr)
            .port(port)
            .distributor(distributor)
            .build()

        println("╭─── cjh · Web Server ────────────────────────")
        println("│  监听地址:  http://${bindAddr}:${port}")
        println("│  鉴权:     ${if (this.config.webAuthToken.size > 0) { "已启用" } else { "未启用（本机访问）" }}")
        println("│  浏览器访问上述地址开始对话")
        println("╰──────────────────────────────────────────────")
        println("  按 Ctrl+C 停止服务器")
        println()

        // Step 5：启动安全审计日志
        SecurityAudit.logStartup(this.config)

        server.serve()
        return 0
    }
}

/**
 * HTTP 请求分发器：实现 HttpRequestDistributor 接口
 *
 * 用 HashMap<String, HttpRequestHandler> 存储路由表，
 * distribute(path) 查表返回 handler，未找到返回 NotFoundHandler。
 */
public class WebDistributor <: HttpRequestDistributor {
    private let config: CjhConfig
    private let provider: LlmProvider
    private let registry: ToolRegistry
    private let wsHandler: WsHandler
    private let webHandler: WebHandler

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
        // WsHandler 实例（WebSocket 端点）
        this.wsHandler = WsHandler(this.config, this.provider, this.registry)
        // WebHandler 实例（统一 HTTP 处理）
        this.webHandler = WebHandler(this.config)
    }
    /**
     * 分发请求：按 path 查路由表，未找到返回 404
     *
     * 用 match 语句直接分发，避免 HashMap 在 5+ 路由时的注册问题。
     */
    public func distribute(path: String): HttpRequestHandler {
        match (path) {
            case "/" => return this.webHandler
            case "/assets/app.js" => return this.webHandler
            case "/assets/styles.css" => return this.webHandler
            case "/api/health" => return this.webHandler
            case "/ws" => return this.wsHandler
            case _ => return NotFoundHandler()
        }
    }

    /**
     * 注册请求处理器（接口契约要求，当前实现为空操作）
     */
    public func register(path: String, handler: HttpRequestHandler): Unit {}

    /**
     * 注册请求处理器（lambda 重载，接口契约要求，当前实现为空操作）
     */
    public func register(path: String, handler: (HttpContext) -> Unit): Unit {}
}

/**
 * 统一 HTTP 请求处理器：按 URL path 分发到具体处理函数
 */
public class WebHandler <: HttpRequestHandler {
    private let config: CjhConfig

    public init(config: CjhConfig) {
        this.config = config
    }

    public func handle(ctx: HttpContext): Unit {
        // Step 5：auth_token 鉴权中间件
        if (!Auth.check(ctx, this.config)) {
            return
        }
        let path = ctx.request.url.path
        match (path) {
            case "/" => this.handleIndex(ctx)
            case "/assets/app.js" => this.handleStaticJs(ctx)
            case "/assets/styles.css" => this.handleStaticCss(ctx)
            case "/api/health" => this.handleHealth(ctx)
            case _ => this.handleNotFound(ctx)
        }
    }

    /**
     * GET / → 返回聊天界面 HTML
     */
    private func handleIndex(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "text/html; charset=utf-8")
        res.body(StaticAssets.indexHtml.toArray())
    }

    /**
     * GET /assets/app.js → 返回前端 JS
     */
    private func handleStaticJs(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/javascript; charset=utf-8")
        res.body(StaticAssets.appJs.toArray())
    }

    /**
     * GET /assets/styles.css → 返回前端 CSS
     */
    private func handleStaticCss(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "text/css; charset=utf-8")
        res.body(StaticAssets.stylesCss.toArray())
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
     * 未知路由 → 404
     */
    private func handleNotFound(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.header("Content-Type", "text/plain; charset=utf-8")
        res.body("404 Not Found".toArray())
    }
}
