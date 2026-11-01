package cjh.tests

import cjh.web.*

/**
 * WebSocket 发送守护（`WsSendGuard`）单测。
 *
 * 背景：客户端断开后继续写会抛 SocketException(10053)，异常抛穿 `Agent.run`
 * 顶层会打死整轮 run（灵渠 0.39.7 实测：页面永远停在 tool_start:24）。
 * 守护的契约：第一次失败要能被上层看见（只打一条日志），之后一律跳过。
 * socket 本身的行为不在单测里模拟，这里只测状态机。
 */
@Test
public class WsSendGuardTest {

    @TestCase
    public func testAllowsSendUntilFailure(): Unit {
        let g = WsSendGuard()
        @Assert(g.allowsSend(), true)      // 初始可写
        @Assert(g.isDead(), false)
        g.onSent()
        @Assert(g.sentCount(), 1)
        @Assert(g.allowsSend(), true)      // 成功不影响可写性
    }

    @TestCase
    public func testFirstFailureReportedThenDies(): Unit {
        let g = WsSendGuard()
        @Assert(g.onFailed("SocketException: 10053"), true)   // 第一次：上层要打日志
        @Assert(g.isDead(), true)
        @Assert(g.allowsSend(), false)                        // 之后跳过，不再抛异常
        @Assert(g.onFailed("SocketException: 10053"), false)   // 第二次不再上报
        @Assert(g.failedCount(), 2)
        @Assert(g.errorText(), "SocketException: 10053")       // 只留第一次的错误文本
    }

    @TestCase
    public func testSummaryCarriesCounters(): Unit {
        let g = WsSendGuard()
        g.onSent()
        g.onSent()
        let _ = g.onFailed("boom")
        let s = g.summary()
        @Assert(s.contains("sent=2"), true)
        @Assert(s.contains("failed=1"), true)
        @Assert(s.contains("dead=true"), true)
        @Assert(s.contains("boom"), true)
    }

    @TestCase
    public func testSummaryWithoutErrorOmitsErrPart(): Unit {
        // 边界：没失败过时摘要不该带 err=（排障时靠这点区分"没断"与"断了"）
        let g = WsSendGuard()
        g.onSent()
        @Assert(g.summary().contains("err="), false)
    }
}
