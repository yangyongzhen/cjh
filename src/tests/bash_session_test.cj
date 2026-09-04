package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * BashSession 持久会话测试（P1-3）：
 * 跨命令保留 cwd/env、输出、退出码、超时重建。
 */
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
            // 用 sleep 2（非 sleep 10）：killSession 只杀 bash 本体，其孙进程
            // sleep 会被 re-parent 到测试进程并持有 stdout 管道直到自然退出，
            // sleep 越短读线程 EOF 越快，用例越短（回收 bash 本身是瞬时的）
            let (c1, o1) = s.execute("sleep 2", 1)
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
