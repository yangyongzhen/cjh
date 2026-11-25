package cjcfg

import std.fs.*

/**
 * Anthropic prompt_cache 配置：默认开启，显式 false 可关闭（兼容拒绝 cache_control 的代理），
 * 保存后重新加载必须保持 false；类型非法时忽略、保留默认值。
 */
@Test
public class PromptCacheConfigTest {
    private static func cleanDir(dir: String): Unit {
        if (!exists(dir)) {
            return
        }
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }

    @TestCase
    public func testPromptCacheDefaultsTrueAndRoundTripsFalse(): Unit {
        let dir = testTmpPath("cjh_ut_prompt_cache")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json",
            "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.promptCache, true)

        cfg.promptCache = false
        cfg.saveAll()
        let saved = String.fromUtf8(File.readFrom("${dir}/settings.json"))
        @Assert(saved.contains("\"prompt_cache\": false") || saved.contains("\"prompt_cache\" : false"), true)
        let reloaded = CjhConfig(dir)
        @Assert(reloaded.promptCache, false)
        cleanDir(dir)
    }

    @TestCase
    public func testPromptCacheIgnoresBadType(): Unit {
        let dir = testTmpPath("cjh_ut_prompt_cache_bad")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json",
            "{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"prompt_cache\": \"no\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.promptCache, true)
        cleanDir(dir)
    }
}
