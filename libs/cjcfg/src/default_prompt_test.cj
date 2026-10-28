/**
 * 默认系统提示词回归：todo_write 使用引导（修"Tasks 面板不弹出"根因）。
 *
 * 背景（2026-10-28）：默认提示词七段规范唯独没有任务列表引导，模型只在
 * 工具描述里看到一句被动"建议"，导致 Tasks 面板几乎不出现（其他 agent
 * 靠系统提示词整段 TodoWrite 规范驱动）。本测试锁死引导段存在，防回归。
 */
package cjcfg

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DefaultSystemPromptTest {
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
    public func testDefaultPromptHasTodoGuidance(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt")
        cleanDir(dir)
        Directory.create(dir)
        // 空 settings.json（无 system_prompt）→ load() 应用默认提示词
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.contains("## Task list (todo_write)"), true)
        // 状态纪律关键词（doing/done 即时标记，防批量补账）
        @Assert(cfg.systemPrompt.contains("keep the list LIVE"), true)
        // 与派发特性绑定：task 派发计入 todo 项
        @Assert(cfg.systemPrompt.contains("Subagent dispatches (task) are todo items"), true)
        cleanDir(dir)
    }

    @TestCase
    public func testCustomPromptOverridesDefault(): Unit {
        // 用户显式配置 system_prompt 时不被默认段污染
        let dir = testTmpPath("cjh_ut_custom_prompt")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"system_prompt\": \"自定义提示词\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt == "自定义提示词", true)
        cleanDir(dir)
    }
}
