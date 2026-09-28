package cjllm

import std.collection.*

/**
 * mock 长思考垫片（`CJH_MOCK_REASONING_CHARS` 的纯函数部分）测试。
 *
 * 契约：
 * - targetRunes <= baseRunes → 不垫（空列表）——含"默认关闭"（目标解析为 0）这条主路径
 * - targetRunes > baseRunes → 整块重复，垫到 baseRunes + 累计 >= targetRunes
 * - 单块恒为 MOCK_PAD_CHUNK 本身（多字节中文不被切碎），溢出不超过一块
 *
 * 环境变量本身走 mockEnvInt（去空白/引号、非法回落 0），在此不重复测：
 * 其行为已由"目标 <= 基线不垫"与 PTY/--mock 的不设变量路径覆盖。
 */
@Test
public class MockReasoningPadTest {

    private func totalRunes(chunks: ArrayList<String>): Int64 {
        var n: Int64 = 0
        for (c in chunks) {
            n += c.toRuneArray().size
        }
        return n
    }

    /** 默认关闭：目标为 0 或不超过基线时，基础思考流原样不动 */
    @TestCase
    public func testNoPadWhenTargetNotGreater(): Unit {
        @Assert(reasoningPadChunks(150, 0).size, 0)
        @Assert(reasoningPadChunks(150, 150).size, 0)
        @Assert(reasoningPadChunks(150, 149).size, 0)
    }

    /** 垫到目标：baseRunes + 累计 >= targetRunes（8192 即单轮上限那个量级） */
    @TestCase
    public func testPadsUpToTarget(): Unit {
        let base: Int64 = 150
        let chunks = reasoningPadChunks(base, 8192)
        @Assert(chunks.size > 0, true)
        @Assert(base + this.totalRunes(chunks) >= 8192, true)
    }

    /** 溢出受控：最多多垫一块，不重复放大 */
    @TestCase
    public func testOvershootBoundedByOneChunk(): Unit {
        let base: Int64 = 150
        let target: Int64 = 8192
        let chunkRunes = MOCK_PAD_CHUNK.toRuneArray().size
        let pad = this.totalRunes(reasoningPadChunks(base, target))
        let overshoot = base + pad - target
        @Assert(overshoot >= 0, true)
        @Assert(overshoot < chunkRunes, true)
    }

    /** 多字节完整：每块都是 MOCK_PAD_CHUNK 原样（不是按字节切出来的碎片） */
    @TestCase
    public func testChunksKeepMultibyteIntact(): Unit {
        let chunkRunes = MOCK_PAD_CHUNK.toRuneArray().size
        let chunks = reasoningPadChunks(0, chunkRunes * 3)
        @Assert(chunks.size, 3)
        for (c in chunks) {
            @Assert(c.toRuneArray().size, chunkRunes)
            @Assert(c.contains("思考"), true)
            @Assert(c.contains("\n"), true)
        }
    }
}

// 复现台闸门用的环境变量写入（与 mock.cj 的 getenv 同款零依赖做法）
@C
foreign func setenv(name: CString, value: CString, overwrite: Int32): Int32

/**
 * `CJH_MOCK_WEB_URL` 闸门测试（端到端复现台 scripts/e2e_warn_harness.py 的驱动点）。
 *
 * 契约：
 * - 未设/空 → 既有 4 步链不变（第 1 轮 2 个只读工具、第 2 轮 grep）
 * - 非空 → 第 2 轮单发 `web_fetch`，URL 原样透传给工具（HTTP 层全真实）
 *
 * 每个用例开头都重新设置该变量：共享进程内不依赖上一用例的清理动作。
 */
@Test
public class MockWebFetchGateTest {

    private func setGate(value: String): Unit {
        unsafe {
            setenv(LibC.mallocCString("CJH_MOCK_WEB_URL"), LibC.mallocCString(value), 1)
        }
    }

    private func callOnce(p: MockProvider): ModelResponse {
        let msgs = ArrayList<ChatMessage>()
        let tools = ArrayList<ToolSpec>()
        return p.chatStream(msgs, tools, { _: String => }, { _: String => },
            { _: Int64 => }, { => false })
    }

    /** 主路径：闸门打开 → 第 2 轮发 web_fetch，URL 原样进参数 */
    @TestCase
    public func testGateEmitsWebFetchOnSecondRound(): Unit {
        this.setGate("http://127.0.0.1:9/stall")
        let p = MockProvider("/tmp/cjh_mock_web_gate.txt")
        let r1 = this.callOnce(p)
        @Assert(r1.toolCalls.size, 2)  // 第 1 轮仍是并发 2 个只读工具
        let r2 = this.callOnce(p)
        @Assert(r2.toolCalls.size, 1)
        @Assert(r2.toolCalls[0].name, "web_fetch")
        let urlArg = r2.toolCalls[0].arguments.get("url").getOrThrow()
        @Assert(urlArg.toString().contains("127.0.0.1:9/stall"), true)
        this.setGate("")
    }

    /** 默认关闭：闸门为空时第 2 轮仍是 grep（既有链路不受影响） */
    @TestCase
    public func testGateClosedKeepsGrepStep(): Unit {
        this.setGate("")
        let p = MockProvider("/tmp/cjh_mock_web_gate_off.txt")
        let _ = this.callOnce(p)
        let r2 = this.callOnce(p)
        @Assert(r2.toolCalls.size, 1)
        @Assert(r2.toolCalls[0].name, "grep")
    }
}
