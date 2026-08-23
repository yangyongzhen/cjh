package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import std.regex.*
import std.io.*
import cjllm.ToolSpec

/**
 * bash 工具：执行 shell 命令并捕获输出
 */
public class BashTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return false  // 有副作用：V2d 并发执行引擎分类
    }

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

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

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

    public func isReadOnly(): Bool {
        return false  // 写文件：V2d 并发执行引擎分类
    }

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

/**
 * grep 工具：在指定文件中按正则搜索，返回匹配行
 */
public class GrepTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("正则表达式（std.regex 语法）"))
        props.add("path", JsonSchema.str("要搜索的文件路径"))
        let schema = JsonSchema.object(props, ArrayList<String>(["pattern", "path"]))
        return ToolSpec("grep", "在文件中用正则搜索，返回所有匹配行（含行号）。", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("pattern") || !args.containsKey("path")) {
            return ToolResult("缺少参数: pattern/path", true)
        }
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        let path = args.get("path").getOrThrow().asString().getValue()
        try {
            let regex = Regex(pattern)
            let content = String.fromUtf8(File.readFrom(path))
            var result = ""
            var count: Int64 = 0
            var lineNo: Int64 = 1
            let lines = content.split("\n", -1)
            for (line in lines) {
                if (regex.matches(line)) {
                    result += "${lineNo}: ${line}\n"
                    count += 1
                }
                lineNo += 1
            }
            if (count == 0) {
                return ToolResult("未找到匹配（${pattern}）", false)
            }
            return ToolResult("匹配 ${count} 行：\n${result}", false)
        } catch (e: Exception) {
            return ToolResult("grep 失败: ${e}", true)
        }
    }
}

/**
 * list_dir 工具：列出目录内容
 */
public class ListDirTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("要列出的目录路径"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("list_dir", "列出目录下的文件和子目录。用于了解项目结构。", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path")) {
            return ToolResult("缺少参数: path", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        try {
            ListDirState.result = ""
            ListDirState.count = 0
            Directory.walk(path, { fi =>
                var line = fi.name
                if (fi.isDirectory()) {
                    line += "/"
                }
                if (ListDirState.count < 50) {
                    ListDirState.result += line + "\n"
                }
                ListDirState.count += 1
                return true
            })
            var extra = ""
            if (ListDirState.count > 50) {
                extra = "…（共 ${ListDirState.count} 项，仅显示前 50）\n"
            }
            return ToolResult("目录 ${path}（${ListDirState.count} 项）：\n${extra}${ListDirState.result}", false)
        } catch (e: Exception) {
            return ToolResult("列出目录失败: ${e}", true)
        }
    }
}

class ListDirState {
    static var result: String = ""
    static var count: Int64 = 0
}
