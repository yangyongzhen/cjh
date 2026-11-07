package cjh.tests

import std.time.*
import std.collection.*
import std.fs.*
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

    /**
     * 命令自己退出（`exit N`）走 EOF 路径：会话要能重建，且不留下会话 pid 文件。
     *
     * 旧实现只在 killProcessTree 里 `rm -f`，EOF 路径只把 proc 置 None —— 于是
     * 「命令带 exit / 会话崩溃」每条都在 /tmp 留一个 cjh-sess-*.pid（实测积了 8 个）。
     * POSIX 现在根本不落这个文件（setsid ⇒ pgid == pid），所以断言用「目录计数不变」，
     * 同时验证 EOF 收尾没把会话重建搞坏。
     */
    @TestCase
    public func testExitCommandLeavesNoPgFileAndRebuilds(): Unit {
        let before = countSessionPgFiles()
        let s = BashSession()
        try {
            let (c1, _) = s.execute("exit 3", 10)
            @Assert(c1, 3)
            @Assert(countSessionPgFiles(), before)
            let (c2, o2) = s.execute("echo rebuilt-after-eof", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("rebuilt-after-eof"), true)
        } finally {
            s.close()
        }
        @Assert(countSessionPgFiles(), before)
    }

    /**
     * POSIX 组杀不再依赖 pid 文件：会话跑着也不该在 /tmp 落 cjh-sess-*.pid。
     * 修复前每次建会话都写一个，而清理只埋在 killProcessTree 里 —— 漏一次就永久留档。
     */
    @TestCase
    public func testPosixSessionDoesNotCreatePgFile(): Unit {
        let before = countSessionPgFiles()
        let s = BashSession()
        try {
            let (c1, o1) = s.execute("echo pgfile-probe", 10)
            @Assert(c1, 0)
            @Assert(o1.contains("pgfile-probe"), true)
            @Assert(countSessionPgFiles(), before)
        } finally {
            s.close()
        }
        @Assert(countSessionPgFiles(), before)
    }

    /** 数 /tmp 下遗留的会话 pid 文件（POSIX 侧应恒定不变） */
    private static func countSessionPgFiles(): Int64 {
        let found = ArrayList<String>()
        try {
            Directory.walk("/tmp", { fi =>
                if (!fi.isDirectory() && fi.name.startsWith("cjh-sess-") && fi.name.endsWith(".pid")) {
                    found.add(fi.name)
                }
                return true
            })
        } catch (e: Exception) {
            ()
        }
        return found.size
    }
}
