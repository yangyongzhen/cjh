package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import cjutil.*
import std.regex.*
import std.io.*
import std.convert.*
import std.sync.*
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
        props.add("command", JsonSchema.str("Shell command to execute"))
        let schema = JsonSchema.object(props, ArrayList<String>(["command"]))
        return ToolSpec("bash", "Execute a command in the local shell and return combined stdout/stderr. Use for builds, tests, git, etc.", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("command")) {
            return ToolResult("Missing parameter: command", true)
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
    // 重复读追踪：path → 已读次数（静态共享，跨工具实例）
    static let readCountMap: HashMap<String, Int64> = HashMap<String, Int64>()
    static let readCountLock: Mutex = Mutex()

    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("File path to read"))
        props.add("offset", JsonSchema.str("Start line (1-based, default 1)"))
        props.add("limit", JsonSchema.str("Number of lines to return (default: 200 for large files, full for small)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("read_file",
            "Read a file. Returns line-numbered content (format: <N>\\t<content>). " +
            "Default behavior: small files (<200 lines) return full content; " +
            "larger files return the first 200 lines -- use offset+limit to read other sections. " +
            "Pass offset=1 limit=50 to read lines 1-50. " +
            "Avoid reading the same file repeatedly; if you need a different section, use offset+limit.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path")) {
            return ToolResult("缺少参数: path", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
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
        // 重复读计数 + 提示
        let repeatHint = trackReadCount(path)
        // 默认 limit：无 offset/limit 时读前 500 行（够覆盖大多数源文件，省轮次）
        let defaultLimit: Int64 = 500
        try {
            // 大文件优化：用 FileInfo.size 判断，避免 File.readFrom 全文加载
            let fi = FileInfo(path)
            let fileSize = fi.size
            // 大文件阈值：256KB（约 5000-8000 行源码）
            let largeThreshold: Int64 = 262144
            if (fileSize > largeThreshold) {
                // 大文件：流式逐行读取，不加载全文到 Array<String>
                let result = readLargeFile(path, offset, limit)
                return appendHints(result, repeatHint, offset, limit, 0, 0, 0)
            }
            // 小文件：一次读完
            let bytes = File.readFrom(path)
            let content = safeFromUtf8(bytes)
            let lines = content.split("\n", -1)
            let totalLines = Int64(lines.size)
            // 有 offset 或 limit → 按需展开行段
            if (offset > 0 || limit > 0) {
                let result = readRange(lines, offset, limit)
                let readEnd = if (limit > 0) { offset + limit - 1 } else { totalLines }
                return appendHints(result, repeatHint, offset, limit, totalLines, offset, readEnd)
            }
            // 无 offset/limit：大文件默认读前 defaultLimit 行，小文件返回全文
            if (totalLines > defaultLimit) {
                let result = readRange(lines, 1, defaultLimit)
                return appendHints(result, repeatHint, 0, 0, totalLines, 1, defaultLimit)
            }
            // 小文件全文（带行号前缀，与 readRange 格式统一）
            var numbered = StringBuilder()
            var i: Int64 = 0
            while (i < totalLines) {
                numbered.append("${i + 1}\t${lines[i]}\n")
                i += 1
            }
            return appendHints(ToolResult(numbered.toString(), false), repeatHint, 0, 0, totalLines, 1, totalLines)
        } catch (e: Exception) {
            return ToolResult("读取失败: ${e}", true)
        }
    }

    /**
     * 重复读追踪：同一文件读 ≥3 次时返回提示
     * 对齐 omp REPEAT_READ_HINT_THRESHOLD=3
     */
    private func trackReadCount(path: String): String {
        readCountLock.lock()
        var count: Int64 = 0
        match (readCountMap.get(path)) {
            case Some(v) => count = v
            case None => count = 0
        }
        readCountMap[path] = count + 1
        readCountLock.unlock()
        if (count + 1 >= 3) {
            return "\n[提示] 你已读取 ${path} ${count + 1} 次。如需其他段落，请用 offset+limit 指定行范围，避免重复全量读取。"
        }
        return ""
    }

    /**
     * 在工具结果末尾追加提示
     * - 重复读提示（repeatHint）
     * - 截断提示：文件总行数 + 已读范围 + 剩余行数 + 下一段 offset
     *
     * 参数：
     *   totalLines  文件总行数（0 表示未知，如大文件流式扫描）
     *   readStart   本次已读起始行（1-based）
     *   readEnd     本次已读结束行（1-based，含）
     */
    private func appendHints(result: ToolResult, repeatHint: String,
        offset: Int64, limit: Int64, totalLines: Int64,
        readStart: Int64, readEnd: Int64): ToolResult {
        var hints = repeatHint
        // 截断提示：已读范围未覆盖全文时，告知总行数 + 剩余 + 下一段 offset
        if (totalLines > 0 && readEnd < totalLines) {
            let remaining = totalLines - readEnd
            hints += "\n[提示] 文件共 ${totalLines} 行，已读 ${readStart}-${readEnd}，剩余 ${remaining} 行。用 offset=${readEnd + 1} 读取下一段。"
        }
        if (hints.size > 0) {
            return ToolResult(result.content + hints, result.isError)
        }
        return result
    }

    /**
     * 大文件流式读取：逐行扫描，不加载全文到内存
     *
     * 三种模式：
     *   1. 有 offset+limit → 只读 offset..offset+limit 行段
     *   2. 有 offset 无 limit → 从 offset 读到文件末尾
     *   3. 无 offset 无 limit → 流式扫描生成结构化摘要
     */
    private func readLargeFile(path: String, offset: Int64, limit: Int64): ToolResult {
        let f = File(path, OpenMode.Read)
        // 逐字节读取，遇 \n 切行
        var lineBuf = ArrayList<Byte>()
        var lineNum: Int64 = 0
        var result = StringBuilder()
        var collecting: Bool = false
        // 确定起始/结束行
        let startLine = if (offset > 0) { offset - 1 } else { 0 }  // 0-based
        let endLine = if (limit > 0) { startLine + limit } else { Int64(9223372036854775807) }  // Int64.MAX
        // 摘要模式标志
        let summaryMode = (offset == 0 && limit == 0)
        if (summaryMode) {
            result.append("[结构化摘要：大文件流式扫描]\n")
        }
        let readBuf = Array<Byte>(8192, repeat: 0)
        var done: Bool = false
        while (!done) {
            let n = f.read(readBuf)
            if (n <= 0) {
                // EOF：处理最后一行
                if (lineBuf.size > 0) {
                    this.processLine(lineBuf, lineNum, startLine, endLine, summaryMode, result)
                }
                done = true
                break
            }
            for (i in 0..n) {
                let b = readBuf[i]
                if (b == 10u8) {  // \n
                    this.processLine(lineBuf, lineNum, startLine, endLine, summaryMode, result)
                    lineBuf = ArrayList<Byte>()
                    lineNum += 1
                    // 行段模式：超过 endLine 提前结束
                    if (!summaryMode && lineNum >= endLine) {
                        done = true
                        break
                    }
                } else {
                    lineBuf.add(b)
                }
            }
        }
        f.close()
        return ToolResult(result.toString(), false)
    }

    /**
     * 处理单行：根据模式决定收集或跳过
     */
    private func processLine(lineBuf: ArrayList<Byte>, lineNum: Int64,
        startLine: Int64, endLine: Int64, summaryMode: Bool, result: StringBuilder): Unit {
        if (summaryMode) {
            // 摘要模式：提取符号定义行 + 重要注释
            let line = safeFromUtf8(lineBuf.toArray())
            let trimmed = line.trimAscii()
            if (trimmed.size == 0) { return }
            if (isSymbolDefinition(trimmed)) {
                result.append("${lineNum + 1}\t${line}\n")
            } else if (trimmed.startsWith("///") || isImportantComment(trimmed)) {
                result.append("${lineNum + 1}\t${line}\n")
            }
        } else {
            // 行段模式：startLine <= lineNum < endLine 时收集
            if (lineNum >= startLine && lineNum < endLine) {
                let line = safeFromUtf8(lineBuf.toArray())
                result.append("${lineNum + 1}\t${line}\n")
            }
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
        props.add("path", JsonSchema.str("File path to write"))
        props.add("content", JsonSchema.str("File content (overwrites existing)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path", "content"]))
        return ToolSpec("write_file",
            "Create or overwrite a file. WARNING: single-call content must NOT exceed 150 lines / 4000 chars, " +
            "otherwise the model's max_tokens will truncate it and leave the file incomplete. " +
            "Write strategy: (1) small file (HTML/CSS snippet, config, single function) -> write_file in one call; " +
            "(2) large file (full HTML game, multi-function JS, long markdown) -> first use write_file to write the skeleton " +
            "(HTML head + empty body/script tags), then call append_file multiple times to append <style>, <script>, etc. " +
            "path and content MUST be passed together in the same call.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("content")) {
            return ToolResult(
                "Error: write_file requires both path and content. " +
                "Call write_file again with path (file path) and content (full file content) together.",
                true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let content = args.get("content").getOrThrow().asString().getValue()
        // 软约束：超长 content 警告但不阻断（让 LLM 自行决定是否拆分）
        let lines = content.split('\n').size
        if (content.size > 4000 || lines > 150) {
            try {
                File.writeTo(path, content.toArray())
                return ToolResult("Written ${path} (${content.size} chars).\nWARNING: content exceeds the recommended limit (${lines} lines / ${content.size} chars); risk of max_tokens truncation. If the file turns out incomplete, switch to: write_file for the skeleton + append_file for incremental chunks.", false)
            } catch (e: Exception) {
                return ToolResult("Write failed: ${e}", true)
            }
        }
        try {
            File.writeTo(path, content.toArray())
            return ToolResult("Written ${path} (${content.size} chars)", false)
        } catch (e: Exception) {
            return ToolResult("Write failed: ${e}", true)
        }
    }
}

/**
 * append_file 工具：向文件末尾追加内容（增量写入）
 *
 * 设计动机：DeepSeek 等模型单轮 max_tokens 装不下完整 HTML 游戏（通常 5000+ 字符）。
 * 一次性 write_file 会被截断，导致文件不完整（缺 </script></body></html>）。
 * 业界 CLI（Aider/Cursor）的解法：write_file 写骨架，append_file 多段追加。
 *
 * 配合 system prompt 的"骨架 + 增量"写入策略，断绝 LLM 全量重写的死循环。
 */
public class AppendFileTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return false
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("File path to append to (must already exist)"))
        props.add("content", JsonSchema.str("Content to append at end of file"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path", "content"]))
        return ToolSpec("append_file",
            "Append content to the end of an existing file (incremental write). " +
            "Used for multi-chunk writing of large files: first create the skeleton with write_file, " +
            "then call append_file multiple times to append each part. " +
            "Single-call content should stay under 150 lines / 4000 chars; exceeding this risks truncation. " +
            "Fails if the file does not exist -- create it with write_file first.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("content")) {
            return ToolResult("Error: append_file requires both path and content.", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let content = args.get("content").getOrThrow().asString().getValue()
        try {
            // 增量写：OpenMode.Append 只写新增内容，O(1) 每次调用
            // 不再读全文→拼接→写全文（旧实现 O(n)，大文件极慢）
            let f = File(path, OpenMode.Append)
            f.write(stringToBytes(content))
            f.close()
            return ToolResult("Appended ${content.size} chars to ${path}", false)
        } catch (e: Exception) {
            // 文件不存在或打开失败
            return ToolResult("Error: cannot append to ${path} (file may not exist). Create the skeleton with write_file first. Detail: ${e}", true)
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
        props.add("pattern", JsonSchema.str("Regex pattern (std.regex syntax)"))
        props.add("path", JsonSchema.str("File or directory path to search"))
        props.add("context", JsonSchema.str("Context lines around each match (default 0 = no context)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["pattern", "path"]))
        return ToolSpec("grep",
            "Search file(s) or a directory tree with a regex. " +
            "path can be a file or a directory (recursive); " +
            "auto-skips .git/node_modules/target/dist; " +
            "context controls N lines shown around each match.",
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
                // 用 FileInfo.isDirectory 判断，不预读全文（旧实现 File.readFrom 大文件读两遍）
                let fi = FileInfo(path)
                if (!fi.isDirectory()) {
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
        props.add("path", JsonSchema.str("Directory path to list"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("list_dir", "List files and subdirectories under a directory. Use to understand project structure.", schema)
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
