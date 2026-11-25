package cjh.tools

import std.time.*

/**
 * 收尾命令必须自己有超时（2026-11-25 Wine 实测回归）。
 *
 * 现场：Git Bash 在 Wine 下卡在 Cygwin 初始化，`BashSession.execute` 的 10s
 * 超时到了以后，`killProcessTree` 又用无超时的 `executeWithOutput` 去调同一个
 * 卡住的 bash，整条工具调用一直挂到外层 120s timeout。收尾命令一旦卡住，
 * 超时提示就永远回不到模型——这比"没杀掉"更糟。
 *
 * 这里直接守 `runBounded` 的上限：`/bin/sleep 30` 必须在 ~1s 返回。
 */
@When[os != "Windows"]
@Test
public class BashSessionBoundedTest {

    @TestCase
    public func testHangingCommandIsKilledWithinBound(): Unit {
        let start = DateTime.now()
        runBounded("/bin/sleep", ["30"], Duration.second * 1)
        let elapsedMs = (DateTime.now() - start).toMilliseconds()
        @Expect(elapsedMs < 5000)
    }

    @TestCase
    public func testMissingExecutableIsIgnored(): Unit {
        let start = DateTime.now()
        runBounded("/nonexistent/cjh-no-such-binary", ["x"], Duration.second * 1)
        let elapsedMs = (DateTime.now() - start).toMilliseconds()
        @Expect(elapsedMs < 2000)
    }
}
