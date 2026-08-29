package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*

/**
 * BashTool 单元测试：命令执行、退出码、stderr、参数校验
 */
@Test
public class BashToolTest {

    private func buildArgs(command: String): JsonObject {
        var args = JsonObject()
        args.put("command", JsonString(command))
        return args
    }

    @TestCase
    public func testEchoSuccess(): Unit {
        let tool = BashTool(60, false)  // 非会话路径（stderr 分离语义）
        let result = tool.execute(this.buildArgs("echo hello"))
        @Assert(result.isError, false)
        @Assert(result.content.contains("exit code: 0"), true)
        @Assert(result.content.contains("hello"), true)
    }

    @TestCase
    public func testNonZeroExitIsError(): Unit {
        let tool = BashTool(60, false)  // 非会话路径（stderr 分离语义）
        let result = tool.execute(this.buildArgs("exit 3"))
        @Assert(result.isError, true)
        @Assert(result.content.contains("exit code: 3"), true)
    }

    @TestCase
    public func testStderrCaptured(): Unit {
        let tool = BashTool(60, false)  // 非会话路径（stderr 分离语义）
        let result = tool.execute(this.buildArgs("echo oops >&2"))
        @Assert(result.isError, false)
        @Assert(result.content.contains("stderr"), true)
        @Assert(result.content.contains("oops"), true)
    }

    @TestCase
    public func testPipelineAndEnv(): Unit {
        let tool = BashTool(60, false)  // 非会话路径（stderr 分离语义）
        // 管道 + 变量展开：验证 -c 语义
        let result = tool.execute(this.buildArgs("X=5; echo $X | wc -l"))
        @Assert(result.isError, false)
        @Assert(result.content.contains("1"), true)
    }

    @TestCase
    public func testMissingCommandParam(): Unit {
        let tool = BashTool(60, false)  // 非会话路径（stderr 分离语义）
        var args = JsonObject()
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testTimeoutKillsLongCommand(): Unit {
        // P0-1：超时防挂死——sleep 5 用 1s 超时必须被杀
        let tool = BashTool(1, false)  // 非会话路径 + 1 秒超时
        let result = tool.execute(this.buildArgs("sleep 5"))
        @Assert(result.isError, true)
        @Assert(result.content.contains("超时"), true)
        @Assert(result.content.contains("124"), true)
    }

    @TestCase
    public func testFastCommandNotAffectedByTimeout(): Unit {
        let tool = BashTool(1, false)
        let result = tool.execute(this.buildArgs("echo quick"))
        @Assert(result.isError, false)
        @Assert(result.content.contains("quick"), true)
    }
}
