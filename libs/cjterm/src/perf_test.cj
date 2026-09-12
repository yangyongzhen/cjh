package cjterm

import std.fs.*
import std.process.*

/**
 * 渲染性能埋点（perf.cj）测试：
 * - 默认关闭：入口零副作用（不计数、不读时钟、无落点）
 * - 开启后按虚拟时钟累计：次数、耗时峰值、最近一次行数与活跃轮长度
 * - 落盘节奏：计数到点（每 60 次渲染）或间隔到点（2s）才写一行，绝不逐帧 I/O
 * - 统计行为纯整数（renders=/folds=/avgFoldUs=/maxFoldUs=/lastFoldUs=/lastLines=/lastActiveRunes=）
 *
 * 临时目录：/tmp/cjh_ut_perf_*（用例内自建自清；仓颉无递归删除 API → bash rm -rf）
 */

/** 可编程微秒时间源（用类承载可变状态，避免 lambda 捕获可变变量的限制） */
class FakeMicros <: MicrosSource {
    public var us: Int64 = 0

    public init() {}

    public func micros(): Int64 {
        return this.us
    }
}

@Test
public class PerfTraceTest {

    private func freshDir(name: String): String {
        let dir = "/tmp/cjh_ut_perf_" + name
        try {
            var args = Array<String>(2, repeat: "")
            args[0] = "-c"
            args[1] = "rm -rf '" + dir + "'"
            let _ = executeWithOutput("/bin/bash", args)
        } catch (e: Exception) {
            // 清理失败不影响用例
        }
        Directory.create(dir, recursive: true)
        return dir
    }

    /** 默认关闭：所有入口零副作用（不计数、不读时钟、无落点） */
    @TestCase
    public func testDisabledIsNoop(): Unit {
        PerfTrace.resetForTest()
        PerfTrace.disableForTest()
        let fake = FakeMicros()
        fake.us = 777
        PerfTrace.setSourceForTest(fake)
        PerfTrace.onRender()
        let t0 = PerfTrace.beginFold()
        PerfTrace.foldDone(t0, 9, 99)
        @Assert(PerfTrace.stats().contains("renders=0 folds=0 "), true)
        @Assert(t0, 0)                       // 关闭时不读时钟
        @Assert(PerfTrace.outputPath(), "")
    }

    /** 开启后按虚拟时钟累计：次数、耗时峰值、最近一次行数与活跃轮长度 */
    @TestCase
    public func testCountsWithVirtualClock(): Unit {
        PerfTrace.resetForTest()
        let dir = this.freshDir("counts")
        PerfTrace.enableForTest(dir + "/perf.log")
        let fake = FakeMicros()
        PerfTrace.setSourceForTest(fake)
        // 第 1 帧：0 → 250us
        fake.us = 0
        PerfTrace.onRender()
        var start = PerfTrace.beginFold()
        fake.us = 250
        PerfTrace.foldDone(start, 12, 100)
        // 第 2 帧：250 → 1750us（本帧 1500us，刷新峰值）
        PerfTrace.onRender()
        start = PerfTrace.beginFold()
        fake.us = 1750
        PerfTrace.foldDone(start, 30, 8000)
        @Assert(PerfTrace.stats().contains("renders=2 folds=2 "), true)
        @Assert(PerfTrace.stats().contains("avgFoldUs=875 "), true)     // (250+1500)/2
        @Assert(PerfTrace.stats().contains("maxFoldUs=1500 "), true)
        @Assert(PerfTrace.stats().contains("lastFoldUs=1500 "), true)
        @Assert(PerfTrace.stats().contains("lastLines=30 "), true)
        @Assert(PerfTrace.stats().contains("lastActiveRunes=8000"), true)
    }

    /** 落盘节奏：不足 60 次渲染且未超间隔 → 不落盘（避免逐帧 I/O） */
    @TestCase
    public func testFlushPacingByCount(): Unit {
        PerfTrace.resetForTest()
        let dir = this.freshDir("pacing")
        let path = dir + "/perf.log"
        PerfTrace.enableForTest(path)
        let fake = FakeMicros()
        PerfTrace.setSourceForTest(fake)
        for (i in 1..=59) {
            fake.us = i
            PerfTrace.onRender()
        }
        @Assert(PerfTrace.stats().contains("renders=59 "), true)
        @Assert(exists(path), false)          // 59 次：还没到点
        fake.us = 60
        PerfTrace.onRender()                  // 第 60 次：到点落一行
        @Assert(exists(path), true)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("renders=60"), true)
        @Assert(content.contains("lastActiveRunes="), true)
    }

    /** 间隔到点也落盘：计数未到点也能拿到数据（长思考卡顿现场往往只跑几秒） */
    @TestCase
    public func testFlushOnInterval(): Unit {
        PerfTrace.resetForTest()
        let dir = this.freshDir("interval")
        let path = dir + "/perf.log"
        PerfTrace.enableForTest(path)
        let fake = FakeMicros()
        PerfTrace.setSourceForTest(fake)      // lastFlushUs = 0
        fake.us = PerfTrace.FLUSH_INTERVAL_US + 1
        PerfTrace.onRender()
        @Assert(PerfTrace.stats().contains("renders=1 "), true)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("renders=1"), true)
    }
}
