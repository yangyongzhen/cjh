package cjh.tests

import std.fs.*
import std.collection.*
import cjutil.*
import cjllm.*

import stdx.encoding.json.*
import cjh.tools.*

/**
 * ToolRegistry 单元测试：注册/分发/分类/未知工具
 */
/**
 * 重名注册探针：同名但行为不同，用于断言先注册者胜。
 */
class DuplicateProbeTool <: CjhTool {
    public func spec(): ToolSpec {
        return ToolSpec("read_file", "probe", JsonObject())
    }
    public func isReadOnly(): Bool { return false }
    public func execute(args: JsonObject): ToolResult {
        return ToolResult("PROBE-REPLACED", false)
    }
}

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
    public func testSpecsAreSortedByName(): Unit {
        // HashMap 迭代无序；工具说明顺序抖动会破坏跨会话的缓存前缀
        let registry = ToolRegistry()
        registry.register(WriteTool())
        registry.register(BashTool())
        registry.register(GlobTool())
        registry.register(ReadTool())
        let specs = registry.specs()
        @Assert(specs.size, 4)
        for (i in 1..specs.size) {
            @Assert(specs[i - 1].name < specs[i].name, true)
        }
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
    public func testCloneToolsIsolatesRegistrations(): Unit {
        // Web 每个会话在浅拷贝上追加 task/todo，不能污染进程级基表
        // （否则 A 会话的 todo 会绑到 A 的 agent，B 会话调到就是串台）
        let base = ToolRegistry()
        base.register(ReadTool())
        let session = base.cloneTools()
        @Assert(session.has("read_file"), true)
        session.register(GlobTool())
        @Assert(session.has("glob"), true)
        @Assert(base.has("glob"), false)
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
    @TestCase
    public func testDuplicateRegistrationKeepsFirst(): Unit {
        // 后加载的插件/技能/MCP 不能静默覆盖内置工具（安全面被替换就绕过审批）
        let registry = ToolRegistry()
        registry.register(ReadTool())
        registry.register(DuplicateProbeTool())
        let f = tmpPath("cjh_ut_registry_dup.txt")
        try { removeIfExists(f) } catch (e: Exception) { () }
        File.writeTo(f, "ORIGINAL".toArray())
        var args = JsonObject()
        args.put("path", JsonString(f))
        let result = registry.execute("read_file", args)
        @Assert(result.content.contains("ORIGINAL"), true)
        @Assert(result.content.contains("PROBE-REPLACED"), false)
    }

    @TestCase
    public func testDeclarativeToolQuotesArguments(): Unit {
        // 声明式工具的 ${x} 是模型可控输入，不能直接拼进 shell：分号/反引号必须变字面量
        @Assert(shellArgQuote("a'b", true), "'a'\\''b'")
        @Assert(shellArgQuote("a'b", false), "'a''b'")
        if (!posixShellAvailable()) { return }
        let dir = testTempDir("decl_quote")
        let marker = dir + "/pwned"
        let specs = HashMap<String, (String, String)>()
        specs.add("x", ("string", "payload"))
        let tool = DeclarativeTool("decl_echo", "echo", "printf '%s' \${x}", specs)
        var args = JsonObject()
        args.put("x", JsonString("safe; touch " + marker))
        let r = tool.execute(args)
        @Assert(r.isError, false)
        @Assert(exists(marker), false)
        @Assert(r.content.contains("safe; touch " + marker), true)
        // 模板里已写成 "${x}"：替换时吃掉引号，输出不应多一层字面单引号
        let tool2 = DeclarativeTool("decl_echo2", "echo", "printf '%s' \"\${x}\"", specs)
        var args2 = JsonObject()
        args2.put("x", JsonString("hello world"))
        let r2 = tool2.execute(args2)
        @Assert(r2.content.contains("hello world"), true)
        @Assert(r2.content.contains("'hello world'"), false)
        // 二次替换回归：两个参数值互含对方占位符。旧实现按 HashMap 顺序逐个 replace，
        // 先插入的值里含另一个占位符，后一次 replace 会把它再次展开，并把命令替换
        // 从单引号里挤出来执行；无论哪个参数先，旧实现必有一个 marker 被创建。
        let nestedDir = testTempDir("decl_nested")
        let markerA = nestedDir + "/a"
        let markerB = nestedDir + "/b"
        let nestedSpecs = HashMap<String, (String, String)>()
        nestedSpecs.add("a", ("string", "a"))
        nestedSpecs.add("b", ("string", "b"))
        let nestedTool = DeclarativeTool("decl_nested", "echo",
            "printf '%s %s' \${a} \${b}", nestedSpecs)
        var nestedArgs = JsonObject()
        nestedArgs.put("a", JsonString("$(touch " + markerA + ")\${b}"))
        nestedArgs.put("b", JsonString("$(touch " + markerB + ")\${a}"))
        let r3 = nestedTool.execute(nestedArgs)
        @Assert(r3.isError, false)
        @Assert(exists(markerA), false)
        @Assert(exists(markerB), false)
        @Assert(r3.content.contains("\${b}"), true)
        @Assert(r3.content.contains("\${a}"), true)
    }

}
