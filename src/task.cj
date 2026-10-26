package cjh

import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import cjllm.*
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
/**
 * 子代理路由模式（S5，方案C R1(d)：与 capability 同一哲学——用户开关物理可达）：
 * - "auto"（默认）：模型按判定表自主决定
 * - "on"：同 auto（显式开启）
 * - "off"：task 派发被拒（execute 直接返回提示），子代理物理不可达
 * 启动默认来自 settings subagent_mode；运行时 /parallel on|off|auto 切换。
 */
public class SubagentRouting {
    private static var mode: String = "auto"
    private static let modeLock: Mutex = Mutex()

    public static func set(m: String): Unit {
        modeLock.lock()
        mode = m
        modeLock.unlock()
    }

    public static func current(): String {
        modeLock.lock()
        let m = mode
        modeLock.unlock()
        return m
    }

    /** off = 派发关闭 */
    public static func enabled(): Bool {
        return current() != "off"
    }
}

public class TaskTool <: CjhTool {
    private let spawnFn: (String, String, String, ArrayList<String>) -> TaskSpawnResult

    public init(spawnFn: (String, String, String, ArrayList<String>) -> TaskSpawnResult) {
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
        props.add("scope", JsonSchema.str("Optional comma-separated glob list limiting where this worker may write, e.g. 'src/agent/*.cj, src/web/*.cj'. Workers without scope are serialized with all writers — give scope to enable parallel writes."))
        let schema = JsonSchema.object(props, ArrayList<String>(["description", "prompt", "subagent_type"]))
        return ToolSpec("task",
            "Delegate a task to a specialized subagent (own message history, structured result). " +
            "When to spawn — decide by this table, do NOT spawn for looks:\n" +
            "- Single-file change / clear answer / <=3 tool calls expected: do it YOURSELF (default).\n" +
            "- Repo-wide scan or >=5-file investigation whose answer fits one sentence: spawn 1 explore.\n" +
            "- >=2 independent changes touching DIFFERENT files, each >=3 tool rounds: spawn N workers in ONE turn (they run concurrently).\n" +
            "- Forbidden: spawning just to 'double-check', one worker for one small file, splitting one task into think+write agents.\n" +
            "Limits: <=3 concurrent spawns per turn, <=6 per turn (excess is rejected with budget_exceeded). " +
            "Each spawn costs ~3-5k tokens of fixed overhead (system prompt + tool schemas). " +
            "subagent_type: explore (read-only) or worker (can write).",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        // S5：/parallel off → 派发关闭（物理不可达语义；提示模型直接处理）
        if (!SubagentRouting.enabled()) {
            return ToolResult("并行子代理已关闭（/parallel on 重新开启）。请直接处理本任务。", false)
        }
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

        // 校验 subagent_type
        if (subagentType != "explore" && subagentType != "worker") {
            return ToolResult(
                "无效的 subagent_type: '${subagentType}'.\n" +
                "有效值: explore (只读调查) 或 worker (可写, 完成任务).\n" +
                "默认 explore.", true)
        }

        // 校验 prompt 非空
        if (prompt.size == 0) {
            return ToolResult("prompt 不能为空. 请提供完整的子任务指令.", true)
        }

        // 校验 description 非空
        if (description.size == 0) {
            return ToolResult("description 不能为空. 请提供 3-5 词的任务标签.", true)
        }

        // S6：scope（可选，逗号分隔 glob）——限定 worker 写域并参与 DAG 冲突消解
        let scope = ArrayList<String>()
        if (let Some(sv) <- args.get("scope")) {
            match (sv.kind()) {
                case JsonKind.JsString =>
                    for (raw in sv.asString().getValue().split(",", -1)) {
                        let g = raw.trimAscii()
                        if (g.size > 0) {
                            scope.add(g)
                        }
                    }
                case _ => ()
            }
        }

        try {
            let result = this.spawnFn(description, prompt, subagentType, scope)
            // 树状格式（方案 §8）：子代理作为父消息流里的一个节点呈现
            var sb = StringBuilder()
            sb.append("├─ [${subagentType}] ${description} · ${result.status} · 迭代 ${result.iterations}")
            if (result.promptTokens > 0 || result.completionTokens > 0) {
                sb.append(" · ↑${result.promptTokens} ↓${result.completionTokens}")
            }
            sb.append("\n${result.text}\n└─ (task 结束)\n")
            return ToolResult(sb.toString(), false)
        } catch (e: Exception) {
            return ToolResult(
                "├─ [${subagentType}] ${description} · failed\n子代理任务失败: ${e}\n└─ (task 结束)\n", true)
        }
    }
}

/**
 * 子代理派发结果
 *
 * status 语义（方案 §7）：
 * - ok        正常完成
 * - failed    子代理异常退出 / LLM 调用失败（summary.errorCode 非空）
 * - cancelled 父代理中断传播，子代理提前退出（阶段 B 中断传播落地后出现）
 */
public class TaskSpawnResult {
    public let text: String
    public let iterations: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64
    public var status: String

    public init(text: String, iterations: Int64, promptTokens: Int64, completionTokens: Int64) {
        this.text = text
        this.iterations = iterations
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
        this.status = "ok"
    }

    public init(text: String, iterations: Int64, promptTokens: Int64, completionTokens: Int64,
        status: String) {
        this.text = text
        this.iterations = iterations
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
        this.status = status
    }
}
