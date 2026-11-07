package cjh.tests

import std.time.*
import cjh.tools.*

/**
 * Windows 侧 bash 会话超时回归（2026-11-07，灵渠实测）。
 *
 * 现象：agent 自己写的 `find / -maxdepth 6 … | head -10` 全盘扫描，调用方给了
 * `timeout: 120`，但工具调用 644s+ 仍不返回（灵渠界面显示「执行中 565s」）；
 * 现场 `find.exe` 还活着、累计 CPU 605s，把它杀掉后 3s 内 agent 恢复。
 *
 * 根因：killSession 只 terminate 会话 bash 本体，正在跑的递归子命令落成孤儿——
 * 孤儿继承了 stdout 管道写端，管道永不 EOF，随后的 wait 就再也返回不了，
 * 超时提示永远到不了模型。
 *
 * 判据：① 必须返回（不挂死）；② 返回 -1 且文案含「超时」；③ 会话可重建继续用。
 * 旧实现在 ① 上失败（wait 卡到孤儿退出为止）。
 */
@When[os == "Windows"]
@Test
public class BashSessionWindowsTest {

    @TestCase
    public func testTimeoutReturnsWithGrandchildHoldingPipe(): Unit {
        let s = BashSession()
        try {
            let t0 = DateTime.now()
            let (c1, o1) = s.execute(
                "find / -maxdepth 6 -type d -name \"ohos\" -path \"*gen*\" 2>/dev/null | head -10", 5)
            let cost = (DateTime.now() - t0).toMilliseconds()
            @Assert(c1, -1)
            @Assert(o1.contains("超时"), true)
            // 挂死判据：超时 5s，给 60s 余量吸收机器级停顿；旧实现这里是 644s+
            @Assert(cost < 60000, true)
            // 会话已重建：后续命令正常
            let (c2, o2) = s.execute("echo recovered", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("recovered"), true)
        } finally {
            s.close()
        }
    }

    /**
     * 收尾靠「会话自报 $$ → 按进程组杀」：文件名必须每个会话唯一，
     * 否则两个会话共用一份 pid 文件，收尾会杀掉别人的进程组。
     */
    @TestCase
    public func testSessionPgFileUniquePerLauncher(): Unit {
        let a = sessionPgFile(1234)
        let b = sessionPgFile(5678)
        @Assert(a == "/tmp/cjh-sess-1234.pid", true)
        @Assert(b == "/tmp/cjh-sess-5678.pid", true)
        @Assert(a == b, false)
    }
}
