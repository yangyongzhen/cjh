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
            .maxRequestBodySize(this.config.webMaxRequestSize)
            .build()

        println("╭─── cjh · Web Server ────────────────────────")
        println("│  监听地址:  http://${bindAddr}:${port}")
        println("│  鉴权:     ${if (this.config.webAuthToken.size > 0) { "已启用" } else { "未启用（本机访问）" }}")
        println("│  浏览器访问上述地址开始对话")
        println("╰──────────────────────────────────────────────")
        println("  按 Ctrl+C 停止服务器")
        println()

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
    private let routes: HashMap<String, HttpRequestHandler> = HashMap<String, HttpRequestHandler>()

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
        // 注册路由（WebHandler 统一处理 HTTP，WsHandler 处理 WebSocket）
        this.routes.add("/", WebHandler(this.config))
        this.routes.add("/assets/app.js", WebHandler(this.config))
        this.routes.add("/assets/styles.css", WebHandler(this.config))
        this.routes.add("/api/health", WebHandler(this.config))
        // WebSocket 端点
        this.routes.add("/ws", WsHandler(this.config, this.provider, this.registry))
    }

    /**
     * 分发请求：按 path 查路由表，未找到返回 404
     */
    public func distribute(path: String): HttpRequestHandler {
        // 精确匹配
        match (this.routes.get(path)) {
            case Some(handler) => return handler
            case None => ()
        }
        // 前缀匹配：/ws 开头（含 /ws?token=... 等变体）→ WsHandler
        if (path.startsWith("/ws")) {
            match (this.routes.get("/ws")) {
                case Some(handler) => return handler
                case None => ()
            }
        }
        return NotFoundHandler()
    }

    /**
     * 注册请求处理器（接口契约要求）
     */
    public func register(path: String, handler: HttpRequestHandler): Unit {
        this.routes.add(path, handler)
    }

    /**
     * 注册请求处理器（lambda 重载，接口契约要求）
     */
    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        this.routes.add(path, FuncHandler(handler))
    }
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
        health.put("version", JsonString("1.2.3"))
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
