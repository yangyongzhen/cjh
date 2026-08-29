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
