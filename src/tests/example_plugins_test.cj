package cjh.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * 第三方风格示例插件加载验证（example/plugins/git-status + tool-result-banner）
 *
 * 目的：示例插件不只是"能跑"，还要锁住 plugin.json 的加载契约——
 * 工具注册、工具执行、钩子改写，防止示例与加载器实现漂移。
 *
 * 定位仓库根：测试进程 cwd = 仓库根（scripts/test.sh 固定 cd 根目录），
 * 带常见开发路径兜底。
 */
@Test
public class ExamplePluginsTest {

    // 仓库根下的示例插件目录（测试进程 cwd = 仓库根）
    private let examplePluginsDir = "example/plugins"

    private func repoRoot(): String {
        // 从 cwd 探测；不可用则用常见开发路径兜底
        let candidates = ArrayList<String>()
        candidates.add("example/plugins")
        candidates.add("/root/test/cj/cjh/example/plugins")
        for (c in candidates) {
            if (exists(c)) {
                return c
            }
        }
        return "example/plugins"
    }

    @TestCase
    public func testGitStatusPluginLoadsAndRuns(): Unit {
        let pluginsDir = this.repoRoot()
        @Assert(exists(pluginsDir + "/git-status/plugin.json"), true)

        let registry = ToolRegistry()
        let pm = PluginManager(pluginsDir)
        pm.loadAll(registry, ArrayList<String>(), false, ArrayList<String>())

        // 加载后注册了 git_status 工具
        @Assert(registry.has("git_status"), true)

        // 执行：在当前目录（仓库内）跑 git 状态摘要
        let result = registry.execute("git_status", JsonObject())
        @Assert(result.isError, false)
        @Assert(result.content.contains("branch:"), true)
        @Assert(result.content.contains("changes:"), true)
        @Assert(result.content.contains("latest:"), true)
    }

    @TestCase
    public func testToolResultBannerHookRewrites(): Unit {
        let pluginsDir = this.repoRoot()
        @Assert(exists(pluginsDir + "/tool-result-banner/plugin.json"), true)

        let pm = PluginManager(pluginsDir)
        pm.loadAll(ToolRegistry(), ArrayList<String>(), false, ArrayList<String>())

        // 钩子已注册
        @Assert(pm.hasHook("on_tool_result"), true)

        // 触发钩子：结果头部应追加 [tool: <name>] 横幅
        var data = JsonObject()
        data.put("tool", JsonString("bash"))
        data.put("content", JsonString("hello world"))
        let rewritten = pm.fireHook("on_tool_result", data)
        @Assert(rewritten.size > 0, true)
        @Assert(rewritten.startsWith("[tool: bash]"), true)
        @Assert(rewritten.contains("hello world"), true)
    }

    @TestCase
    public func testGitStatusRejectsNonRepoPath(): Unit {
        let pluginsDir = this.repoRoot()
        let registry = ToolRegistry()
        let pm = PluginManager(pluginsDir)
        pm.loadAll(registry, ArrayList<String>(), false, ArrayList<String>())

        // 非 git 目录：工具应报错（isError=true）
        // testTempDir 已创建目录（Directory.create 不幂等，勿重复建）
        let tmpDir = testTempDir("plugin_nonrepo")
        var args = JsonObject()
        args.put("path", JsonString(tmpDir))
        let result = registry.execute("git_status", args)
        @Assert(result.isError, true)
        removeTree(tmpDir)
    }
}
