package cjh.tests

import cjh.gateway.*

/**
 * WS 断连策略（`disconnectAction`）单测。
 *
 * 背景：cjh 原先"连接一断就打断本轮"。灵渠迁移台 0.39.7 端到端实测中，
 * WebView 只重连了一次，整轮 AI 迁移（40 次工具调用）就被打断。
 * 现在由 settings 的 `web.keep_running_on_disconnect` 决定：无人值守长任务可以选"不断"。
 */
@Test
public class DisconnectPolicyTest {

    @TestCase
    public func testIdleSessionDoesNothing(): Unit {
        @Assert(disconnectAction(false, false), "none")
        @Assert(disconnectAction(false, true), "none")   // 没在跑，配什么都无所谓
    }

    @TestCase
    public func testDefaultInterrupts(): Unit {
        // 默认行为（保持向后兼容）：断连即打断
        @Assert(disconnectAction(true, false), "cancel")
    }

    @TestCase
    public func testKeepRunningWhenConfigured(): Unit {
        // 长任务 opted-in：断开也不打断，本轮跑完
        @Assert(disconnectAction(true, true), "keep")
    }
}