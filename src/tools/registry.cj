package cjh.tools

import std.collection.*
import std.process.*
import std.sync.*
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjutil.*
import cjterm.*
import cjlog.*

/**
 * 工具执行结果
 */
public class ToolResult {
    public let content: String
    public let isError: Bool
    /**
     * 结构化 diff（仅文件改动类工具成功时携带）
     *
     * 文字 content 仍是给人 / 模型看的主体；diff 是给客户端渲染 diff 视图用的
     * 结构化数据（path / unified_diff / before_sha / after_sha，见 textdiff.cj）。
     */
    public let diff: ?DiffInfo

    public init(content: String, isError: Bool) {
        this.content = content
        this.isError = isError
        this.diff = None
    }

    public init(content: String, isError: Bool, diff: ?DiffInfo) {
        this.content = content
        this.isError = isError
        this.diff = diff
    }

    public func toJson(): JsonValue {
        var obj = JsonObject()
        obj.put("content", JsonString(this.content))
        obj.put("is_error", JsonBool(this.isError))
        return obj
    }
}

/**
 * 工具接口：schema 定义 + 执行
 *
 * isReadOnly 分类（V2d 并发执行引擎，对齐 pi/omp/anon-kode Read vs. Write）：
 * - true（read-only）：纯读无副作用，同一批 tool_calls 可并发执行
 * - false（state-modifying）：有写/副作用，整批串行执行避免竞态
 * 默认 false（保守：新工具除非显式声明，否则视为有副作用）
 */
public interface CjhTool {
    func spec(): ToolSpec
    func execute(args: JsonObject): ToolResult
    /**
     * V2d 并发执行引擎分类：true=纯读无副作用（可并发），false=有写/副作用（串行）
     * 默认 false（保守：新工具除非显式 override，否则视为有副作用）
     */
    func isReadOnly(): Bool
}

/**
 * 工具注册中心与分发器
 */
public class ToolRegistry {
    private var tools: HashMap<String, CjhTool> = HashMap<String, CjhTool>()
    // 异步 MCP 加载会在后台协程 register，主线程同时 specs/execute → 加锁保护
    private let lock: Mutex = Mutex()

    public init() {}

    public func register(tool: CjhTool): Unit {
        lock.lock()
        try {
            let name = tool.spec().name
            // 先注册者胜：技能/MCP/插件与内置工具重名时，不允许后加载者静默覆盖
            // 已经过安全审查的内置实现（例如插件注册一个同名 bash 绕过 capability）。
            if (this.tools.contains(name)) {
                Log.warn("工具重名，忽略后注册项: ${name}")
                return
            }
            this.tools.add(name, tool)
        } finally {
            lock.unlock()
        }
    }

    public func specs(): ArrayList<ToolSpec> {
        lock.lock()
        try {
            var list = ArrayList<ToolSpec>()
            for ((_, t) in this.tools) {
                list.add(t.spec())
            }
            return list
        } finally {
            lock.unlock()
        }
    }

    /**
     * 复制一份工具表（共享同一批工具实例，槽位/会话状态仍互通）。
     *
     * Web 每个会话需要往表里追加 agent 专属的 task/todo 工具，
     * 但 bash 会话、后台任务表、MCP 连接必须仍是进程级共享——所以是浅拷贝工具实例，
     * 不是复制工具内部状态。
     */
    public func cloneTools(): ToolRegistry {
        let copy = ToolRegistry()
        this.lock.lock()
        try {
            for ((_, t) in this.tools) {
                copy.register(t)
            }
        } finally {
            this.lock.unlock()
        }
        return copy
    }

    public func has(name: String): Bool {
        lock.lock()
        try {
            return this.tools.contains(name)
        } finally {
            lock.unlock()
        }
    }

    /**
     * 获取工具实例（供工作区切换等场景对工具做运行时操作）
     */
    public func getTool(name: String): ?CjhTool {
        lock.lock()
        try {
            if (!this.tools.contains(name)) {
                return None
            }
            return this.tools.get(name)
        } finally {
            lock.unlock()
        }
    }

    /**
     * 查询工具是否 read-only（V2d 并发执行引擎分类）
     * 工具不存在时返回 false（保守：未知工具不并发）
     */
    public func isReadOnly(name: String): Bool {
        lock.lock()
        try {
            if (!this.tools.contains(name)) {
                return false
            }
            return this.tools.get(name).getOrThrow().isReadOnly()
        } finally {
            lock.unlock()
        }
    }

    public func execute(name: String, args: JsonObject): ToolResult {
        lock.lock()
        let toolOpt: ?CjhTool = if (this.tools.contains(name)) {
            this.tools.get(name)
        } else {
            None
        }
        lock.unlock()
        match (toolOpt) {
            case Some(tool) =>
                try {
                    return tool.execute(args)
                } catch (e: Exception) {
                    return ToolResult("tool ${name} failed: ${e}", true)
                }
            case None =>
                return ToolResult("unknown tool: ${name}", true)
        }
    }
}

/**
 * JSON Schema 工具：构造参数 schema 的辅助
 */
public class JsonSchema {
    public static func object(props: HashMap<String, JsonValue>, required: ArrayList<String>): JsonObject {
        var obj = JsonObject()
        obj.put("type", JsonString("object"))
        var propsJson = JsonObject()
        for ((k, v) in props) {
            propsJson.put(k, v)
        }
        obj.put("properties", propsJson)
        var reqArr = ArrayList<JsonValue>()
        for (r in required) {
            reqArr.add(JsonString(r))
        }
        obj.put("required", JsonArray(reqArr))
        return obj
    }

    public static func str(description: String): JsonValue {
        var obj = JsonObject()
        obj.put("type", JsonString("string"))
        obj.put("description", JsonString(description))
        return obj
    }

    public static func bool(description: String): JsonValue {
        var obj = JsonObject()
        obj.put("type", JsonString("boolean"))
        obj.put("description", JsonString(description))
        return obj
    }

    /** 数组参数：items 是元素 schema，模型按 JSON 数组传值。 */
    public static func array(description: String, items: JsonValue): JsonValue {
        var obj = JsonObject()
        obj.put("type", JsonString("array"))
        obj.put("description", JsonString(description))
        obj.put("items", items)
        return obj
    }
}

/**
 * shell 参数转义：声明式工具把模型可控的参数拼进命令模板时，必须当成数据而不是代码。
 * bash 用单引号包裹（内部 ' 变 '\''）；PowerShell 单引号内用 '' 转义。
 */
public func shellArgQuote(value: String, isBash: Bool): String {
    if (isBash) {
        return shSingleQuote(value)
    }
    return "'" + value.replace("'", "''") + "'"
}

func declarativeArgLiteral(args: JsonObject, name: String, isBash: Bool): String {
    var value = ""
    if (let Some(v) <- args.get(name)) {
        match (v.kind()) {
            case JsonKind.JsString => value = v.asString().getValue()
            case _ => value = v.toJsonString()
        }
    }
    return shellArgQuote(value, isBash)
}

/**
 * 单趟展开声明式命令模板：只在原模板上扫描占位符，参数值插入后不再参与扫描。
 * 不能用「按参数逐个 replace」——先插入的值里若含 `${另一个参数}`，后一次 replace
 * 会把它当占位符再次展开（二次替换），既改变命令语义，也会破坏 shellArgQuote 的引号边界。
 */
func expandDeclarativeCommand(template: String,
    argSpecs: HashMap<String, (String, String)>, args: JsonObject, isBash: Bool): String {
    let out = StringBuilder()
    var cursor = 0
    while (true) {
        var bestIdx: ?Int64 = None
        var bestKey = ""
        var bestPh = ""
        // 每次取原模板中最早出现的占位符；同一位置取更长者，避免参数名前缀互吃。
        for ((k, _) in argSpecs) {
            let ph = "$" + "{" + k + "}"
            match (template.indexOf(ph, cursor)) {
                case Some(idx) =>
                    var take = false
                    match (bestIdx) {
                        case None => take = true
                        case Some(bi) => take = idx < bi || (idx == bi && ph.size > bestPh.size)
                    }
                    if (take) {
                        bestIdx = Some(idx)
                        bestKey = k
                        bestPh = ph
                    }
                case None => ()
            }
        }
        var idx = 0
        match (bestIdx) {
            case Some(i) => idx = i
            case None => break
        }
        let phEnd = idx + bestPh.size
        var start = idx
        var end = phEnd
        // 模板写成 "${x}" / '${x}'：连同占位符两侧的引号一起吃掉，输出不多一层字面引号。
        if (idx > 0 && phEnd < template.size) {
            let q = template[idx - 1]
            if ((q == 34u8 || q == 39u8) && template[phEnd] == q) {
                start = idx - 1
                end = phEnd + 1
            }
        }
        if (start > cursor) {
            out.append(template[cursor..start])
        }
        out.append(declarativeArgLiteral(args, bestKey, isBash))
        cursor = end
    }
    if (cursor < template.size) {
        out.append(template[cursor..])
    }
    return out.toString()
}

/**
 * 声明式工具（Skill 携带的自定义工具，对齐 v2 4.3b 声明式形态）：
 * 由 shell 命令模板 + 参数 schema 声明定义，execute 时展开参数执行。
 * 技能文件 frontmatter 的 tools 段可声明多个此类工具（低门槛，写 Markdown 即贡献）。
 */
public class DeclarativeTool <: CjhTool {
    public let name: String
    public let description: String
    // 命令模板：${argName} 占位符在 execute 时替换为参数值
    public let commandTemplate: String
    // 参数 schema：argName → (type, description)
    public let argSpecs: HashMap<String, (String, String)>

    public init(name: String, description: String, commandTemplate: String,
        argSpecs: HashMap<String, (String, String)>) {
        this.name = name
        this.description = description
        this.commandTemplate = commandTemplate
        this.argSpecs = argSpecs
    }

    /**
     * 声明式工具执行 shell 命令，默认有副作用（V2d 并发执行引擎分类）
     */
    public func isReadOnly(): Bool {
        return false
    }

    public override func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        var required = ArrayList<String>()
        for ((k, spec) in this.argSpecs) {
            var obj = JsonObject()
            obj.put("type", JsonString(spec[0]))
            obj.put("description", JsonString(spec[1]))
            props.add(k, obj)
            required.add(k)
        }
        let schema = JsonSchema.object(props, required)
        return ToolSpec(this.name, this.description, schema)
    }

    public override func execute(args: JsonObject): ToolResult {
        // 平台感知 shell（v1.3.17 起 bash_session / builtin 都走 ShellProvider；
        // 这里原先硬编码 /bin/bash，Windows 上声明式技能工具一调就抛异常，见 issue #1）
        let provider = ShellProvider()
        // 模板展开：${argName} → 参数值；未提供的参数替换为空串。
        // 参数来自模型/用户，必须转义成单个 shell 字面量；否则 `x; rm -rf /` 会被当命令执行。
        // 单趟扫描：参数值里即使含 `${other}` 也不会被二次展开。
        let cmd = expandDeclarativeCommand(this.commandTemplate, this.argSpecs, args,
            provider.isBash)
        try {
            var argv = Array<String>(2, repeat: "")
            if (provider.isBash) {
                argv[0] = "-c"
                argv[1] = cmd
            } else {
                argv[0] = "-Command"
                argv[1] = cmd
            }
            let (code, stdoutBytes, stderrBytes) = executeWithOutput(provider.shellPath, argv)
            var out = safeFromUtf8(stdoutBytes)
            var err = safeFromUtf8(stderrBytes)
            var result = "exit code: ${code}\n"
            if (out.size > 0) {
                result += "stdout:\n${out}\n"
            }
            if (err.size > 0) {
                result += "stderr:\n${err}\n"
            }
            return ToolResult(result, code != 0)
        } catch (e: Exception) {
            return ToolResult("命令执行异常: ${e}", true)
        }
    }
}
