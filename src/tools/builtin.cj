package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import cjutil.*
import std.regex.*
import std.io.*
import std.convert.*
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

/**
 * read 工具：读取文件内容（P1 结构化摘要 + 按需展开）
 *
 * 默认行为：返回结构化摘要（函数名/类名/重要注释），省一半 Token
 *   - 摘要格式：`<line>: <symbol_type> <name>`（symbol_type ∈ func/class|struct|enum|interface|prop|var|let|public|private）
 *   - 大文件（>200 行）只返回摘要；小文件返回全文
 *
 * 按需展开：`offset` + `limit` 参数指定行段
 *   - offset=1, limit=50 → 返回第 1-50 行
 *   - 不带 offset/limit → 返回结构化摘要（大文件）或全文（小文件）
 *
 * 效率收益（omp 实测）：省一半上下文 Token
 */
public class ReadTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("要读取的文件路径"))
        props.add("offset", JsonSchema.str("起始行号（1-based，默认 1）"))
        props.add("limit", JsonSchema.str("返回行数（默认返回结构化摘要或全文）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("read_file",
            "读取文件。默认返回结构化摘要（函数名/类名/注释，省 Token）；" +
            "带 offset+limit 返回指定行段（按需展开）；" +
            "小文件（<200 行）直接返回全文。",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path")) {
            return ToolResult("缺少参数: path", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        try {
            let bytes = File.readFrom(path)
            let content = safeFromUtf8(bytes)
            let lines = content.split("\n", -1)

            // 解析 offset/limit（可选）
            var offset: Int64 = 0
            var limit: Int64 = 0
            if (let Some(o) <- args.get("offset")) {
                match (o.kind()) {
                    case JsonKind.JsString => offset = parseInt(o.asString().getValue())
                    case JsonKind.JsInt => offset = o.asInt().getValue()
                    case _ => ()
                }
            }
            if (let Some(l) <- args.get("limit")) {
                match (l.kind()) {
                    case JsonKind.JsString => limit = parseInt(l.asString().getValue())
                    case JsonKind.JsInt => limit = l.asInt().getValue()
                    case _ => ()
                }
            }

            // 有 offset 或 limit → 按需展开行段
            if (offset > 0 || limit > 0) {
                return readRange(lines, offset, limit)
            }

            // 无 offset/limit：大文件返回摘要，小文件返回全文
            if (lines.size > 200) {
                return readSummary(lines)
            }
            return ToolResult(content, false)
        } catch (e: Exception) {
            return ToolResult("读取失败: ${e}", true)
        }
    }

    /**
     * 按需展开：返回 offset..offset+limit 行段
     */
    private func readRange(lines: Array<String>, offset: Int64, limit: Int64): ToolResult {
        let start = if (offset > 0) { offset - 1 } else { 0 }  // 1-based → 0-based
        let end = if (limit > 0) { start + limit } else { Int64(lines.size) }
        let actualEnd = if (end > Int64(lines.size)) { Int64(lines.size) } else { end }
        if (start >= Int64(lines.size)) {
            return ToolResult("offset ${offset} 超出文件行数 ${lines.size}", true)
        }
        var result = StringBuilder()
        var i = start
        while (i < actualEnd) {
            result.append("${i + 1}\t${lines[i]}\n")
            i += 1
        }
        return ToolResult(result.toString(), false)
    }

    /**
     * 结构化摘要：提取函数/类/结构体/枚举/接口/属性定义
     * 格式：`<line>: <type> <name>` 或 `<line>: <comment>`
     */
    private func readSummary(lines: Array<String>): ToolResult {
        var result = StringBuilder()
        result.append("[结构化摘要：${lines.size} 行，提取符号定义]\n")
        var i: Int64 = 0
        while (i < Int64(lines.size)) {
            let line = lines[i].trimAscii()
            // 跳过空行
            if (line.size == 0) {
                i += 1
                continue
            }
            // 提取符号定义行
            if (isSymbolDefinition(line)) {
                result.append("${i + 1}\t${lines[i]}\n")
            }
            // 提取重要注释（/// 或 // TODO/FIXME/HACK/NOTE）
            else if (line.startsWith("///") || isImportantComment(line)) {
                result.append("${i + 1}\t${lines[i]}\n")
            }
            i += 1
        }
        return ToolResult(result.toString(), false)
    }

    /**
     * 判断是否为符号定义行
     * 匹配：func/class|struct|enum|interface|prop|var|let/public|private + name
     */
    private func isSymbolDefinition(line: String): Bool {
        // 仓颉/Cangjie 关键字
        let keywords = ["func ", "class ", "struct ", "enum ", "interface ", "prop ", "var ", "let ", "public func", "public class", "public struct", "public enum", "public interface", "public prop", "private func", "private class", "private struct", "private enum", "private interface", "private prop", "override func", "static func", "static var", "static let"]
        for (kw in keywords) {
            if (line.startsWith(kw) || line.contains(" ${kw}")) {
                return true
            }
        }
        // 通用语言：def (Python), function (JS), fn (Rust), void|int|bool (C/Java 方法)
        let genericKws = ["def ", "function ", "fn ", "void ", "int ", "bool ", "string ", "export function", "export const", "export default"]
        for (kw in genericKws) {
            if (line.startsWith(kw) || line.contains(" ${kw}")) {
                return true
            }
        }
        return false
    }

    /**
     * 判断是否为重要注释
     * 匹配：// TODO, // FIXME, // HACK, // NOTE, // WARNING
     */
    private func isImportantComment(line: String): Bool {
        let markers = ["// TODO", "// FIXME", "// HACK", "// NOTE", "// WARNING", "// XXX", "/* TODO", "/* FIXME"]
        for (m in markers) {
            if (line.contains(m)) {
                return true
            }
        }
        return false
    }

    /**
     * 字符串转 Int64（解析失败返回 0）
     */
    private func parseInt(s: String): Int64 {
        try {
            return Int64.parse(s)
        } catch (e: Exception) {
            return 0
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
 * grep 工具：在文件或目录树中按正则搜索（P2 进程内 ripgrep 对齐）
 *
 * path 支持文件或目录：
 *   - 文件 → 单文件搜索
 *   - 目录 → 递归搜索目录树
 *
 * gitignore 感知：跳过 .git/node_modules/target/.next/dist 等
 *
 * context 参数：匹配行周围 N 行（默认 0=不显示上下文）
 *
 * 进程内实现：零 fork/exec，和 omp ripgrep 同思路
 */
public class GrepTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("正则表达式（std.regex 语法）"))
        props.add("path", JsonSchema.str("要搜索的文件或目录路径"))
        props.add("context", JsonSchema.str("上下文行数（默认 0=不显示上下文）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["pattern", "path"]))
        return ToolSpec("grep",
            "在文件或目录树中用正则搜索。path 支持文件/目录（目录递归）；" +
            "自动跳过 .git/node_modules/target/dist；" +
            "context 参数控制匹配行周围 N 行。",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("pattern") || !args.containsKey("path")) {
            return ToolResult("缺少参数: pattern/path", true)
        }
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        let path = args.get("path").getOrThrow().asString().getValue()
        var contextLines: Int64 = 0
        if (let Some(c) <- args.get("context")) {
            match (c.kind()) {
                case JsonKind.JsString => contextLines = parseInt(c.asString().getValue())
                case JsonKind.JsInt => contextLines = c.asInt().getValue()
                case _ => ()
            }
        }
        try {
            let regex = Regex(pattern)
            // 判断 path 是文件还是目录
            if (exists(path)) {
                // 尝试作为文件读取；失败则按目录处理
                var isFile: Bool = true
                try {
                    let _ = File.readFrom(path)
                } catch (e: Exception) {
                    isFile = false
                }
                if (isFile) {
                    return searchFile(path, regex, contextLines, pattern)
                } else {
                    return searchDirectory(path, regex, contextLines, pattern)
                }
            } else {
                return ToolResult("路径不存在: ${path}", true)
            }
        } catch (e: Exception) {
            return ToolResult("grep 失败: ${e}", true)
        }
    }

    /**
     * gitignore 感知：跳过常见忽略目录
     */
    private let ignoredDirs: Array<String> = [".git", "node_modules", "target", ".next", "dist", "build", ".cache", "__pycache__", ".venv"]

    /**
     * 判断路径是否应被忽略
     */
    private func shouldIgnore(name: String): Bool {
        for (ignored in ignoredDirs) {
            if (name == ignored) {
                return true
            }
        }
        return false
    }

    /**
     * 搜索单个文件
     */
    private func searchFile(filePath: String, regex: Regex, contextLines: Int64, pattern: String): ToolResult {
        try {
            let content = safeFromUtf8(File.readFrom(filePath))
            let lines = content.split("\n", -1)
            var result = StringBuilder()
            var count: Int64 = 0
            var i: Int64 = 0
            while (i < Int64(lines.size)) {
                let line = lines[i]
                if (regex.matches(line)) {
                    // 显示文件路径（多文件搜索时有用）
                    result.append("${filePath}:${i + 1}: ${line}\n")
                    // 上下文行
                    if (contextLines > 0) {
                        var j: Int64 = i - contextLines
                        while (j <= i + contextLines) {
                            if (j >= 0 && j < Int64(lines.size) && j != i) {
                                result.append("${filePath}:${j + 1}- ${lines[j]}\n")
                            }
                            j += 1
                        }
                    }
                    count += 1
                }
                i += 1
            }
            if (count == 0) {
                return ToolResult("未找到匹配（${pattern}）", false)
            }
            return ToolResult("匹配 ${count} 行：\n${result.toString()}", false)
        } catch (e: Exception) {
            return ToolResult("读取文件失败: ${filePath}: ${e}", true)
        }
    }

    /**
     * 递归搜索目录树
     */
    private func searchDirectory(dirPath: String, regex: Regex, contextLines: Int64, pattern: String): ToolResult {
        let state = GrepWalkState()
        Directory.walk(dirPath, { fi =>
            let name = fi.name
            if (state.shouldIgnore(name)) {
                return false  // 跳过忽略目录
            }
            // 只搜文本文件（跳过二进制）
            if (!fi.isDirectory()) {
                if (state.isTextFile(name)) {
                    try {
                        let content = safeFromUtf8(File.readFrom(fi.path))
                        let lines = content.split("\n", -1)
                        var i: Int64 = 0
                        var hasMatch: Bool = false
                        while (i < Int64(lines.size)) {
                            let line = lines[i]
                            if (regex.matches(line)) {
                                if (!hasMatch) {
                                    state.result.append("\n=== ${fi.path} ===\n")
                                    hasMatch = true
                                    state.fileCount += 1
                                }
                                state.result.append("${i + 1}: ${line}\n")
                                // 上下文行
                                if (contextLines > 0) {
                                    var j: Int64 = i - contextLines
                                    while (j <= i + contextLines) {
                                        if (j >= 0 && j < Int64(lines.size) && j != i) {
                                            state.result.append("${j + 1}- ${lines[j]}\n")
                                        }
                                        j += 1
                                    }
                                }
                                state.totalCount += 1
                            }
                            i += 1
                        }
                    } catch (e: Exception) {
                        // 跳过无法读取的文件
                    }
                }
            }
            return true
        })
        if (state.totalCount == 0) {
            return ToolResult("未找到匹配", false)
        }
        return ToolResult("在 ${state.fileCount} 个文件中匹配 ${state.totalCount} 行：\n${state.result.toString()}", false)
    }

    /**
     * 判断是否为文本文件（按扩展名）
     */
    private func isTextFile(name: String): Bool {
        let textExts = [".cj", ".cjo", ".cjh", ".rs", ".go", ".py", ".js", ".ts", ".tsx", ".jsx",
            ".java", ".c", ".h", ".cpp", ".cc", ".hpp", ".cs", ".rb", ".php", ".swift", ".kt",
            ".scala", ".clj", ".ex", ".exs", ".erl", ".elm", ".lua", ".pl", ".sh", ".bash",
            ".zsh", ".fish", ".ps1", ".bat", ".cmd", ".md", ".markdown", ".rst", ".txt",
            ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".xml", ".html",
            ".css", ".scss", ".sass", ".less", ".vue", ".svelte", ".gradle", ".sbt",
            ".makefile", ".cmake", ".dockerfile", ".gitignore", ".gitattributes"]
        for (ext in textExts) {
            if (name.endsWith(ext)) {
                return true
            }
        }
        // 无扩展名的常见文本文件
        if (name == "Makefile" || name == "Dockerfile" || name == "README" || name == "LICENSE") {
            return true
        }
        return false
    }

    /**
     * 字符串转 Int64（解析失败返回 0）
     */
    private func parseInt(s: String): Int64 {
        try {
            return Int64.parse(s)
        } catch (e: Exception) {
            return 0
        }
    }
}

/**
 * grep 目录递归搜索的可变状态封装
 * 解决仓颉闭包捕获可变变量报错问题
 */
class GrepWalkState {
    public var result: StringBuilder = StringBuilder()
    public var totalCount: Int64 = 0
    public var fileCount: Int64 = 0
    private let ignoredDirs: Array<String> = [".git", "node_modules", "target", ".next", "dist", "build", ".cache", "__pycache__", ".venv"]
    private let textExts: Array<String> = [".cj", ".cjo", ".cjh", ".rs", ".go", ".py", ".js", ".ts", ".tsx", ".jsx",
        ".java", ".c", ".h", ".cpp", ".cc", ".hpp", ".cs", ".rb", ".php", ".swift", ".kt",
        ".scala", ".clj", ".ex", ".exs", ".erl", ".elm", ".lua", ".pl", ".sh", ".bash",
        ".zsh", ".fish", ".ps1", ".bat", ".cmd", ".md", ".markdown", ".rst", ".txt",
        ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".xml", ".html",
        ".css", ".scss", ".sass", ".less", ".vue", ".svelte", ".gradle", ".sbt",
        ".makefile", ".cmake", ".dockerfile", ".gitignore", ".gitattributes"]

    public func shouldIgnore(name: String): Bool {
        for (ignored in ignoredDirs) {
            if (name == ignored) {
                return true
            }
        }
        return false
    }

    public func isTextFile(name: String): Bool {
        for (ext in textExts) {
            if (name.endsWith(ext)) {
                return true
            }
        }
        if (name == "Makefile" || name == "Dockerfile" || name == "README" || name == "LICENSE") {
            return true
        }
        return false
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
