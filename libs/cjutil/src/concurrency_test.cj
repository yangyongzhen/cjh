package cjutil

import std.time.*

/**
 * runWithBudget 预算竞速原语单元测试
 *
 * 覆盖（AGENTS.md：新纯函数 → 主路径 + 错误路径 + 边界）：
 *  1. 主路径：正常返回（T=Int64）+ T=Unit
 *  2. 错误路径：任务异常原样重抛（类型保留，不包装）
 *  3. 边界：超预算 → BudgetTimeoutException（耗时 ≈ 预算）
 *  4. 中断：isCancelled 恒 true → 立即 BudgetCancelledException
 *  5. 边界：任务运行中被中断（时间条件翻转）→ BudgetCancelledException
 */
@Test
public class BudgetRaceTest {

    @TestCase
    public func testMainPathIntAndUnit(): Unit {
        let v: Int64 = runWithBudget("phase", 5000, 100, { => false }) {
            42
        }
        @Assert(v, 42)

        // T=Unit 主路径（lambda 推断 T=Unit）
        runWithBudget("phase", 5000, 100, { => false }) {
            let x: Int64 = 21
            if (x != 21) {
                throw Exception("unreachable")
            }
        }
        @Assert(true, true)
    }

    @TestCase
    public func testTaskErrorRethrown(): Unit {
        var caught: ?Exception = None
        try {
            let _: Int64 = runWithBudget("phase", 5000, 100, { => false }) {
                throw IllegalArgumentException("boom-inner")
            }
        } catch (e: IllegalArgumentException) {
            caught = Some(e)
        } catch (e: Exception) {
            // 落到这里 = 异常被包装了（原语契约违规）
        }
        @Assert(caught.isSome(), true)
        let e = caught.getOrThrow()
        @Assert(e.toString().contains("boom-inner"), true)
    }

    @TestCase
    public func testBudgetExceeded(): Unit {
        let t0 = DateTime.now()
        var timedOut: Bool = false
        try {
            let _: Int64 = runWithBudget("slowphase", 150, 50, { => false }) {
                var i: Int64 = 0
                while (i < 600000000) {
                    i += 1
                }
                return 1
            }
        } catch (e: BudgetTimeoutException) {
            timedOut = true
            @Assert(e.toString().contains("slowphase"), true)
        }
        @Assert(timedOut, true)
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(elapsed >= 150, true)
        @Assert(elapsed < 5000, true)
    }

    @TestCase
    public func testCancelledImmediate(): Unit {
        let t0 = DateTime.now()
        var cancelled: Bool = false
        try {
            let _: Int64 = runWithBudget("phase", 5000, 50, { => true }) {
                7
            }
        } catch (e: BudgetCancelledException) {
            cancelled = true
        }
        @Assert(cancelled, true)
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(elapsed < 1000, true)
    }

    @TestCase
    public func testCancelledMidRun(): Unit {
        let t0 = DateTime.now()
        var cancelled: Bool = false
        try {
            let _: Int64 = runWithBudget("phase", 5000, 50, { => (DateTime.now() - t0).toMilliseconds() > 200 }) {
                var i: Int64 = 0
                while (i < 600000000) {
                    i += 1
                }
                return 1
            }
        } catch (e: BudgetCancelledException) {
            cancelled = true
        }
        @Assert(cancelled, true)
        // 中断在预算内生效（任务需 ~1s，未正常完成即被打断）
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        @Assert(elapsed < 3000, true)
    }
}
