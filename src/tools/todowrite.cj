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
/**
 * 待办引用（工具侧视图）：把 agent 的 TodoItem 投影成 id + content。
 *
 * 为什么投影而不是直接用 TodoItem：cjh.agent 单向依赖 cjh.tools，
 * 工具侧反向 import agent 会成环（见 TodowriteTool 头注释的解耦设计）。
 */
public class TodoRef {
    public let id: Int64
    public let content: String

    public init(id: Int64, content: String) {
        this.id = id
        this.content = content
    }
}

/**
 * 按内容子串匹配待办（纯函数，便于单测）。
 *
 * 大小写不敏感（ASCII），两端空白先裁掉——模型常把整句待办文本原样抄回来，
 * 前后带空格或大小写不一致都该算命中。空 needle 不匹配任何项。
 */
public func todoContentMatches(refs: ArrayList<TodoRef>, needle: String): ArrayList<TodoRef> {
    let hits = ArrayList<TodoRef>()
    let key = needle.trimAscii().toAsciiLower()
    if (key.size == 0) {
        return hits
    }
    for (r in refs) {
        if (r.content.toAsciiLower().contains(key)) {
            hits.add(r)
        }
    }
    return hits
}

/** 候选清单文案：最多列 3 条，超出省略（错误信息别刷屏） */
public func describeTodoCandidates(hits: ArrayList<TodoRef>): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    for (h in hits) {
        if (i >= 3) {
            sb.append(" …")
            break
        }
        if (i > 0) {
            sb.append(" / ")
        }
        sb.append("#${h.id} ${h.content}")
        i += 1
    }
    return sb.toString()
}

public class TodoWriteTool <: CjhTool {
    // 回调函数（由 main.cj 注入，绑定到 Agent 实例）
    private let _add: (String) -> Int64
    private let _doing: (Int64) -> Unit
    private let _done: (Int64) -> Unit
    private let _update: (Int64, String) -> Unit
    private let _clear: () -> Unit
    private let _list: () -> String
    // 待办引用快照（done 按内容匹配时用；list 是给人看的文本，别拿它反解析）
    private let _pairs: () -> ArrayList<TodoRef>

    public init(
        add: (String) -> Int64,
        doing: (Int64) -> Unit,
        done: (Int64) -> Unit,
        update: (Int64, String) -> Unit,
        clear: () -> Unit,
        list: () -> String,
        pairs: () -> ArrayList<TodoRef>
    ) {
        this._add = add
        this._doing = doing
        this._done = done
        this._update = update
        this._clear = clear
        this._list = list
        this._pairs = pairs
    }

    public func isReadOnly(): Bool {
        return false  // 修改任务状态：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("action", JsonSchema.str("操作类型: add|doing|done|update|clear|list"))
        props.add("id", JsonSchema.str("任务 id（doing/update 必填；done 可省略，改用 content 匹配）"))
        props.add("content", JsonSchema.str("任务内容（add 必填；update 时为新内容；done 时可填待办文本子串）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["action"]))
        return ToolSpec("todo_write",
            "管理内置任务列表（对齐 Claude Code TodoWrite）。" +
            "action=add: 添加任务（content 必填），返回新 id；" +
            "action=doing: 标记任务为进行中（id 必填）；" +
            "action=done: 标记任务为已完成（id 必填，也可只给 content 子串让工具自己匹配唯一待办）；" +
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
                // 实测（2026-11-06 E2E）：模型常把待办**文本**当 content 传给 done，而不是 id，
                // 旧行为直接报错逼它再 list 一轮补 id。这里先认 id，再按内容子串唯一匹配。
                if (args.containsKey("id")) {
                    let id = parseInt(args.get("id").getOrThrow())
                    this._done(id)
                    return ToolResult("任务 #${id} → completed", false)
                }
                if (args.containsKey("content")) {
                    let needle = args.get("content").getOrThrow().asString().getValue()
                    let hits = todoContentMatches(this._pairs(), needle)
                    if (hits.size == 0) {
                        return ToolResult("done 未找到内容包含「${needle}」的待办；用 action=list 查看现有待办", true)
                    }
                    if (hits.size > 1) {
                        // 多命中不猜：猜错会把没做完的待办标成完成，比报错更糟
                        return ToolResult("done 命中 ${hits.size} 项待办，请改用 id 指定: ${describeTodoCandidates(hits)}", true)
                    }
                    let target = hits[0]
                    this._done(target.id)
                    return ToolResult("任务 #${target.id} → completed（内容匹配: ${target.content}）", false)
                }
                return ToolResult("done 操作缺少参数: id（也可给 content 子串匹配已存在的待办）", true)
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
