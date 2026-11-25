package cjh.tools

import std.collection.*
import stdx.encoding.json.*

@Test
public class DeclarativeExpandTest {
    @TestCase
    public func testExpansionDoesNotRescanInsertedValues(): Unit {
        // 两个参数值互含对方占位符：先插入的值不能被后一次替换再次展开。
        let specs = HashMap<String, (String, String)>()
        specs.add("a", ("string", "a"))
        specs.add("b", ("string", "b"))
        var args = JsonObject()
        args.put("a", JsonString("\${b}"))
        args.put("b", JsonString("\${a}"))
        let cmd = expandDeclarativeCommand("echo \${a} \${b}", specs, args, true)
        @Assert(cmd, "echo '\${b}' '\${a}'")
    }

    @TestCase
    public func testQuotedPlaceholdersConsumeOneQuotePairEach(): Unit {
        // 模板同时出现双引号、单引号和裸占位符时，每一处都按自己的引号处理。
        let specs = HashMap<String, (String, String)>()
        specs.add("x", ("string", "x"))
        var args = JsonObject()
        args.put("x", JsonString("a'b"))
        let cmd = expandDeclarativeCommand("echo \"\${x}\" '\${x}' \${x}", specs, args, true)
        @Assert(cmd, "echo 'a'\\''b' 'a'\\''b' 'a'\\''b'")
    }

    @TestCase
    public func testUnknownAndMissingPlaceholders(): Unit {
        // 未声明的占位符保持字面量；声明但未提供的参数替换为空 shell 字面量。
        let specs = HashMap<String, (String, String)>()
        specs.add("x", ("string", "x"))
        specs.add("missing", ("string", "missing"))
        var args = JsonObject()
        args.put("x", JsonString("VALUE"))
        let cmd = expandDeclarativeCommand("echo \${unknown} \${x} \${missing}", specs, args, true)
        @Assert(cmd, "echo \${unknown} 'VALUE' ''")
    }
}
