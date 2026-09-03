package cjlog

import std.time.*

/**
 * cjlog 回归测试
 *
 * 重点：sleepMs 必须是真实 sleep（忙等空转 bug，见 docs 踩坑记录）：
 * 旧实现 `while (i < ms*1000) { i += 1000 }` 是纯整数空循环，毫秒级耗时 ≈ 0——
 * sink 协程在主 worker 上满速自旋，烧光 CPU 并饿死 TUI 主循环：
 * 现象 = 进程存活 + CPU 100% + TUI 无法输入/画面冻结 + sshd Send-Q 0（远端显示未断线）。
 */
@Test
public class CjlogTest {
    @TestCase
    public func testSleepMsIsRealSleep(): Unit {
        let sink = LogSink()
        let t0 = MonoTime.now()
        sink.sleepMs(80)
        let elapsed = MonoTime.now() - t0
        // 忙等空转 → elapsed ≈ 0，本断言失败（红）；真实 sleep → ≈ 80ms（绿）
        @Assert(elapsed >= Duration.millisecond * 60, true)
        // 上界：慢环境/高负载下真实 sleep 也不应离谱地长
        @Assert(elapsed <= Duration.millisecond * 3000, true)
    }
}
