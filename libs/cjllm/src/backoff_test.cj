package cjllm

import std.collection.*
import std.time.*

/**
 * backoffWait（限流退避的可中断等待）单元测试
 *
 * 背景：限流退避此前直接 `sleep(2s/5s/10s)`，退避窗口内 Ctrl+C / 子代理墙钟超时
 * 完全无响应（最长 17s 像死机）。改为 200ms 切片轮询 isCancelled 后，必须锁住三件事：
 *  1. 一开始就取消 → 立刻返回 false，绝不空等
 *  2. 期间取消 → 提前收场（不等满）
 *  3. 不取消 → 真的等满（别退化成立即返回，那会变成打满限流）
 *
 * 仓颉测试坑遵守：零参 lambda 写 `{ => }`；ArrayList 包装计数器（lambda 不能捕获可变局部）。
 */
@Test
public class BackoffWaitTest {

    @TestCase
    public func testCancelledReturnsFalseImmediately(): Unit {
        let t0 = DateTime.now()
        let ok = backoffWait(5000, { => true })
        let ms = (DateTime.now() - t0).toMilliseconds()
        @Assert(ok, false)        // 已取消 → false
        @Assert(ms < 500, true)   // 不等满 5s（退化成整段 sleep 时会 > 5000）
    }

    @TestCase
    public func testCompletesWhenNotCancelled(): Unit {
        let t0 = DateTime.now()
        let ok = backoffWait(300, { => false })
        let ms = (DateTime.now() - t0).toMilliseconds()
        @Assert(ok, true)
        @Assert(ms >= 300, true)  // 退避时长必须真的等到（否则等于没退避）
    }

    @TestCase
    public func testCancelMidwayStopsEarly(): Unit {
        // 第 3 次轮询开始取消：1000ms 的退避应在约 400ms 内收场
        let polls = ArrayList<Int64>()
        polls.add(0)
        let t0 = DateTime.now()
        let ok = backoffWait(1000, { =>
            polls[0] += 1
            polls[0] >= 3
        })
        let ms = (DateTime.now() - t0).toMilliseconds()
        @Assert(ok, false)
        @Assert(ms < 1000, true)
    }

    @TestCase
    public func testZeroWaitNoSleep(): Unit {
        // 边界：0ms 退避 = 只做一次取消检查
        @Assert(backoffWait(0, { => false }), true)
        @Assert(backoffWait(0, { => true }), false)
    }
}
