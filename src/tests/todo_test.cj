package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * TodoWriteTool 单元测试：任务增/改/查/清 + 错误参数
 *
 * 通过注入内存回调验证工具与任务列表的交互协议。
 */
@Test
public class TodoWriteToolTest {

    private func buildTool(): (TodoWriteTool, ArrayList<String>) {
        let todos = ArrayList<String>()
        // 仓颉普通参数按位置传递（命名参数需 p! 声明），按 init 参数序传 6 个回调
        let tool = TodoWriteTool(
            { content =>
                todos.add(content)
                return Int64(todos.size)
            },
            { id => () },
            { id => () },
            { id, content =>
                todos[Int64(id - 1)] = content
            },
            { => todos.clear() },
            { =>
                var sb = StringBuilder()
                var i: Int64 = 0
                while (i < todos.size) {
                    sb.append("#${i + 1} ${todos[i]}\n")
                    i += 1
                }
                return sb.toString()
            })
        return (tool, todos)
    }

    @TestCase
    public func testAddAndList(): Unit {
        let (tool, todos) = this.buildTool()
        var args = JsonObject()
        args.put("action", JsonString("add"))
        args.put("content", JsonString("任务A"))
        let addResult = tool.execute(args)
        @Assert(addResult.isError, false)
        @Assert(addResult.content.contains("任务 #1"), true)
        @Assert(todos.size, 1)

        args = JsonObject()
        args.put("action", JsonString("add"))
        args.put("content", JsonString("任务B"))
        tool.execute(args)
        @Assert(todos.size, 2)

        args = JsonObject()
        args.put("action", JsonString("list"))
        let listResult = tool.execute(args)
        @Assert(listResult.isError, false)
        @Assert(listResult.content.contains("任务A"), true)
        @Assert(listResult.content.contains("任务B"), true)
    }

    @TestCase
    public func testAddMissingContent(): Unit {
        let (tool, _) = this.buildTool()
        var args = JsonObject()
        args.put("action", JsonString("add"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testUpdateFlow(): Unit {
        let (tool, todos) = this.buildTool()
        var args = JsonObject()
        args.put("action", JsonString("add"))
        args.put("content", JsonString("旧"))
        tool.execute(args)

        args = JsonObject()
        args.put("action", JsonString("update"))
        args.put("id", JsonInt(1))
        args.put("content", JsonString("新"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(todos[0], "新")
    }

    @TestCase
    public func testClear(): Unit {
        let (tool, todos) = this.buildTool()
        var args = JsonObject()
        args.put("action", JsonString("add"))
        args.put("content", JsonString("x"))
        tool.execute(args)
        @Assert(todos.size, 1)

        args = JsonObject()
        args.put("action", JsonString("clear"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(todos.size, 0)
    }

    @TestCase
    public func testUnknownAction(): Unit {
        let (tool, _) = this.buildTool()
        var args = JsonObject()
        args.put("action", JsonString("frobnicate"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("未知 action"), true)
    }

    @TestCase
    public func testMissingAction(): Unit {
        let (tool, _) = this.buildTool()
        var args = JsonObject()
        args.put("content", JsonString("x"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }
}
