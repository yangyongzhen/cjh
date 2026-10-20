package cjh.web

/**
 * 鉴权中间件 + 启动安全审计日志
 *
 * Step 5（可选）：
 *   - auth_token 鉴权：webAuthToken 非空时，HTTP 请求需携带
 *     Authorization: Bearer <token>，否则返回 401
 *   - 启动安全审计日志：serve() 启动时打印安全配置摘要
 *
 * TLS 配置因 ServerBuilder.tlsConfig API 不确定而跳过（#9 可选）。
 */

import stdx.encoding.json.*
import stdx.net.http.*
import cjcfg.CjhConfig

/**
 * 鉴权检查器
 *
 * 用法：在 HttpRequestHandler.handle(ctx) 开头调用
 *   if (!Auth.check(ctx, config)) { return }
 *
 * webAuthToken 为空时，鉴权跳过（本机访问模式）。
 */
public class Auth {
    /**
     * 检查请求是否通过鉴权
     * @return true=通过（或未启用鉴权），false=未通过（已写 401 响应）
     */
    public static func check(ctx: HttpContext, config: CjhConfig): Bool {
        // 未配置 token，跳过鉴权
        if (config.webAuthToken.size == 0) {
            return true
        }

        // 从 Authorization 头提取 Bearer token
        let token = Auth.extractBearerToken(ctx)
        if (token == config.webAuthToken) {
            return true
        }

        // 鉴权失败：写 401 响应
        Auth.writeUnauthorized(ctx)
        return false
    }

    /**
     * 写 401 未授权响应
     *
     * 状态码必须是 401：只往 body 里塞 error 字段而不设状态码时，HTTP 行仍是 200，
     * 前端 `res.ok` 为真、探活脚本也判成功，鉴权失败会被当成一次正常响应。
     */
    public static func writeUnauthorized(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        res.status(401)
        res.header("Content-Type", "application/json; charset=utf-8")
        res.header("WWW-Authenticate", "Bearer")
        var err = JsonObject()
        err.put("error", JsonString("unauthorized"))
        err.put("message", JsonString("Missing or invalid auth token"))
        res.body(err.toJsonString().toArray())
    }

    /**
     * 从 Authorization 头提取 Bearer token
     *
     * 支持格式：
     *   Authorization: Bearer <token>
     *   ?token=<token>（WebSocket 查询参数，降级支持）
     */
    private static func extractBearerToken(ctx: HttpContext): String {
        // 尝试从 Authorization 头提取
        match (ctx.request.headers.getFirst("Authorization")) {
            case Some(authHeader) =>
                let fromHeader = tokenFromAuthHeader(authHeader.toString())
                if (fromHeader.size > 0) {
                    return fromHeader
                }
            case None => ()
        }
        // WebSocket / 浏览器降级：从 URL 查询参数 ?token=... 提取
        match (ctx.request.url.query) {
            case Some(query) => return tokenFromQuery(query)
            case None => ()
        }
        return ""
    }
}

/**
 * 从 Authorization 头值提取 Bearer token（非 Bearer 格式返回空串）
 */
public func tokenFromAuthHeader(header: String): String {
    if (header.size > 7 && header.startsWith("Bearer ")) {
        return header[7..].toString()
    }
    return ""
}

/**
 * 从查询串提取 token 参数（多参数并存时按键名匹配）
 *
 * 允许多个参数并存（?token=x&foo=1），因此按 & 切分后按键名匹配，
 * 而不是把整个 query 直接当值（那样带第二个参数就永远对不上）。
 */
public func tokenFromQuery(query: String): String {
    for (pair in query.split("&")) {
        if (pair.startsWith("token=")) {
            return pair[6..].toString()
        }
    }
    return ""
}

/**
 * 该路径是否要求鉴权
 *
 * 只有数据面（api 前缀路由）与长连接（ws）要求；静态页面与资源放行——
 * 浏览器顶层导航带不了 Authorization 头，静态页若拦就等于把 UI 锁死。
 */
public func requiresAuthPath(path: String): Bool {
    return path.startsWith("/api/") || path == "/ws"
}

/**
 * 启动安全审计日志
 *
 * 在 WebServer.serve() 启动后调用，打印安全配置摘要。
 */
public class SecurityAudit {
    /**
     * 打印安全审计日志
     */
    public static func logStartup(config: CjhConfig): Unit {
        let bindAddr = config.webBindAddr
        let isRemote = (bindAddr != "127.0.0.1" && bindAddr != "localhost")
        let hasAuth = (config.webAuthToken.size > 0)

        println("╭─── 安全审计日志 ────────────────────────────")
        println("│  绑定地址:  ${bindAddr}")
        println("│  访问范围:  ${if (isRemote) { "远程（局域网/公网）" } else { "本机（127.0.0.1）" }}")
        println("│  鉴权:     ${if (hasAuth) { "已启用（Bearer token）" } else { "未启用" }}")
        if (isRemote && !hasAuth) {
            println("│  ⚠  风险:  远程访问未启用鉴权，任何人可调用工具")
            println("│           建议: cjh web --bind ${bindAddr} --token <secret>")
        }
        println("│  TLS:      未配置（HTTPS 跳过）")
        println("╰──────────────────────────────────────────────")
        println()
    }
}

/**
 * 绑定地址是否属于回环（仅本机可达）
 *
 * 覆盖 127.0.0.0/8、localhost、IPv6 ::1；其余（含 0.0.0.0、局域网 IP、域名）视为对外。
 */
public func isLoopbackBind(addr: String): Bool {
    let a = addr.trimAscii()
    if (a == "localhost" || a == "::1" || a == "[::1]") {
        return true
    }
    if (a == "127.0.0.1") {
        return true
    }
    // 127.0.0.0/8 整段都是回环
    if (a.startsWith("127.")) {
        return true
    }
    return false
}

/**
 * 启动安全策略：非回环绑定 + 无鉴权 token → 返回拒绝原因（空串 = 允许启动）
 *
 * 为什么拒绝而不是只警告：`cjh web` 的接口能读写工作区、跑 shell、动用 LLM 额度，
 * 裸绑 0.0.0.0 等于把整套能力摆在局域网上。警告在实际使用中很容易被日志刷掉，
 * 所以改成硬拒绝，把「对外 + 无鉴权」这个组合变成不可能配置。
 */
public func webBindRejection(bindAddr: String, token: String): String {
    if (isLoopbackBind(bindAddr) || token.size > 0) {
        return ""
    }
    return "拒绝启动：绑定地址 ${bindAddr} 对外可达，但未设置鉴权 token——" +
        "任何人都能通过它读写工作区、执行 shell。\n" +
        "  · 仅本机使用：去掉 --bind（默认 127.0.0.1）\n" +
        "  · 需要局域网访问：cjh web --bind ${bindAddr} --token <your-secret>\n" +
        "  · 绑定地址也可能来自 settings.json 的 web_bind_addr（命令行未传 --bind 时生效），" +
        "改回 127.0.0.1 或同时配 web_auth_token"
}
