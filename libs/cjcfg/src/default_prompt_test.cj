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
        @Assert(cfg.systemPrompt.contains("## Intellectual honesty"), true)
        // 先质疑后执行（防迎合式照做）
        @Assert(cfg.systemPrompt.contains("say so plainly with evidence BEFORE executing"), true)
        // 完成宣称必须有本会话工具证据（防"测试都过了"嘴瓢）
        @Assert(cfg.systemPrompt.contains("must come from a command you just ran"), true)
        // 失败如实上报（防静默绕过）
        @Assert(cfg.systemPrompt.contains("a silent workaround is worse than an honest error"), true)
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
     * 读文件口径（修"轮次预算被 sed 分段扫吃光"问题）。
     *
     * 实测 2026-11-06 16:30：50 轮预算里 59 次 bash 几乎全是
     * `sed -n '595,645p' src/oschina.cj`——每片烧一整轮，任务还没进写作就没预算了。
     * 锁死三条：read_file 一次读完 / 禁止对仓库源码逐片 sed / 例外边界必须写明
     * （管道过滤、超大日志切片、字段提取、脚本内部仍是 sed 的地盘，
     * 一刀切会挡掉合法用法）。
     */
    @TestCase
    public func testDefaultPromptBansSliceReadingButKeepsSedExceptions(): Unit {
        let dir = testTmpPath("cjh_ut_default_prompt_readfile")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        // 正例：read_file 是读文件的主路径
        @Assert(cfg.systemPrompt.contains("read_file is the PRIMARY way to read files"), true)
        // 反例：逐片 sed 扫仓库源码被点名禁止（含"每片烧一整轮"的代价说明）
        @Assert(cfg.systemPrompt.contains("NEVER page a repo source file slice by slice"), true)
        @Assert(cfg.systemPrompt.contains("EVERY slice burns a whole LLM round"), true)
        // 例外边界：禁令只针对"读文件"，不针对 sed 本身
        @Assert(cfg.systemPrompt.contains("That ban is about READING files, not about sed itself"), true)
        @Assert(cfg.systemPrompt.contains("sed as a pipe filter"), true)
        cleanDir(dir)
    }
}
