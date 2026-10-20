package cjh.tests

/**
 * Web 启动安全策略 + REST 会话路由参数校验
 *
 * 回归背景（AtomGit issue #5 第 3、4 条）：
 *   - 之前 `--bind 0.0.0.0` 且无 token 只打印警告，照样起服务；
 *   - /api/sessions/{id} 是新增路由，id 会拼进文件路径，必须挡掉路径穿越。
 */

import cjh.web.*
import cjterm.*

@Test
public class WebBindPolicyTest {
    @TestCase
    public func testLoopbackAddresses(): Unit {
        @Assert(isLoopbackBind("127.0.0.1"), true)
        @Assert(isLoopbackBind("127.0.0.5"), true)
        @Assert(isLoopbackBind("localhost"), true)
        @Assert(isLoopbackBind("::1"), true)
        @Assert(isLoopbackBind(" 127.0.0.1 "), true)  // 首尾空白容忍
    }

    @TestCase
    public func testNonLoopbackAddresses(): Unit {
        @Assert(isLoopbackBind("0.0.0.0"), false)
        @Assert(isLoopbackBind("192.168.1.10"), false)
        @Assert(isLoopbackBind("cjh.example.com"), false)
        @Assert(isLoopbackBind(""), false)
    }

    @TestCase
    public func testRemoteBindWithoutTokenRejected(): Unit {
        let msg = webBindRejection("0.0.0.0", "")
        @Assert(msg.size > 0, true)
        @Assert(msg.contains("--token"), true)   // 给出可执行的出路
        // 局域网 IP 同样拒绝
        @Assert(webBindRejection("192.168.1.10", "").size > 0, true)
    }

    @TestCase
    public func testAllowedCombinations(): Unit {
        // 本机绑定：无需 token
        @Assert(webBindRejection("127.0.0.1", ""), "")
        // 对外绑定 + token：允许
        @Assert(webBindRejection("0.0.0.0", "secret"), "")
        @Assert(webBindRejection("192.168.1.10", "secret"), "")
    }
}

@Test
public class SessionIdValidationTest {
    @TestCase
    public func testAcceptsSessionIds(): Unit {
        @Assert(isValidSessionId("s1760000000.123.1"), true)
        @Assert(isValidSessionId("abc_DEF-123"), true)
    }

    @TestCase
    public func testRejectsTraversalAndJunk(): Unit {
        @Assert(isValidSessionId(""), false)
        @Assert(isValidSessionId("../settings"), false)
        @Assert(isValidSessionId("a/b"), false)
        @Assert(isValidSessionId("a b"), false)
        @Assert(isValidSessionId("s1.json"), true)   // 点允许，但会落成 s1.json.json，无害
        @Assert(isValidSessionId("中文"), false)
    }
}

/**
 * 鉴权细节回归（第六十轮）
 *
 * 背景：上一轮给 api 路由与 ws 端点补上鉴权后，两处功能被自己人锁死——
 *   1. 鉴权失败只写 body 错误字段、没设状态码 → HTTP 行仍是 200，前端当成功；
 *   2. 静态页（GET /）也走鉴权 → 浏览器顶层导航带不了 Authorization 头，
 *      配了 token 就再也打不开 UI。
 */
@Test
public class WebAuthTokenTest {
    @TestCase
    public func testTokenFromAuthHeader(): Unit {
        @Assert(tokenFromAuthHeader("Bearer s3cret"), "s3cret")
        @Assert(tokenFromAuthHeader("Basic YWJj"), "")   // 非 Bearer 不认
        @Assert(tokenFromAuthHeader("Bearer"), "")       // 只有前缀不算 token
        @Assert(tokenFromAuthHeader(""), "")
    }

    @TestCase
    public func testTokenFromQuery(): Unit {
        @Assert(tokenFromQuery("token=abc"), "abc")
        // 多参数并存：按键名匹配，而不是把整个 query 当值
        @Assert(tokenFromQuery("token=abc&theme=dark"), "abc")
        @Assert(tokenFromQuery("theme=dark&token=abc"), "abc")
        @Assert(tokenFromQuery("theme=dark"), "")
        @Assert(tokenFromQuery(""), "")
    }

    @TestCase
    public func testRequiresAuthPath(): Unit {
        // 数据面与长连接必须鉴权
        @Assert(requiresAuthPath("/api/health"), true)
        @Assert(requiresAuthPath("/api/sessions/s1"), true)
        @Assert(requiresAuthPath("/ws"), true)
        // 静态页面/资源放行（否则浏览器进不去）
        @Assert(requiresAuthPath("/"), false)
        @Assert(requiresAuthPath("/assets/app.js"), false)
        @Assert(requiresAuthPath("/assets/styles.css"), false)
    }

    @TestCase
    public func testRejectionMentionsConfigSource(): Unit {
        // 用户不传 --bind 时绑定地址来自 settings.json，提示必须指出来源
        let msg = webBindRejection("0.0.0.0", "")
        @Assert(msg.contains("settings.json"), true)
        @Assert(msg.contains("web_bind_addr"), true)
    }
}

/**
 * 前端必须自带 token（服务端一收紧，前端不带就是 200 户挡不住的死路）
 */
@Test
public class WebFrontendAuthTest {
    @TestCase
    public func testAllApiCallsGoThroughApiFetch(): Unit {
        let js = StaticAssets.appJs
        // 所有 /api/ 请求都要走 apiFetch —— 裸 fetch 不会带 Authorization 头
        @Assert(js.contains("fetch('/api/"), false)
        @Assert(js.contains("apiFetch('/api/"), true)
        @Assert(js.contains("Authorization"), true)
        @Assert(js.contains("Bearer "), true)
    }

    @TestCase
    public func testWebSocketCarriesTokenAndTokenIsPickedUp(): Unit {
        let js = StaticAssets.appJs
        // WS 无法自定义头，token 只能走查询参数
        @Assert(js.contains("'/ws' +"), true)
        @Assert(js.contains("takeTokenFromUrl()"), true)
        @Assert(js.contains("cjh-auth-token"), true)
    }
}

/**
 * 版本号一致性守卫
 *
 * 历史坑：/api/health 曾把版本写死 "1.3.0"，一路发到 1.5.x 都还在报 1.3.0。
 * 现在版本收成 cjh.web 的 CJH_WEB_VERSION，与 cjterm 的 Logo.VERSION 必须同步，
 * 发版改漏一个就会在门禁上红。
 */
@Test
public class WebVersionSyncTest {
    @TestCase
    public func testWebVersionMatchesLogoVersion(): Unit {
        // Logo.VERSION 带 "v" 前缀（titlebar 展示用），web 自述不带
        @Assert(CJH_WEB_VERSION, Logo.VERSION[1..].toString())
    }

    @TestCase
    public func testWebVersionIsNotStale(): Unit {
        // 防止有人把常量改回旧值：只要求是 1.x 且非 1.3.0 这个已知的历史值
        @Assert(CJH_WEB_VERSION.startsWith("1."), true)
        @Assert(CJH_WEB_VERSION != "1.3.0", true)
    }
}
