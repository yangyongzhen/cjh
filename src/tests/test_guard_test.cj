package cjh.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjh.agent.*

/**
 * 测试契约护栏测试（2026-11-22 实测回归）。
 *
 * 事故：模型测试失败后把测试断言从 == 1 改成 == 2，测试变绿但实现缺陷仍在。
 * 期望：改写测试断言必须走审批；无头模式默认拒绝，TUI/Web 由用户决定。
 */
@Test
public class TestGuardTest {
    @TestCase
    public func testDetectsTestPaths(): Unit {
        @Assert(isTestFilePath("src/tests/foo.cj"), true)
        @Assert(isTestFilePath("/tmp/x/tests/test_ledger.py"), true)
        @Assert(isTestFilePath("src/core_funcs_test.cj"), true)
        @Assert(isTestFilePath("web/app.test.ts"), true)
        @Assert(isTestFilePath("pkg/test_widget.py"), true)
        @Assert(isTestFilePath("src/tools/edit.cj"), false)
        @Assert(isTestFilePath("docs/contest.md"), false)
        @Assert(isTestFilePath("src/latest.py"), false)
    }

    @TestCase
    public func testDetectsAssertions(): Unit {
        @Assert(containsTestAssertion("@Assert(value, 1)"), true)
        @Assert(containsTestAssertion("assert x == 1"), true)
        @Assert(containsTestAssertion("expect(value).toBe(1)"), true)
        @Assert(containsTestAssertion("pytest.raises(ValueError)"), true)
        @Assert(containsTestAssertion("let x = 1"), false)
        @Assert(containsTestAssertion("return value"), false)
    }

    @TestCase
    public func testDetectsEditOfTestAssertion(): Unit {
        let dir = testTempDir("test_guard_detect")
        let path = dir + "/sample_test.cj"
        writeTextFile(path, "@Assert(value, 1)\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("@Assert(value, 1)"))
        args.put("new_string", JsonString("@Assert(value, 2)"))
        let reason = testContractChangeReason("edit", args)
        @Assert(reason.isSome(), true)
        @Assert(reason.getOrThrow().contains("测试断言"), true)
        removeTree(dir)
    }

    @TestCase
    public func testNonAssertionEditOfTestFileAllowed(): Unit {
        let dir = testTempDir("test_guard_non_assert")
        let path = dir + "/sample_test.cj"
        writeTextFile(path, "import foo.*\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("import foo.*"))
        args.put("new_string", JsonString("import bar.*"))
        @Assert(testContractChangeReason("edit", args).isNone(), true)
        removeTree(dir)
    }

    @TestCase
    public func testWriteExistingTestFileWithAssertionDetected(): Unit {
        let dir = testTempDir("test_guard_write")
        let path = dir + "/sample_test.py"
        writeTextFile(path, "def test_x():\n    assert 1 == 1\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("def test_x():\n    assert 1 == 2\n"))
        @Assert(testContractChangeReason("write_file", args).isSome(), true)
        removeTree(dir)
    }

    @TestCase
    public func testAssertionEditDeniedWithoutApproval(): Unit {
        let dir = testTempDir("test_guard_denied")
        let path = dir + "/sample_test.cj"
        writeTextFile(path, "@Assert(value, 1)\n")
        let provider = TestGuardProvider(path, "@Assert(value, 1)", "@Assert(value, 2)")
        let registry = ToolRegistry()
        registry.register(EditTool())
        let agent = Agent(provider, registry, AgentConfig("guard denied", 4))
        let seen = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            seen.add(reason)
            false
        }
        let summary = agent.run("改断言让测试通过")
        @Assert(summary.reply.contains("guard done"), true)
        @Assert(readTextFile(path), "@Assert(value, 1)\n")
        @Assert(seen.size, 1)
        @Assert(seen[0].contains("测试断言"), true)
        var denied = false
        for (m in agent.getMessages()) {
            if (m.role == "tool" && m.content.contains("操作被用户拒绝")) {
                denied = true
            }
        }
        @Assert(denied, true)
        removeTree(dir)
    }

    @TestCase
    public func testAssertionEditAllowedAfterApproval(): Unit {
        let dir = testTempDir("test_guard_allowed")
        let path = dir + "/sample_test.cj"
        writeTextFile(path, "@Assert(value, 1)\n")
        let provider = TestGuardProvider(path, "@Assert(value, 1)", "@Assert(value, 2)")
        let registry = ToolRegistry()
        registry.register(EditTool())
        let agent = Agent(provider, registry, AgentConfig("guard allowed", 4))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, _ =>
            asked.add("asked")
            true
        }
        let summary = agent.run("用户确认改断言")
        @Assert(summary.reply.contains("guard done"), true)
        @Assert(readTextFile(path), "@Assert(value, 2)\n")
        @Assert(asked.size, 1)
        removeTree(dir)
    }

    @TestCase
    public func testNonAssertionTestEditNeedsNoApproval(): Unit {
        let dir = testTempDir("test_guard_no_ask")
        let path = dir + "/sample_test.cj"
        writeTextFile(path, "import foo.*\n")
        let provider = TestGuardProvider(path, "import foo.*", "import bar.*")
        let registry = ToolRegistry()
        registry.register(EditTool())
        let agent = Agent(provider, registry, AgentConfig("guard no ask", 4))
        let asked = ArrayList<String>()
        agent.onApproval = { _, _, _ =>
            asked.add("asked")
            false
        }
        let summary = agent.run("改测试文件导入")
        @Assert(summary.reply.contains("guard done"), true)
        @Assert(readTextFile(path), "import bar.*\n")
        @Assert(asked.size, 0)
        removeTree(dir)
    }
}

/**
 * 第一轮 edit 指定测试文件，后续收场。
 */
class TestGuardProvider <: LlmProvider {
    private let path: String
    private let oldString: String
    private let newString: String
    public var callCount: Int64 = 0

    public init(path: String, oldString: String, newString: String) {
        this.path = path
        this.oldString = oldString
        this.newString = newString
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount == 1) {
            var calls = ArrayList<ToolCall>()
            var args = JsonObject()
            args.put("path", JsonString(this.path))
            args.put("old_string", JsonString(this.oldString))
            args.put("new_string", JsonString(this.newString))
            calls.add(ToolCall("guard_edit", "edit", args))
            return ModelResponse("改测试断言", calls)
        }
        return ModelResponse("guard done", ArrayList<ToolCall>())
    }
}
