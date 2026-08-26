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

import std.collection.*
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
        let res = ctx.responseBuilder
        res.header("Content-Type", "application/json; charset=utf-8")
        res.header("WWW-Authenticate", "Bearer")
        var err = JsonObject()
        err.put("error", JsonString("unauthorized"))
        err.put("message", JsonString("Missing or invalid auth token"))
        res.body(err.toJsonString().toArray())
        return false
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
        let headers = ctx.request.headers
        match (headers.getFirst("Authorization")) {
            case Some(authHeader) =>
                // Authorization 值格式："Bearer <token>"
                let s = authHeader.toString()
                if (s.size > 7 && s.startsWith("Bearer ")) {
                    return s[7..].toString()
                }
            case None => ()
        }
        // WebSocket 降级：从 URL 查询参数 ?token=... 提取
        let url = ctx.request.url
        match (url.query) {
            case Some(query) =>
                if (query.size > 6 && query.startsWith("token=")) {
                    return query[6..]
                }
            case None => ()
        }
        return ""
    }
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
            println("│  ⚠️  风险:  远程访问未启用鉴权，任何人可调用工具")
            println("│           建议: cjh web --bind ${bindAddr} --token <secret>")
        }
        println("│  TLS:      未配置（HTTPS 跳过）")
        println("╰──────────────────────────────────────────────")
        println()
    }
}
