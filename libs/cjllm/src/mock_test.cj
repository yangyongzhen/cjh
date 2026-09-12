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
