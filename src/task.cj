package cjh

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjh.agent.*
import cjh.tools.*

/**
 * task 工具: 派发子代理执行独立任务
 *
 * 移植自 omp TaskTool (精简版). omp 的 task 支持 batch/isolation/async 等
 * 高级特性, cjh 砍掉这些, 保留核心: 派发一个子代理, 跑一轮独立对话, 返回结果.
 *
 * 解耦设计 (避免 cjh.tools <-> cjh.agent 循环依赖):
 * TaskTool 只持有 spawnFn 回调, 由 cjh 主包 (entries.cj) 注入实际实现.
 * spawnFn 回调签名: (description, prompt, subagentType) -> resultText
 *
 * 参数:
 * - description: 3-5 词任务标签
 * - prompt: 完整任务指令
 * - subagent_type: "explore" (只读, fast model) 或 "worker" (可写, capable model)
 *
 * 子代理有独立的 messages 历史, 不影响主对话.
 * 子代理 max_iterations 限制为 5 (避免失控).
 *
 * 适用场景:
 * - 并行处理多个独立子任务 (多次 task 调用)
 * - 只读调查 (explore): 不修改文件, 只汇报发现
 * - 隔离执行: 子代理的 todo/工具调用不污染主会话
 */
public class TaskTool <: CjhTool {
    private let spawnFn: (String, String, String) -> TaskSpawnResult

    public init(spawnFn: (String, String, String) -> TaskSpawnResult) {
        this.spawnFn = spawnFn
    }

    public func isReadOnly(): Bool {
        return false  // 子代理可能写文件: V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("description", JsonSchema.str("3-5 word task label"))
        props.add("prompt", JsonSchema.str("Full task instruction for the subagent"))
        props.add("subagent_type", JsonSchema.str("Agent type: explore (read-only, fast) or worker (can write, capable)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["description", "prompt", "subagent_type"]))
        return ToolSpec("task",
            "Delegate a task to a specialized subagent. " +
            "The subagent runs independently with its own message history and returns a result. " +
            "Use for parallel independent subtasks or isolated investigation. " +
            "subagent_type: explore (read-only investigation) or worker (can modify files).",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("description") || !args.containsKey("prompt")) {
            return ToolResult("缺少参数: description/prompt", true)
        }
        let description = args.get("description").getOrThrow().asString().getValue()
        let prompt = args.get("prompt").getOrThrow().asString().getValue()
        var subagentType: String = "explore"
        if (let Some(st) <- args.get("subagent_type")) {
            match (st.kind()) {
                case JsonKind.JsString => subagentType = st.asString().getValue()
                case _ => ()
            }
        }

        try {
            let result = this.spawnFn(description, prompt, subagentType)
            var sb = StringBuilder()
            sb.append("子代理任务完成: ${description}\n")
            sb.append("类型: ${subagentType}\n")
            sb.append("迭代次数: ${result.iterations}\n")
            if (result.promptTokens > 0 || result.completionTokens > 0) {
                sb.append("Token: ↑${result.promptTokens} ↓${result.completionTokens}\n")
            }
            sb.append("\n结果:\n${result.text}\n")
            return ToolResult(sb.toString(), false)
        } catch (e: Exception) {
            return ToolResult("子代理任务失败: ${e}", true)
        }
    }
}

/**
 * 子代理派发结果
 */
public class TaskSpawnResult {
    public let text: String
    public let iterations: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64

    public init(text: String, iterations: Int64, promptTokens: Int64, completionTokens: Int64) {
        this.text = text
        this.iterations = iterations
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
    }
}
