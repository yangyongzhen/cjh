package cjh.tests

/**
 * Web 启动安全策略 + REST 会话路由参数校验
 *
 * 回归背景（AtomGit issue #5 第 3、4 条）：
 *   - 之前 `--bind 0.0.0.0` 且无 token 只打印警告，照样起服务；
 *   - /api/sessions/{id} 是新增路由，id 会拼进文件路径，必须挡掉路径穿越。
 */

import cjh.web.*

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
