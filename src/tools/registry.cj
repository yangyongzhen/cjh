package cjh.tools

import std.collection.*
import std.process.*
import std.sync.*
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjutil.*

/**
 * 工具执行结果
 */
public class ToolResult {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        this.content = content
        this.isError = isError
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
    public func spec(): ToolSpec
    public func execute(args: JsonObject): ToolResult
    /**
     * V2d 并发执行引擎分类：true=纯读无副作用（可并发），false=有写/副作用（串行）
     * 默认 false（保守：新工具除非显式 override，否则视为有副作用）
     */
    public func isReadOnly(): Bool
}

/**
 * 工具注册中心与分发器
 */
public class ToolRegistry {
    private var tools: HashMap<String, CjhTool> = HashMap<String, CjhTool>()
    // 异步 MCP 加载会在后台协程 register，主线程同时 specs/execute → 加锁保护
    private let lock: ReentrantMutex = ReentrantMutex()

    public init() {}

    public func register(tool: CjhTool): Unit {
        lock.lock()
        try {
            this.tools.add(tool.spec().name, tool)
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

    public func has(name: String): Bool {
        lock.lock()
        try {
            return this.tools.contains(name)
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
        // 模板展开：${argName} → 参数值；未提供的参数替换为空串
        var cmd = this.commandTemplate
        for ((k, _) in this.argSpecs) {
            var value = ""
            if (let Some(v) <- args.get(k)) {
                match (v.kind()) {
                    case JsonKind.JsString => value = v.asString().getValue()
                    case _ => value = v.toJsonString()
                }
            }
            cmd = cmd.replace("${" + k + "}", value)
        }
        try {
            var argv = Array<String>(2, repeat: "")
            argv[0] = "-c"
            argv[1] = cmd
            let (code, stdoutBytes, stderrBytes) = executeWithOutput("/bin/bash", argv)
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
