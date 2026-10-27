package cjh.tests

import std.fs.*
import cjutil.*

import stdx.encoding.json.*
import cjh.tools.*

/**
 * ToolRegistry 单元测试：注册/分发/分类/未知工具
 */
@Test
public class RegistryTest {

    @TestCase
    public func testRegisterAndSpecs(): Unit {
        let registry = ToolRegistry()
        registry.register(BashTool())
        registry.register(ReadTool())
        @Assert(registry.has("bash"), true)
        @Assert(registry.has("read_file"), true)
        @Assert(registry.has("nonexistent"), false)
        // spec 列表包含注册的工具名
        let specs = registry.specs()
        var hasBash = false
        var hasRead = false
        for (s in specs) {
            if (s.name == "bash") { hasBash = true }
            if (s.name == "read_file") { hasRead = true }
        }
        @Assert(hasBash, true)
        @Assert(hasRead, true)
    }

    @TestCase
    public func testExecuteDispatch(): Unit {
        // 用跨平台工具验证 dispatch 链路（原用 bash echo：Windows 上 BashTool 回落
        // PowerShell/无 Git Bash 时报错，测的就不再是 registry 本身了）
        let registry = ToolRegistry()
        registry.register(ReadTool())
        let f = tmpPath("cjh_ut_registry_dispatch.txt")
        try { removeIfExists(f) } catch (e: Exception) { () }
        File.writeTo(f, "dispatched".toArray())
        var args = JsonObject()
        args.put("path", JsonString(f))
        let result = registry.execute("read_file", args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("dispatched"), true)
    }

    @TestCase
    public func testUnknownTool(): Unit {
        let registry = ToolRegistry()
        var args = JsonObject()
        let result = registry.execute("no_such_tool", args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("unknown tool"), true)
    }

    @TestCase
    public func testReadOnlyClassification(): Unit {
        let registry = ToolRegistry()
        registry.register(ReadTool())     // 纯读 → true
        registry.register(BashTool())    // 有副作用 → false
        registry.register(GlobTool())    // 纯读 → true
        @Assert(registry.isReadOnly("read_file"), true)
        @Assert(registry.isReadOnly("glob"), true)
        @Assert(registry.isReadOnly("bash"), false)
        @Assert(registry.isReadOnly("unknown"), false)  // 未知工具保守不并发
    }

    @TestCase
    public func testToolErrorPropagated(): Unit {
        // 工具返回 isError（如读取不存在文件）经 registry 原样透传
        let registry = ToolRegistry()
        registry.register(ReadTool())
        var args = JsonObject()
        args.put("path", JsonString("/nonexistent/cjh/ut/file"))
        let result = registry.execute("read_file", args)
        @Assert(result.isError, true)
    }
}
