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
        @Assert(cfg.systemPrompt.contains("## Tools"), true)
        // 状态纪律关键词（doing/done 即时标记，防批量补账）
        @Assert(cfg.systemPrompt.contains("todo_write: for multi-step work"), true)
        @Assert(cfg.systemPrompt.contains("mark it doing when started"), true)
        @Assert(cfg.systemPrompt.contains("Never batch-complete at the end"), true)
        // 与派发特性绑定：task 只用于真正独立的工作
        @Assert(cfg.systemPrompt.contains("task: only for genuinely independent work"), true)
        // 并行工具调用：同一响应内批量发独立调用（实测一轮一个工具浪费轮次）
        @Assert(cfg.systemPrompt.contains("Parallel calls:"), true)
        @Assert(cfg.systemPrompt.contains("SAME response"), true)
        // 验证只跑一次：README/文档改动不使已绿的测试失效（实测长任务重复 pytest 4 次）
        @Assert(cfg.systemPrompt.contains("Run each verification once"), true)
        @Assert(cfg.systemPrompt.contains("docs-only edits"), true)
        @Assert(cfg.systemPrompt.contains("instead of rerunning with another wrapper"), true)
        // 范围纪律：小工具任务实测多建 pyproject/LICENSE/venv，白烧数轮
        @Assert(cfg.systemPrompt.contains("Do not add packaging, CI, license files"), true)
        @Assert(cfg.systemPrompt.contains("unless the user asked"), true)
        cleanDir(dir)
    }

    /**
     * 反迎合/证据链规范（修"模型迎合用户、无证据宣称完成"问题）。
     * 锁死 Intellectual honesty 节存在与关键纪律：先质疑后执行、
     * 无工具证据不得宣称完成、失败如实上报、未验证事项明说。
     */
    @TestCase
    public func testDefaultPromptHasHonestyGuidance(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_honesty")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.contains("## Safety and precedence"), true)
        // 先质疑后执行（防迎合式照做）
        @Assert(cfg.systemPrompt.contains("say so with evidence before executing"), true)
        // 不得编造工具输出/测试结果（防"测试都过了"嘴瓢）
        @Assert(cfg.systemPrompt.contains("Never fabricate tool output"), true)
        // 未验证事项必须明说（防静默绕过）
        @Assert(cfg.systemPrompt.contains("If something cannot be verified"), true)
        // 测试是契约：不得改断言让失败测试变绿（需用户批准）
        @Assert(cfg.systemPrompt.contains("Tests are contracts"), true)
        @Assert(cfg.systemPrompt.contains("never rewrite an existing test assertion"), true)
        @Assert(cfg.systemPrompt.contains("requires explicit user approval"), true)
        cleanDir(dir)
    }

    /**
     * 工具名/行为与实现对齐（2026-11-20）：
     * - 实际编辑工具是 `edit`，旧提示词写 `edit_file`（模型可能调用不存在的工具）
     * - read_file 无 offset/limit 时默认只返回 500 行，旧提示词说"加载整文件"
     * - 语言跟随用户，而不是硬编码中文
     */
    @TestCase
    public func testDefaultPromptMatchesToolContracts(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_contract")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.contains("edit: primary way to change an existing file"), true)
        @Assert(cfg.systemPrompt.contains("edit_file"), false)
        @Assert(cfg.systemPrompt.contains("read_file: primary file reader"), true)
        @Assert(cfg.systemPrompt.contains("first 500 lines"), true)
        // 长任务实测：逐次 poll 会把 30s 任务拖成 6 轮工具调用；提示词必须
        // 明确让模型用 wait_ms 一次等完，而不是只靠工具描述。
        @Assert(cfg.systemPrompt.contains("bash_start/bash_poll"), true)
        @Assert(cfg.systemPrompt.contains("wait_ms=60000"), true)
        @Assert(cfg.systemPrompt.contains("Reply in the user's language"), true)
        @Assert(cfg.systemPrompt.contains("answer in Chinese"), false)
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

    /**
     * 读文件口径：禁止对仓库源码逐片 sed，但不写事故故事。
     */
    @TestCase
    public func testDefaultPromptBansSliceReading(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_readfile")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.contains("Never walk a repository source file with repeated `sed -n` slices"), true)
        cleanDir(dir)
    }

    /**
     * 环境块与最终汇报契约：模型不再靠 `pwd` 探测，交付有固定字段。
     */
    @TestCase
    public func testDefaultPromptHasEnvironmentAndReportContract(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_contract2")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.contains("## Environment"), true)
        @Assert(cfg.systemPrompt.contains("## Current environment"), true)
        @Assert(cfg.systemPrompt.contains("## Output contract"), true)
        @Assert(cfg.systemPrompt.contains("list what changed (files)"), true)
        @Assert(cfg.systemPrompt.contains("what you verified (commands and results)"), true)
        @Assert(cfg.systemPrompt.contains("anything you could not verify"), true)
        cleanDir(dir)
    }

    /**
     * 提示词保持英文、紧凑，不把历史事故原文写进系统提示。
     */
    @TestCase
    public func testDefaultPromptStaysCompactAndEnglish(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_compact")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.systemPrompt.size < 5000, true)
        @Assert(cfg.systemPrompt.contains("59 such calls"), false)
        @Assert(cfg.systemPrompt.contains("Every extra token costs time and money"), false)
        @Assert(cfg.systemPrompt.contains("项目指令"), false)
        cleanDir(dir)
    }
}
