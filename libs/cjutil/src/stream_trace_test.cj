package cjutil

import std.fs.*

/**
 * 流式到达埋点（stream_trace.cj）测试：
 * - 默认关闭：入口零副作用（不计数、不读时钟、无落点）
 * - 开启后按虚拟时钟累计：首字节延迟、相邻增量间隔（均值/峰值/最近）、长静默次数
 * - 落盘节奏：累计到 N 个 delta 或间隔到点才写一行，绝不逐个 delta I/O
 * - 边界：chars<=0 的增量忽略；新一轮 beginRequest 重置首字节计时
 *
 * 临时目录沿用工程约定（POSIX=/tmp/cjh_ut_*，Windows=%TEMP%\cjh_ut_*），
 * 每个用例独立目录：先递归清理再创建（Directory.create 不幂等）。
 */

/** 可编程微秒时间源（用类承载可变状态，避免 lambda 捕获可变变量的限制） */
class FakeMicrosClock <: MicrosClock {
    public var us: Int64 = 0

    public init() {}

    public func micros(): Int64 {
        return this.us
    }
}

@Test
public class StreamTraceTest {

    private func freshDir(name: String): String {
        let path = tmpPath("cjh_ut_stream_trace_" + name)
        try {
            removeIfExists(path, recursive: true)
        } catch (e: Exception) {
            ()
        }
        Directory.create(path, recursive: true)
        return path
    }

    /** 默认关闭：所有入口零副作用（不计数、不读时钟、无落点） */
    @TestCase
    public func testDisabledIsNoop(): Unit {
        StreamTrace.resetForTest()
        StreamTrace.disableForTest()
        let fake = FakeMicrosClock()
        fake.us = 5000
        StreamTrace.setClockForTest(fake)
        StreamTrace.beginRequest()
        StreamTrace.onDelta(10)
        @Assert(StreamTrace.stats().contains("reqs=0 deltas=0 chars=0 "), true)
        @Assert(StreamTrace.outputPath(), "")
    }

    /** 主路径：首字节延迟 + 相邻增量间隔（均值/峰值/最近）+ 字符累计 */
    @TestCase
    public func testCountsTtfbAndGaps(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("gaps")
        StreamTrace.enableForTest(dir + "/stream.log")
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        fake.us = 0
        StreamTrace.beginRequest()
        // 首帧：t=500us 到达 → ttfbUs=500（不计间隔）
        fake.us = 500
        StreamTrace.onDelta(3)
        // 第 2 帧：t=1500 → gap 1000
        fake.us = 1500
        StreamTrace.onDelta(2)
        // 第 3 帧：t=4000 → gap 2500
        fake.us = 4000
        StreamTrace.onDelta(1)
        @Assert(StreamTrace.stats().contains("reqs=1 deltas=3 chars=6 "), true)
        @Assert(StreamTrace.stats().contains("ttfbUs=500 "), true)
        @Assert(StreamTrace.stats().contains("ttfbMaxUs=500 "), true)
        @Assert(StreamTrace.stats().contains("avgGapUs=1750 "), true)   // (1000+2500)/2
        @Assert(StreamTrace.stats().contains("maxGapUs=2500 "), true)
        @Assert(StreamTrace.stats().contains("lastGapUs=2500 "), true)
        @Assert(StreamTrace.stats().contains("stalls=0 "), true)
        @Assert(StreamTrace.stats().contains("lastDeltaChars=1"), true)
    }

    /** 长静默计数：单个间隔超过 1s 记一次（模型停顿 / 代理攒包） */
    @TestCase
    public func testStallCounted(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("stall")
        StreamTrace.enableForTest(dir + "/stream.log")
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        fake.us = 0
        StreamTrace.beginRequest()
        StreamTrace.onDelta(5)
        // 间隔恰为 1s：不算长静默（判据是"> STALL_US"）
        fake.us = StreamTrace.STALL_US
        StreamTrace.onDelta(5)
        @Assert(StreamTrace.stats().contains("stalls=0 "), true)
        // 间隔 4s：算一次
        fake.us = StreamTrace.STALL_US + 4000000
        StreamTrace.onDelta(5)
        @Assert(StreamTrace.stats().contains("stalls=1 "), true)
    }

    /** 边界：chars<=0 的增量被忽略（不计数、不推进间隔基准） */
    @TestCase
    public func testNonPositiveCharsIgnored(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("zero")
        StreamTrace.enableForTest(dir + "/stream.log")
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        fake.us = 0
        StreamTrace.beginRequest()
        StreamTrace.onDelta(0)
        StreamTrace.onDelta(-3)
        @Assert(StreamTrace.stats().contains("deltas=0 chars=0 "), true)
        fake.us = 100
        StreamTrace.onDelta(7)
        @Assert(StreamTrace.stats().contains("ttfbUs=100 "), true)
    }

    /** 新一轮请求重置首字节计时（多轮对话里每轮都要看自己的 TTFB） */
    @TestCase
    public func testNewRequestResetsTtfb(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("rounds")
        StreamTrace.enableForTest(dir + "/stream.log")
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        fake.us = 0
        StreamTrace.beginRequest()
        fake.us = 200
        StreamTrace.onDelta(1)
        @Assert(StreamTrace.stats().contains("ttfbUs=200 "), true)
        // 第 2 轮：从 t=10000 起算，首帧 t=13000 → ttfb 3000（峰值刷新）
        fake.us = 10000
        StreamTrace.beginRequest()
        fake.us = 13000
        StreamTrace.onDelta(1)
        @Assert(StreamTrace.stats().contains("reqs=2 "), true)
        @Assert(StreamTrace.stats().contains("ttfbUs=3000 "), true)
        @Assert(StreamTrace.stats().contains("ttfbMaxUs=3000 "), true)
    }

    /** 落盘节奏：不足 N 个 delta 且未超间隔 → 不落盘 */
    @TestCase
    public func testFlushPacingByCount(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("pacing")
        let path = dir + "/stream.log"
        StreamTrace.enableForTest(path)
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        StreamTrace.beginRequest()
        for (i in 1..=StreamTrace.FLUSH_EVERY - 1) {
            fake.us = i
            StreamTrace.onDelta(1)
        }
        @Assert(exists(path), false)          // 未到点：一行都没写
        fake.us = StreamTrace.FLUSH_EVERY
        StreamTrace.onDelta(1)                // 第 N 个：到点落一行
        @Assert(exists(path), true)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("deltas=${StreamTrace.FLUSH_EVERY} "), true)
        @Assert(content.contains("avgGapUs="), true)
    }

    /** 间隔到点也落盘：delta 很少但等了很久（长静默现场往往只有几帧） */
    @TestCase
    public func testFlushOnInterval(): Unit {
        StreamTrace.resetForTest()
        let dir = this.freshDir("interval")
        let path = dir + "/stream.log"
        StreamTrace.enableForTest(path)
        let fake = FakeMicrosClock()
        StreamTrace.setClockForTest(fake)
        StreamTrace.beginRequest()
        fake.us = StreamTrace.FLUSH_INTERVAL_US + 1
        StreamTrace.onDelta(9)
        @Assert(exists(path), true)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("deltas=1 "), true)
    }
}
