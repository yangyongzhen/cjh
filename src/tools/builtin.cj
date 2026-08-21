package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import std.io.*
import cjllm.ToolSpec

/**
 * bash 工具：执行 shell 命令并捕获输出
 */
public class BashTool <: CjhTool {
    public init() {}

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("command", JsonSchema.str("要执行的 shell 命令"))
        let schema = JsonSchema.object(props, ArrayList<String>(["command"]))
        return ToolSpec("bash", "在本地 shell 中执行命令并返回 stdout/stderr 输出。用于运行构建、测试、git 操作等。", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("command")) {
            return ToolResult("缺少参数: command", true)
        }
        let cmd = args.get("command").getOrThrow().asString().getValue()
        try {
            var args = Array<String>(2, repeat: "")
            args[0] = "-c"
            args[1] = cmd
            let (code, stdoutBytes, stderrBytes) = executeWithOutput("/bin/bash", args)
            var out = String.fromUtf8(stdoutBytes)
            var err = String.fromUtf8(stderrBytes)
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

/**
 * read 工具：读取文件内容
 */
public class ReadTool <: CjhTool {
    public init() {}

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("要读取的文件路径"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("read_file", "读取指定文件的完整内容。用于了解代码、配置等。", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path")) {
            return ToolResult("缺少参数: path", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        try {
            let bytes = File.readFrom(path)
            return ToolResult(String.fromUtf8(bytes), false)
        } catch (e: Exception) {
            return ToolResult("读取失败: ${e}", true)
        }
    }
}

/**
 * write 工具：写入文件内容
 */
public class WriteTool <: CjhTool {
    public init() {}

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("要写入的文件路径"))
        props.add("content", JsonSchema.str("完整的新文件内容"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path", "content"]))
        return ToolSpec("write_file", "将完整内容写入指定文件（覆盖）。用于创建或修改文件。", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("content")) {
            return ToolResult("缺少参数: path/content", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let content = args.get("content").getOrThrow().asString().getValue()
        try {
            File.writeTo(path, content.toArray())
            return ToolResult("已写入 ${path}（${content.size} 字符）", false)
        } catch (e: Exception) {
            return ToolResult("写入失败: ${e}", true)
        }
    }
}
