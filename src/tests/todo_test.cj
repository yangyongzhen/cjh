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
            },
            { =>
                let refs = ArrayList<TodoRef>()
                var i: Int64 = 0
                while (i < todos.size) {
                    refs.add(TodoRef(i + 1, todos[i]))
                    i += 1
                }
                return refs
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

    private func addTask(tool: TodoWriteTool, content: String): Unit {
        var args = JsonObject()
        args.put("action", JsonString("add"))
        args.put("content", JsonString(content))
        tool.execute(args)
    }

    /**
     * 复现（2026-11-06 E2E 实测）：模型把待办**文本**当 content 传给 done，而不是 id。
     * 旧实现直接报「done 操作缺少参数: id」，模型只能再 list 一轮补 id——63 次 todo_write
     * 调用里有一堆耗在这上面。done 应当接受 content 子串匹配。
     */
    @TestCase
    public func testDoneByContentSubstring(): Unit {
        let (tool, _) = this.buildTool()
        this.addTask(tool, "通读 cspub 仓库结构与技能文档")
        this.addTask(tool, "撰写图文并茂的介绍文章")
        var args = JsonObject()
        args.put("action", JsonString("done"))
        args.put("content", JsonString("撰写"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("#2"), true)
    }

    /** 多命中不得瞎猜：报出候选让模型用 id 指定 */
    @TestCase
    public func testDoneByContentAmbiguous(): Unit {
        let (tool, _) = this.buildTool()
        this.addTask(tool, "撰写文章 A")
        this.addTask(tool, "撰写文章 B")
        var args = JsonObject()
        args.put("action", JsonString("done"))
        args.put("content", JsonString("撰写文章"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("2"), true)
        @Assert(result.content.contains("#1"), true)
        @Assert(result.content.contains("#2"), true)
    }

    /** 无命中给明确提示，不要静默成功 */
    @TestCase
    public func testDoneByContentNotFound(): Unit {
        let (tool, _) = this.buildTool()
        this.addTask(tool, "撰写文章 A")
        var args = JsonObject()
        args.put("action", JsonString("done"))
        args.put("content", JsonString("不存在的待办"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("未找到"), true)
    }

    /** 老路径不回退：给了 id 就按 id 走，不与 content 混用 */
    @TestCase
    public func testDonePrefersIdOverContent(): Unit {
        let (tool, _) = this.buildTool()
        this.addTask(tool, "撰写文章 A")
        this.addTask(tool, "撰写文章 B")
        var args = JsonObject()
        args.put("action", JsonString("done"))
        args.put("id", JsonInt(1))
        args.put("content", JsonString("撰写文章"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("#1"), true)
    }
}
