package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.convert.*
import cjllm.ToolSpec

/**
 * TodoWrite 工具：LLM 通过工具调用管理内置任务列表（对齐 Claude Code TodoWrite）
 *
 * 操作语义：
 * - `add`：添加新任务，返回新任务 id
 * - `doing`：标记任务为进行中
 * - `done`：标记任务为已完成
 * - `update`：更新任务内容
 * - `clear`：清空所有任务
 * - `list`：列出所有任务（默认操作）
 *
 * 使用场景：
 * - LLM 在处理复杂多步任务时，先调用 todo_write add 拆解任务
 * - 每完成一步调用 todo_write done 标记完成
 * - 开始下一步调用 todo_write doing 标记进行中
 *
 * UI 联动：Agent.onTodosChanged 回调通知 TUI Tasks 面板实时刷新
 *
 * 解耦设计：cjh.agent 单向依赖 cjh.tools（loop.cj import cjh.tools）。
 * 为避免 cjh.tools → cjh.agent 反向依赖形成循环，
 * TodoWriteTool 不持有 Agent 引用，而是通过回调函数操作任务列表。
 * 回调由 main.cj 在工具注册时注入（绑定到具体 Agent 实例）。
 */
public class TodoWriteTool <: CjhTool {
    // 回调函数（由 main.cj 注入，绑定到 Agent 实例）
    private let _add: (String) -> Int64
    private let _doing: (Int64) -> Unit
    private let _done: (Int64) -> Unit
    private let _update: (Int64, String) -> Unit
    private let _clear: () -> Unit
    private let _list: () -> String

    public init(
        add: (String) -> Int64,
        doing: (Int64) -> Unit,
        done: (Int64) -> Unit,
        update: (Int64, String) -> Unit,
        clear: () -> Unit,
        list: () -> String
    ) {
        this._add = add
        this._doing = doing
        this._done = done
        this._update = update
        this._clear = clear
        this._list = list
    }

    public func isReadOnly(): Bool {
        return false  // 修改任务状态：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("action", JsonSchema.str("操作类型: add|doing|done|update|clear|list"))
        props.add("id", JsonSchema.str("任务 id（doing/done/update 操作必填）"))
        props.add("content", JsonSchema.str("任务内容（add 必填；update 时为新内容）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["action"]))
        return ToolSpec("todo_write",
            "管理内置任务列表（对齐 Claude Code TodoWrite）。" +
            "action=add: 添加任务（content 必填），返回新 id；" +
            "action=doing: 标记任务为进行中（id 必填）；" +
            "action=done: 标记任务为已完成（id 必填）；" +
            "action=update: 更新任务内容（id+content 必填）；" +
            "action=clear: 清空所有任务；" +
            "action=list: 列出所有任务。" +
            "复杂多步任务建议先 add 拆解，每完成一步 done，开始下一步 doing。",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("action")) {
            return ToolResult("缺少参数: action", true)
        }
        let action = args.get("action").getOrThrow().asString().getValue()
        match (action) {
            case "add" =>
                if (!args.containsKey("content")) {
                    return ToolResult("add 操作缺少参数: content", true)
                }
                let content = args.get("content").getOrThrow().asString().getValue()
                let id = this._add(content)
                return ToolResult("已添加任务 #${id}: ${content}", false)
            case "doing" =>
                if (!args.containsKey("id")) {
                    return ToolResult("doing 操作缺少参数: id", true)
                }
                let id = parseInt(args.get("id").getOrThrow())
                this._doing(id)
                return ToolResult("任务 #${id} → in_progress", false)
            case "done" =>
                if (!args.containsKey("id")) {
                    return ToolResult("done 操作缺少参数: id", true)
                }
                let id = parseInt(args.get("id").getOrThrow())
                this._done(id)
                return ToolResult("任务 #${id} → completed", false)
            case "update" =>
                if (!args.containsKey("id") || !args.containsKey("content")) {
                    return ToolResult("update 操作缺少参数: id/content", true)
                }
                let id = parseInt(args.get("id").getOrThrow())
                let content = args.get("content").getOrThrow().asString().getValue()
                this._update(id, content)
                return ToolResult("任务 #${id} 内容已更新: ${content}", false)
            case "clear" =>
                this._clear()
                return ToolResult("已清空任务列表", false)
            case "list" =>
                return ToolResult(this._list(), false)
            case _ =>
                return ToolResult("未知 action: ${action}；支持 add|doing|done|update|clear|list", true)
        }
    }

    /**
     * 从 JsonValue 解析 Int64（支持 int 和 string 类型）
     */
    private func parseInt(v: JsonValue): Int64 {
        match (v.kind()) {
            case JsonKind.JsInt => return v.asInt().getValue()
            case JsonKind.JsString => return Int64.parse(v.asString().getValue())
            case _ => return 0
        }
    }
}
