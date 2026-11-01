package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*
import cjterm.*

/**
 * BashSession 持久会话测试（P1-3）：
 * 跨命令保留 cwd/env、输出、退出码、超时重建。
 *
 * @When[os != "Windows"]：契约建立在 /bin/bash 持久子进程 + POSIX 信号语义上；
 * Windows 上 BashTool 回落 PowerShell，cwd/env 保持、超时杀进程、stderr 采集全不同。
 */
@When[os != "Windows"]
@Test
public class BashSessionTest {

    @TestCase
    public func testCwdPersistsAcrossCommands(): Unit {
        let s = BashSession()
        try {
            // 第一条：cd 到临时目录
            let (c1, o1) = s.execute("cd /tmp && pwd", 10)
            @Assert(c1, 0)
            @Assert(o1.contains("/tmp"), true)
            // 第二条：cwd 保留（仍在 /tmp）
            let (c2, o2) = s.execute("pwd", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("/tmp"), true)
            @Assert(o2.contains("/root/test"), false)  // 不是初始 cwd
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testEnvPersistsAcrossCommands(): Unit {
        let s = BashSession()
        try {
            let (c1, _) = s.execute("export CJH_TEST_VAR=hello123", 10)
            @Assert(c1, 0)
            let (c2, o2) = s.execute("echo $CJH_TEST_VAR", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("hello123"), true)
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testOutputAndExitCode(): Unit {
        let s = BashSession()
        try {
            let (c1, o1) = s.execute("echo hello && echo world", 10)
            @Assert(c1, 0)
            @Assert(o1.contains("hello"), true)
            @Assert(o1.contains("world"), true)
            // 非零退出码
            let (c2, _) = s.execute("exit 3", 10)
            @Assert(c2, 3)
            // stderr 合并进输出
            let (c3, o3) = s.execute("echo err-msg >&2", 10)
            @Assert(c3, 0)
            @Assert(o3.contains("err-msg"), true)
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testTimeoutKillsAndRecreates(): Unit {
        let s = BashSession()
        try {
            // 命令挂死 → 超时杀会话
            let (c1, o1) = s.execute("sleep 10", 1)
            @Assert(c1, -1)
            @Assert(o1.contains("超时"), true)
            // 会话已重建：后续命令正常（cwd 重置为初始）
            let (c2, o2) = s.execute("echo recovered", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("recovered"), true)
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testTimeoutKillsReapsZombie(): Unit {
        // 回归（2026-09-03 事故）：killSession 旧实现只 terminate(force) 不 wait，
        // 每个超时命令都留一个未回收僵尸，长会话累计"4 个未回收僵尸子进程"。
        // reapedCount 只在 terminate+wait 成功后自增——>0 证明进程已被 wait 回收。
        let s = BashSession()
        try {
            @Assert(s.testReapedCount(), 0)
            // 命令挂死 → 超时 → killSession（terminate + wait 回收）
            // 用 sleep 15 / timeout 3（曾为 sleep 2 / 1）：1.2.0 全量跑实测整机级
            // 停顿（探针实锤单次 50ms sleep 膨胀 ~4.5s，疑 swap/GC STW），1s 余量
            // 会整段跳过超时窗口（c1==0 假通过）。余量 12s 可吸收秒级停顿；断言
            // 语义不变——超时触发 + killSession 回收照旧验证。killSession 只杀
            // bash 本体，孙进程 sleep 被 re-parent 持有管道直到自然退出
            let (c1, o1) = s.execute("sleep 15", 3)
            @Assert(c1, -1)
            @Assert(o1.contains("超时"), true)
            @Assert(s.testReapedCount(), 1)  // 超时会话进程已被 wait 回收，非僵尸
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testCloseReapsZombie(): Unit {
        // 退出路径回归：close() 必须 wait 回收会话进程，否则退出后残留泄漏的
        // 会话 bash（事故现场泄漏约 2 小时的 bash 即此路径）。
        let s = BashSession()
        try {
            let (c1, _) = s.execute("echo ok", 10)
            @Assert(c1, 0)
            @Assert(s.testReapedCount(), 0)  // 正常完成：进程未 terminate，未回收
            s.close()
            @Assert(s.testReapedCount(), 1)  // close → killSession → wait 回收
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testBashToolCloseReaps(): Unit {
        // 退出清理路径：BashTool.close()（runTui finally 调用）必须回收会话进程
        let tool = BashTool()  // useSession=true
        var args = JsonObject()
        args.put("command", JsonString("echo hi"))
        let r = tool.execute(args)
        @Assert(r.isError, false)
        tool.close()  // 不抛异常且回收（进程被 wait，不残留泄漏 bash）
    }

    @TestCase
    public func testMultiStepWorkflow(): Unit {
        // 模拟真实多步流程：cd 项目 → 创建文件 → 验证
        let s = BashSession()
        try {
            let dir = testTempDir("bsflow")
            let (c1, _) = s.execute("cd '" + dir + "' && mkdir -p sub && echo data > sub/f.txt", 10)
            @Assert(c1, 0)
            let (c2, o2) = s.execute("cat sub/f.txt", 10)
            @Assert(c2, 0)
            @Assert(o2.contains("data"), true)
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testChineseOutputNoMojibake(): Unit {
        // 乱码回归（踩坑 §3.15）：旧 readUntilMarker 逐字节 String(Rune(byte))
        // 拼接，中文 stdout 每个 UTF-8 字节被当独立 Latin-1 码点
        // （"读"=E8 AF BB → "éè»"）。用 >4096 字节中文输出强制多字节字符
        // 跨 4096 读取边界，验证 pending 字节拼接正确、无乱码。
        let s = BashSession()
        try {
            // 2000 个"读懂代码"= 8000 字节，必然跨多个 4096 读取边界
            let (c1, o1) = s.execute("python3 -c \"print('读懂代码快速赢玩法工程案例' * 500)\"", 15)
            @Assert(c1, 0)
            @Assert(o1.contains("读懂代码"), true)
            @Assert(o1.contains("快速赢"), true)
            // 无乱码特征：UTF-8 字节被当单字节字符会产生 Latin-1 区码点
            // （"读"=E8 AF BB → è/¯/»），正确解码的纯中文输出不应含 U+00E8
            @Assert(o1.contains("\u{00e8}"), false)
            // marker 仍能被正确切掉（不残留在输出里）
            @Assert(o1.contains("__CJH_"), false)
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testBashToolSessionPath(): Unit {
        // BashTool 默认走会话：cwd 持久
        let tool = BashTool()  // useSession=true
        var args1 = JsonObject()
        args1.put("command", JsonString("cd /tmp && pwd"))
        let r1 = tool.execute(args1)
        @Assert(r1.isError, false)
        var args2 = JsonObject()
        args2.put("command", JsonString("pwd"))
        let r2 = tool.execute(args2)
        @Assert(r2.isError, false)
        @Assert(r2.content.contains("/tmp"), true)
    }
}

/**
 * 结束标记写**独立 fd 3**（0.39.6 回归用例）
 *
 * 老包装：`{ cmd; } 2>&1; echo CODE; echo marker`。
 * 命令若把 shell 的 fd1 永久改道（`{ exec 1>/dev/null; echo hi; }`），
 * CODE 与 marker 会一起被带进 /dev/null → 读线程永远等不到标记 →
 * 只能耗到超时（本用例 5 秒超时，断言 c1==0 会红）。
 * 新包装：`exec 3>&1; { cmd; } 2>&1; echo CODE 1>&3; echo marker 1>&3; exec 1>&3`。
 *
 * 不加 `@When[os != "Windows"]`：Git Bash 同样有 fd3 语义，
 * Windows 上没有 Git Bash 时用运行时 ShellProvider 判定跳过。
 */
@Test
public class BashMarkerFdTest {

    @TestCase
    public func testMarkerSurvivesExecRedirect(): Unit {
        if (!ShellProvider().isBash) {
            return  // PowerShell 模式没有 fd3，这条契约不成立（见 BashTool 的 PS 分支）
        }
        let s = BashSession()
        try {
            let (c1, o1) = s.execute("{ exec 1>/dev/null; echo hi; } 2>&1", 5)
            @Assert(c1, 0)                        // 老包装在此超时返回 -1
            @Assert(o1.contains("__CJH_"), false)  // CODE/marker 不该留在正文
            // 会话仍可用：fd1 已复位回管道（否则后续命令输出全部进 /dev/null）
            let (c2, o2) = s.execute("echo after-fd3", 5)
            @Assert(c2, 0)
            @Assert(o2.contains("after-fd3"), true)
        } finally {
            s.close()
        }
    }
}

/**
 * heredoc 回归持久会话（0.39.7）
 *
 * 旧包装把收尾的 `}` 与 heredoc 终止符挤在同一行（`… EOF; } 2>&1; echo …`），
 * 而终止符必须**独占一行** → bash 继续从 stdin 读 heredoc 正文，标记永不出现 → 卡到超时。
 * 于是 heredoc 曾被分流到非会话路径（`bash -c` + base64），代价是不共享 cwd/env。
 * 现在收尾 `}` 独占一行，heredoc 在会话里正常工作，分流判定整段删除。
 *
 * 不加 `@When[os != "Windows"]`：Git Bash 吃同一套语法，
 * Windows 上没有 Git Bash 时用运行时 ShellProvider 判定跳过。
 */
@Test
public class BashHeredocInSessionTest {

    @TestCase
    public func testHeredocRunsInsideSession(): Unit {
        if (!ShellProvider().isBash) {
            return  // PowerShell 模式不支持 heredoc
        }
        let s = BashSession()
        try {
            // 全用 shell 内建（while read / echo），不依赖 cat 等 coreutils：
            // 用例只该验证"heredoc 能不能在会话里跑通"，不该顺带验证外部命令是否存在
            let cmd = "while read -r l; do echo \"got:$l\"; done <<'CJH_EOF'\nline-one\nline-two\nCJH_EOF"
            let (c1, o1) = s.execute(cmd, 5)
            @Assert(c1, 0)                            // 旧包装在此超时返回 -1
            @Assert(o1.contains("got:line-one"), true)
            @Assert(o1.contains("got:line-two"), true)
            @Assert(o1.contains("CJH_EOF"), false)    // 终止符不该混进正文
        } finally {
            s.close()
        }
    }

    @TestCase
    public func testHeredocSeesSessionCwd(): Unit {
        // 旧实现把 heredoc 分流到非会话路径（`bash -c`），那条命令的 cwd 是
        // **cjh 进程的 cwd**，不是会话里 `cd` 过的目录 → 相对路径、`$(pwd)` 全跑偏。
        // 用未加引号的 heredoc 分隔符让 `$(pwd)` 在命令执行时展开，直接读出真实 cwd。
        if (!ShellProvider().isBash) {
            return
        }
        let tool = BashTool()  // useSession=true
        try {
            var a1 = JsonObject()
            a1.put("command", JsonString("cd /tmp && pwd"))
            @Assert(tool.execute(a1).isError, false)
            var a2 = JsonObject()
            a2.put("command", JsonString("while read -r l; do echo \"$l\"; done <<CJH_EOF\ncwd-is: $(pwd)\nCJH_EOF"))
            let r2 = tool.execute(a2)
            @Assert(r2.isError, false)
            @Assert(r2.content.contains("cwd-is: /tmp"), true)  // 旧分流在此读到进程 cwd
            var a3 = JsonObject()
            a3.put("command", JsonString("pwd"))
            @Assert(tool.execute(a3).content.contains("/tmp"), true)  // 会话 cwd 不被 heredoc 带走
        } finally {
            tool.close()
        }
    }

    @TestCase
    public func testSessionShellHasCoreutilsOnPath(): Unit {
        // PATH 回归（shell_path.cj）：cjh 用绝对路径找到 Git Bash，但它的 /usr/bin
        // 未必在继承的 PATH 上 —— 缺了连 `cat` 都是 `command not found`（127）。
        // `command -v` 本身是内建，所以这条断言不依赖 coreutils，正好二分。
        if (!ShellProvider().isBash) {
            return
        }
        let s = BashSession()
        try {
            let (c1, _) = s.execute("command -v cat", 5)
            @Assert(c1, 0)
            let (c2, _) = s.execute("command -v grep", 5)
            @Assert(c2, 0)
        } finally {
            s.close()
        }
    }
}
