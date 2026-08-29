package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import stdx.encoding.base64.*
import std.process.*
import std.fs.*
import std.env.*
import cjutil.*
import std.regex.*
import std.io.*
import std.convert.*
import std.sync.*
import cjllm.ToolSpec

/**
 * bash 工具：执行 shell 命令并捕获输出
 *
 * 持久会话（P1-3）：默认走 BashSession（跨命令保留 cwd/env），
 * 超时（P0-1）：默认 60s——git pull/构建/网络命令卡死不会挂起 agent。
 */
public class BashTool <: CjhTool {
    // 默认超时秒数（0=不超时；可用 env CJH_BASH_TIMEOUT 覆盖）
    public let timeoutSecs: Int64
    // 持久会话（P1-3）：true=跨命令保留 cwd/env；false=每次独立 bash -c
    public let useSession: Bool
    // 会话（跨实例共享？registry 单例，实例字段即可）
    private let session: BashSession = BashSession()

    public init() {
        this.timeoutSecs = 60
        this.useSession = true
    }

    public init(timeoutSecs: Int64) {
        this.timeoutSecs = timeoutSecs
        this.useSession = true
    }

    public init(timeoutSecs: Int64, useSession: Bool) {
        this.timeoutSecs = timeoutSecs
        this.useSession = useSession
    }

    public func isReadOnly(): Bool {
        return false  // 有副作用：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("command", JsonSchema.str("Shell command to execute"))
        let schema = JsonSchema.object(props, ArrayList<String>(["command"]))
        return ToolSpec("bash", "Run a shell command (git, build, test, package manager). Do NOT use bash to read files — use read_file instead. bash is for executing commands, not for file content extraction (sed/awk/head/tail are slower and less reliable than read_file). Working directory and env persist across commands. Commands are killed after ${this.timeoutSecs}s by default.", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("command")) {
            return ToolResult("Missing parameter: command", true)
        }
        let cmd = args.get("command").getOrThrow().asString().getValue()
        // 超时配置：构造默认 > env CJH_BASH_TIMEOUT 覆盖
        var secs = this.timeoutSecs
        let envTimeout = getVariable("CJH_BASH_TIMEOUT")
        if (envTimeout.isSome() && envTimeout.getOrThrow().size > 0) {
            try {
                secs = Int64.parse(envTimeout.getOrThrow())
            } catch (e: Exception) {
                ()  // 非法值忽略，用默认
            }
        }
        try {
            if (this.useSession) {
                // 持久会话（P1-3）：跨命令保留 cwd/env
                let (code, output) = this.session.execute(cmd, secs)
                if (code < 0) {
                    return ToolResult(output, true)  // 超时提示
                }
                return ToolResult("exit code: ${code}\nstdout:\n${output}", code != 0)
            }
            // 非会话路径（useSession=false）：timeout 命令包装，base64 传命令
            var argv = Array<String>(2, repeat: "")
            argv[0] = "-c"
            var effective = cmd
            if (secs > 0) {
                let b64 = toBase64String(cmd.toArray())
                // 默认 TERM 信号 → 超时返回 124（--signal=KILL 会返回 137 无法识别）；
                // --kill-after 2s 兜底强杀残留子进程
                effective = "timeout --kill-after=2s ${secs}s bash -c \"\$(echo ${b64} | base64 -d)\""
            }
            argv[1] = effective
            let (code, stdoutBytes, stderrBytes) = executeWithOutput("/bin/bash", argv)
            var out = safeFromUtf8(stdoutBytes)
            var err = safeFromUtf8(stderrBytes)
            if (code == 124 && secs > 0) {
                var result = "⚠️ 命令超时（${secs}s 未完成，已强制终止）\n"
                result += "exit code: 124 (timeout)\n"
                if (out.size > 0) {
                    result += "stdout:\n${out}\n"
                }
                if (err.size > 0) {
                    result += "stderr:\n${err}\n"
                }
                result += "建议：检查命令是否卡死/需交互；必要时拆分为更短步骤或加更长超时（CJH_BASH_TIMEOUT）"
                return ToolResult(result, true)
            }
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
            "Read a file — or any slice of one — from the filesystem. " +
            "This is the PRIMARY way to read files; always prefer it over bash sed/awk/head/tail. " +
            "Returns line-numbered content (format: <N>\\t<content>). " +
            "Call WITHOUT offset/limit first to load the whole file; " +
            "if the file is large (>500 lines), use offset+limit to read a section. " +
            "Example: offset=50 limit=20 reads lines 50-69.",
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
        // SQLite 数据库：P1-7 统一读取接口——.db/.sqlite/.sqlite3 走 sqlite3 CLI
        if (path.endsWith(".db") || path.endsWith(".sqlite") || path.endsWith(".sqlite3")) {
            return this.readSqlite(path, repeatHint)
        }
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
     * SQLite 数据库读取（P1-7，对齐 omp"一切皆路径"）：
     * 返回表列表 + 每表前 sampleRows 行，供模型快速了解库结构。
     * 依赖系统 sqlite3 CLI；不可用时返回明确错误。
     */
    private func readSqlite(path: String, repeatHint: String): ToolResult {
        if (!exists(path)) {
            return ToolResult("读取失败: ${path} 不存在", true)
        }
        let sampleRows: Int64 = 20
        try {
            // 1. 表列表
            var args = Array<String>(2, repeat: "")
            args[0] = path
            args[1] = ".tables"
            let (code1, out1, err1) = executeWithOutput("sqlite3", args)
            if (code1 != 0) {
                let err = safeFromUtf8(err1)
                if (err.contains("not found") || err.contains("No such file")) {
                    return ToolResult("读取 SQLite 失败：系统未安装 sqlite3 CLI。用 bash 安装（apt install sqlite3）或改用其他方式读取。", true)
                }
                return ToolResult("sqlite3 失败: ${err}", true)
            }
            let tablesStr = safeFromUtf8(out1).trimAscii()
            if (tablesStr.size == 0) {
                return ToolResult("数据库无表（${path}）", false)
            }
            var result = StringBuilder()
            result.append("[SQLite 数据库 ${path}]\n表：${tablesStr}\n\n")
            // 2. 每表前 sampleRows 行
            for (t in tablesStr.split(" ")) {
                let table = t.trimAscii()
                if (table.size == 0) {
                    continue
                }
                var qargs = Array<String>(3, repeat: "")
                qargs[0] = path
                qargs[1] = "SELECT * FROM \"${table}\" LIMIT ${sampleRows};"
                qargs[2] = "-header"
                let (code2, out2, err2) = executeWithOutput("sqlite3", qargs)
                if (code2 != 0) {
                    result.append("-- ${table}: 读取失败 ${safeFromUtf8(err2)}\n")
                    continue
                }
                result.append("-- ${table}（前 ${sampleRows} 行）：\n${safeFromUtf8(out2)}\n")
            }
            result.append("\n提示：可继续用 bash sqlite3 查询具体数据")
            if (repeatHint.size > 0) {
                result.append(repeatHint)
            }
            return ToolResult(result.toString(), false)
        } catch (e: Exception) {
            // sqlite3 命令缺失（exec 失败）等：给出可操作的提示
            return ToolResult("SQLite 读取失败：sqlite3 CLI 不可用（${e}）。安装：apt install sqlite3，或用其他工具读取。", true)
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
        // 分段读取提示：已读范围未覆盖全文时，告知总行数 + 剩余 + 下一段 offset
        // 注意：这是 LLM 自己传 offset/limit 导致的分段，不是 read_file 截断
        if (totalLines > 0 && readEnd < totalLines) {
            let remaining = totalLines - readEnd
            hints += "\n[提示] 你用了 offset+limit 分段读取。文件共 ${totalLines} 行，本次读了 ${readStart}-${readEnd}，还剩 ${remaining} 行。用 offset=${readEnd + 1} 读下一段，或省略 offset+limit 一次读全文。"
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
            "Create or overwrite a file. Write the COMPLETE file in ONE call — do not split content into a skeleton + multiple appends. " +
            "Very large content (e.g. a full HTML game, >4000 chars) may be truncated by the model's max_tokens; " +
            "if the file ends up incomplete, continue with append_file to finish it. " +
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
        // 防 LLM 幻觉：拒绝写入纯 ASCII 数字串（如 "6033687967848980..."）
        // 这是 LLM 把字符转 ASCII 码值拼接的幻觉行为，不是合法文件内容
        if (isAsciiDigitGarbage(content)) {
            return ToolResult(
                "ERROR: content looks like ASCII-encoded digit garbage " +
                "(long run of digits with no letters/newlines). " +
                "This usually means you accidentally converted text to ASCII codes. " +
                "Write the ACTUAL file content (HTML/JS/text), not its byte values.",
                true)
        }
        // 软约束：超长 content 警告但不阻断（让 LLM 自行决定是否拆分）
        let lines = content.split('\n').size
        if (content.size > 4000 || lines > 150) {
            try {
                File.writeTo(path, content.toArray())
                return ToolResult("Written ${path} (${content.size} chars).\nWARNING: content exceeds the recommended limit (${lines} lines / ${content.size} chars); risk of max_tokens truncation. If the file turns out incomplete, continue with append_file to finish it.", false)
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
 * 设计动机：write_file 单次调用受 max_tokens 限制，超大文件（5000+ 字符）
 * 可能被截断导致文件不完整（缺 </script></body></html>）。
 * 策略：write_file 一次写完整文件；仅当写入被截断（文件不完整）时，
 * 用 append_file 继续补齐剩余部分——不鼓励主动拆分（拆分多轮低效）。
 */

/**
 * 检测 LLM 幻觉产物：纯 ASCII 数字串
 *
 * LLM 偶尔会把文本转成 ASCII 码值拼接（如 "6033687967848980..."），
 * 再用 write_file/append_file 写入。这种内容是垃圾，应拒绝写入。
 *
 * 判定标准（同时满足）：
 * - 内容长度 > 100（短数字串如 "123" 可能合法）
 * - 字母字符占比 < 1%（正常代码/文本至少有字母）
 * - 换行符数量 < 2（正常代码有多行）
 */
private func isAsciiDigitGarbage(content: String): Bool {
    let n = content.size
    if (n < 100) {
        return false
    }
    var digitCount: Int64 = 0
    var letterCount: Int64 = 0
    var newlineCount: Int64 = 0
    var i = 0
    while (i < n) {
        let c = content[i]
        if (c >= UInt8(48) && c <= UInt8(57)) {  // '0'-'9'
            digitCount += 1
        } else if ((c >= UInt8(65) && c <= UInt8(90)) || (c >= UInt8(97) && c <= UInt8(122))) {  // A-Z, a-z
            letterCount += 1
        } else if (c == UInt8(10)) {  // '\n'
            newlineCount += 1
        }
        i += 1
    }
    // 数字占比 > 80% 且字母占比 < 1% → 纯数字垃圾
    let digitRatio = Float64(digitCount) / Float64(n)
    let letterRatio = Float64(letterCount) / Float64(n)
    return (digitRatio > 0.80 && letterRatio < 0.01 && newlineCount < 2)
}

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
            "Use ONLY to continue a file that a previous write_file call left incomplete (truncated), " +
            "or to add a small piece to an existing file. Do NOT use it as the primary way to write a new file " +
            "-- write_file writes the complete file in one call. " +
            "Fails if the file does not exist -- create it with write_file first.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("content")) {
            return ToolResult("Error: append_file requires both path and content.", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let content = args.get("content").getOrThrow().asString().getValue()
        // 防 LLM 幻觉：拒绝追加纯 ASCII 数字串
        if (isAsciiDigitGarbage(content)) {
            return ToolResult(
                "ERROR: content looks like ASCII-encoded digit garbage " +
                "(long run of digits with no letters/newlines). " +
                "Append the ACTUAL file content (HTML/JS/text), not its byte values.",
                true)
        }
        // OpenMode.Append 对不存在的文件会静默创建，与 spec "Fails if the file does not exist" 不符
        // ——必须显式校验，避免模型以为在补写旧文件、实际悄悄建了新文件
        if (!exists(path)) {
            return ToolResult("Error: cannot append to ${path} (file does not exist). Create it with write_file first.", true)
        }
        try {
            // 增量写：OpenMode.Append 只写新增内容，O(1) 每次调用
            // 不再读全文→拼接→写全文（旧实现 O(n)，大文件极慢）
            let f = File(path, OpenMode.Append)
            f.write(stringToBytes(content))
            f.close()
            return ToolResult("Appended ${content.size} chars to ${path}", false)
        } catch (e: Exception) {
            // 打开失败
            return ToolResult("Error: cannot append to ${path} (file may not exist). Create it with write_file first. Detail: ${e}", true)
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
     *
     * 注意：Directory.walk 是非递归的（只遍历直接子项），且回调返回 false
     * 会终止整个遍历——必须自己显式递归子目录，忽略目录只跳过不终止。
     */
    private func searchDirectory(dirPath: String, regex: Regex, contextLines: Int64, pattern: String): ToolResult {
        let state = GrepWalkState()
        this.searchDirRecursive(dirPath, regex, contextLines, pattern, state)
        if (state.totalCount == 0) {
            return ToolResult("未找到匹配", false)
        }
        return ToolResult("在 ${state.fileCount} 个文件中匹配 ${state.totalCount} 行：\n${state.result.toString()}", false)
    }

    /**
     * 目录树显式递归：walk 只给直接子项，子目录内容需递归进入
     */
    private func searchDirRecursive(dirPath: String, regex: Regex, contextLines: Int64,
        pattern: String, state: GrepWalkState): Unit {
        Directory.walk(dirPath, { fi =>
            let name = fi.name
            if (state.shouldIgnore(name)) {
                return true  // 忽略目录/文件：跳过但继续遍历（返回 false 会终止整个 walk）
            }
            if (fi.isDirectory()) {
                // 递归进入子目录（Directory.walk 非递归，不自动下钻）
                this.searchDirRecursive("${fi.path}", regex, contextLines, pattern, state)
            } else if (state.isTextFile(name)) {
                // 只搜文本文件（跳过二进制）
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
            return true
        })
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
            // 每调用独立状态：静态字段在多线程并发（V2d 并行工具 + 子代理）下会互相踩踏
            let st = ListDirCallState()
            Directory.walk(path, { fi =>
                var line = fi.name
                if (fi.isDirectory()) {
                    line += "/"
                }
                if (st.count < 50) {
                    st.result += line + "\n"
                }
                st.count += 1
                return true
            })
            var extra = ""
            if (st.count > 50) {
                extra = "…（共 ${st.count} 项，仅显示前 50）\n"
            }
            return ToolResult("目录 ${path}（${st.count} 项）：\n${extra}${st.result}", false)
        } catch (e: Exception) {
            return ToolResult("列出目录失败: ${e}", true)
        }
    }
}

class ListDirCallState {
    public var result: String = ""
    public var count: Int64 = 0
}
