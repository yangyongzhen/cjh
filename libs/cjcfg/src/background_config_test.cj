package cjcfg

import std.fs.*

/**
 * B-1 后台任务配置解析测试
 *
 * 覆盖：settings.json 四键解析（max_background_tasks / background_task_timeout_ms /
 * background_output_max_kb / background_poll_max_chars）；缺省用默认值；非整数忽略。
 *
 * 仓颉测试坑遵守：临时目录 /tmp/cjh_ut_*；目录需 recursive 删除。
 */
@Test
public class BackgroundConfigTest {

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
    public func testBackgroundKeysParsed(): Unit {
        let dir = testTmpPath("cjh_ut_bg_cfg")
        cleanDir(dir)
        Directory.create(dir)
        var sb = StringBuilder()
        sb.append("{\"model\": \"m\", \"base_url\": \"https://x/v1\", ")
        sb.append("\"max_background_tasks\": 3, \"background_task_timeout_ms\": 60000, ")
        sb.append("\"background_output_max_kb\": 8, \"background_poll_max_chars\": 1200}")
        File.writeTo("${dir}/settings.json", sb.toString().toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.maxBackgroundTasks, 3)
        @Assert(cfg.backgroundTaskTimeoutMs, 60000)
        @Assert(cfg.backgroundOutputMaxKb, 8)
        @Assert(cfg.backgroundPollMaxChars, 1200)
        cleanDir(dir)
    }

    @TestCase
    public func testBackgroundKeysDefaults(): Unit {
        // 缺省：8 槽位 / 30 分钟 / 256KB / 6000 字节
        let dir = testTmpPath("cjh_ut_bg_cfg_def")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.maxBackgroundTasks, 8)
        @Assert(cfg.backgroundTaskTimeoutMs, 1800000)
        @Assert(cfg.backgroundOutputMaxKb, 256)
        @Assert(cfg.backgroundPollMaxChars, 6000)
        cleanDir(dir)
    }

    /** 非整数（字符串/浮点）一律忽略，保留默认值——不能把槽位解析成 0 个 */
    @TestCase
    public func testBackgroundKeysIgnoreBadType(): Unit {
        let dir = testTmpPath("cjh_ut_bg_cfg_bad")
        cleanDir(dir)
        Directory.create(dir)
        var sb = StringBuilder()
        sb.append("{\"model\": \"m\", \"base_url\": \"https://x/v1\", ")
        sb.append("\"max_background_tasks\": \"three\", \"background_output_max_kb\": 1.5}")
        File.writeTo("${dir}/settings.json", sb.toString().toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.maxBackgroundTasks, 8)
        @Assert(cfg.backgroundOutputMaxKb, 256)
        cleanDir(dir)
    }
}
