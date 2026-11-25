package cjcfg

import std.fs.*

/**
 * explore 子代理模型路由配置（P1）：
 * explore_* 与 summary_* 分开，避免不支持 tool_call 的摘要模型被误用于调查。
 * 缺省全空 = 复用主 provider（不悄悄改路由）。
 */
@Test
public class ExploreConfigTest {

    private static func writeSettings(dir: String, body: String): Unit {
        if (exists(dir)) {
            try {
                removeIfExists(dir, recursive: true)
            } catch (e: Exception) {
                ()
            }
        }
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", body.toArray())
    }

    @TestCase
    public func testExploreFieldsParsed(): Unit {
        let dir = testTmpPath("cjh_ut_explore_cfg")
        writeSettings(dir, "{\"model\": \"m\", \"base_url\": \"https://x/v1\", " +
            "\"explore_model\": \"fast\", \"explore_base_url\": \"https://fast/v1\", " +
            "\"explore_api_key\": \"k2\"}")
        let cfg = CjhConfig(dir)
        @Assert(cfg.exploreModel, "fast")
        @Assert(cfg.exploreBaseUrl, "https://fast/v1")
        @Assert(cfg.exploreApiKey, "k2")
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }

    @TestCase
    public func testExploreFieldsDefaultEmpty(): Unit {
        let dir = testTmpPath("cjh_ut_explore_cfg_def")
        writeSettings(dir, "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}")
        let cfg = CjhConfig(dir)
        @Assert(cfg.exploreModel, "")
        @Assert(cfg.exploreBaseUrl, "")
        @Assert(cfg.exploreApiKey, "")
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }
}
