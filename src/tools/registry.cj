package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import cjh.llm.ToolSpec

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
 */
public interface CjhTool {
    public func spec(): ToolSpec
    public func execute(args: JsonObject): ToolResult
}

/**
 * 工具注册中心与分发器
 */
public class ToolRegistry {
    private var tools: HashMap<String, CjhTool> = HashMap<String, CjhTool>()

    public init() {}

    public func register(tool: CjhTool): Unit {
        this.tools.add(tool.spec().name, tool)
    }

    public func specs(): ArrayList<ToolSpec> {
        var list = ArrayList<ToolSpec>()
        for ((_, t) in this.tools) {
            list.add(t.spec())
        }
        return list
    }

    public func has(name: String): Bool {
        return this.tools.contains(name)
    }

    public func execute(name: String, args: JsonObject): ToolResult {
        if (!this.tools.contains(name)) {
            return ToolResult("unknown tool: ${name}", true)
        }
        try {
            let tool = this.tools.get(name).getOrThrow()
            return tool.execute(args)
        } catch (e: Exception) {
            return ToolResult("tool ${name} failed: ${e}", true)
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
