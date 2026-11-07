package cjh.tests

import std.time.*
import cjh.tools.*

/**
 * POSIX 侧 bash 会话超时收尾回归（2026-11-07）。
 *
 * 与 Windows 版（bash_session_win_test.cj）守的不是同一件事：
 * - Windows 版守「p.wait 挂在孤儿管道上」——那条链在 MSYS 上会让工具调用 644s 不返回；
 * - 本用例守「超时后子孙进程被一起收掉」——孤儿握着 stdout 写端继续吃 CPU/磁盘。
 *
 * 判据必须能区分新旧实现，否则等于没测：
 * 旧实现只 terminate 会话 bash 本体，正在跑的子命令落成孤儿**继续存活**；
 * 修好后按进程组整组收掉（依赖 `launchCommand` 用 setsid 让它当组长）。
 *
 * 定位方式用「命令自己把 pid 写进文件」而不是按命令行数进程：
 * 数进程会把历次运行遗留的同名孤儿一起数进去（实测踩过），pid 文件天然只指本次。
 */
@When[os != "Windows"]
@Test
public class BashSessionPosixTest {

    private static const PROBE_PID_FILE: String = "/tmp/cjh_ut_posix_group.pid"

    @TestCase
    public func testTimeoutCollectsGrandchildren(): Unit {
        let s = BashSession()
        try {
            // 先清上次残留的 pid 文件，确保读到的是本次进程
            let _ = s.execute("rm -f '${PROBE_PID_FILE}'", 10)

            let t0 = DateTime.now()
            // 子 shell 先把自己的 pid 落盘，再前台 sleep：超时后两者都必须消失
            let (c1, o1) = s.execute("sh -c 'echo $$ > ${PROBE_PID_FILE}; sleep 297.5'", 3)
            let cost = (DateTime.now() - t0).toMilliseconds()
            @Assert(c1, -1)
            @Assert(o1.contains("超时"), true)
            // 超时 3s，给 20s 余量吸收机器级停顿
            @Assert(cost < 20000, true)

            // 会话已重建：后续命令正常（收尾不能把会话本身搞坏）
            let (c2, o2) = s.execute("echo recovered-posix", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("recovered-posix"), true)

            // 关键断言：本次那个子进程必须已经被收掉。
            // `ps -p` 只看这一个 pid，不受历次运行遗留的同类进程干扰。
            let (c3, o3) = s.execute(
                "p=$(cat ${PROBE_PID_FILE} 2>/dev/null); if [ -n \"$p\" ] && ps -p $p >/dev/null 2>&1; then echo ALIVE; else echo GONE; fi",
                10)
            @Assert(c3, 0)
            @Assert(o3.contains("GONE"), true)
        } finally {
            s.close()
        }
    }
}
