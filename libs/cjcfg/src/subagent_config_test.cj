package cjcfg

import std.fs.*

/**
 * S4 子代理边界配置解析测试（方案C D9 默认值）
 *
 * 覆盖：settings.json 四键解析（max_subagents / max_tasks_per_turn /
 * subagent_token_budget / subagent_timeout_ms）；缺省时用默认值。
 *
 * 仓颉测试坑遵守：临时目录 /tmp/cjh_ut_*；removeIfExists 需 recursive。
 */
@Test
public class SubagentConfigTest {

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
    public func testSubagentLimitsParsed(): Unit {
        let dir = "/tmp/cjh_ut_subagent_cfg"
        cleanDir(dir)
        Directory.create(dir)
        var sb = StringBuilder()
        sb.append("{\"model\": \"m\", \"base_url\": \"https://x/v1\", ")
        sb.append("\"max_subagents\": 2, \"max_tasks_per_turn\": 3, ")
        sb.append("\"subagent_token_budget\": 5000, \"subagent_timeout_ms\": 12345}")
        File.writeTo("${dir}/settings.json", sb.toString().toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.maxSubagents, 2)
        @Assert(cfg.maxTasksPerTurn, 3)
        @Assert(cfg.subagentTokenBudget, 5000)
        @Assert(cfg.subagentTimeoutMs, 12345)
        cleanDir(dir)
    }

    @TestCase
    public func testSubagentLimitsDefaults(): Unit {
        // 缺省：D9 默认值（并发 4 / 每回合 6 / 预算 200k / 超时 300s）
        let dir = "/tmp/cjh_ut_subagent_cfg_def"
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.maxSubagents, 4)
        @Assert(cfg.maxTasksPerTurn, 6)
        @Assert(cfg.subagentTokenBudget, 200000)
        @Assert(cfg.subagentTimeoutMs, 300000)
        cleanDir(dir)
    }
}
