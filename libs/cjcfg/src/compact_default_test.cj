package cjcfg

import std.fs.*

/**
 * 压缩 token 阈值缺省契约：128K 上下文模型下 64K 才压缩。
 * 8000 会在短任务频繁压缩（2026-11-21 实测）；32K 对 128K 模型仍偏早（2026-11-23 A/B）。
 */
@Test
public class CompactDefaultTest {
    @TestCase
    public func testDefaultTokenThresholdIs64k(): Unit {
        let dir = testTmpPath("cjh_ut_compact_default")
        if (exists(dir)) {
            try {
                removeIfExists(dir, recursive: true)
            } catch (e: Exception) {
                ()
            }
        }
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.compactTokenThreshold, 64000)
        @Assert(cfg.compactKeep, 6)
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }
}
