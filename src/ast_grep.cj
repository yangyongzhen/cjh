package cjh

import std.collection.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import std.convert.*
import cjllm.ToolSpec
import cjh.tools.*
import cjutil.*

/**
 * ast_grep 工具: AST 结构搜索
 *
 * 移植自 omp AstGrepTool. 比 grep 文本搜索更精准, 重构时不可替代.
 *
 * 实现策略:
 * 1. 优先调用 ast-grep CLI (sg 命令)
 * 2. sg 不存在时降级用 grep 近似 (按 pattern 字面匹配)
 *
 * 参数:
 * - pattern: AST 模式 (ast-grep 语法)
 * - lang: 语言 (rust, typescript, python, go, java, c, cangjie 等)
 * - path: 搜索根目录 (默认 cwd)
 * - skip: 跳过前 N 个匹配 (分页用)
 *
 * ast-grep 模式示例:
 * - rust: 'fn $NAME($$$) { $$$ }' 匹配所有函数定义
 * - typescript: 'const $NAME = $$$' 匹配所有 const 声明
 * - python: 'def $NAME($$$): $$$' 匹配所有函数定义
 *
 * 输出格式:
 *   file:line:col: matched text snippet
 */
public class AstGrepTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return true  // 纯读: V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("AST pattern to search for (ast-grep syntax)"))
        props.add("lang", JsonSchema.str("Language: rust, typescript, python, go, java, c, cangjie"))
        props.add("path", JsonSchema.str("Base directory to search in (default: cwd)"))
        props.add("skip", JsonSchema.str("Skip first N matches (pagination)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["pattern", "lang"]))
        return ToolSpec("ast_grep",
            "Search code using AST patterns. More precise than grep for structural queries. " +
            "Requires ast-grep (sg) installed; falls back to grep if unavailable. " +
            "Example: pattern='fn $NAME($$$) { $$$ }' lang='rust' finds all Rust functions.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("pattern") || !args.containsKey("lang")) {
            return ToolResult("缺少参数: pattern/lang", true)
        }
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        let lang = args.get("lang").getOrThrow().asString().getValue()
        var basePath = "."
        if (let Some(p) <- args.get("path")) {
            match (p.kind()) {
                case JsonKind.JsString => basePath = p.asString().getValue()
                case _ => ()
            }
        }
        var skip: Int64 = 0
        if (let Some(s) <- args.get("skip")) {
            match (s.kind()) {
                case JsonKind.JsInt => skip = s.asInt().getValue()
                case JsonKind.JsString => skip = Int64.parse(s.asString().getValue())
                case _ => ()
            }
        }

        if (pattern.size == 0) {
            return ToolResult("pattern 不能为空", true)
        }

        // 尝试用 ast-grep CLI (sg)
        let sgResult = tryAstGrepCli(pattern, lang, basePath, skip)
        match (sgResult) {
            case Some(text) => return ToolResult(text, false)
            case None => ()
        }

        // 降级: 用 grep 按字面 pattern 匹配
        return grepFallback(pattern, basePath, skip)
    }
}

/**
 * 尝试调用 ast-grep CLI (sg 命令)
 *
 * sg 命令格式:
 *   sg run -p 'pattern' -l lang --json path
 *
 * 返回 None 表示 sg 不存在或调用失败, 应降级.
 */
func tryAstGrepCli(pattern: String, lang: String, path: String, skip: Int64): ?String {
    try {
        // 构造 sg 命令参数
        // sg run -p 'pattern' -l lang --json=stream path
        var sgArgs = ArrayList<String>()
        sgArgs.add("run")
        sgArgs.add("-p")
        sgArgs.add(pattern)
        sgArgs.add("-l")
        sgArgs.add(lang)
        // 用 --json=stream 输出结构化 JSON, 方便解析
        sgArgs.add("--json=stream")
        sgArgs.add(path)

        let (code, stdoutBytes, stderrBytes) = executeWithOutput("sg", sgArgs.toArray())

        if (code != 0) {
            // sg 失败, 降级
            return None
        }

        let stdout = safeFromUtf8(stdoutBytes)
        if (stdout.size == 0) {
            return "没有匹配: pattern=${pattern}, lang=${lang}, path=${path}\n"
        }

        // 解析 sg 的 JSON stream 输出
        // 每行是一个 JSON 对象, 包含 file, line, col, text 等字段
        var matches = ArrayList<String>()
        var matchCount: Int64 = 0
        let lines = stdout.split("\n", -1)
        for (line in lines) {
            if (line.size == 0) { continue }
            matchCount += 1
            // 跳过前 skip 个匹配
            if (matchCount <= skip) { continue }
            // 限制最多 50 个匹配
            if (matches.size >= 50) { continue }
            // 尝试解析 JSON 提取 file/line/col
            let parsed = parseSgJsonLine(line)
            match (parsed) {
                case Some(info) => matches.add("${info}")
                case None => matches.add(line)
            }
        }

        var result = StringBuilder()
        if (matches.size == 0) {
            result.append("没有匹配 (跳过 ${skip} 个): pattern=${pattern}\n")
        } else {
            result.append("ast-grep 匹配 ${matches.size} 处 (pattern=${pattern}, lang=${lang}):\n")
            for (m in matches) {
                result.append(m)
                result.append("\n")
            }
            if (matchCount > 50 + skip) {
                result.append("... (共 ${matchCount} 处匹配, 仅显示前 50)\n")
            }
        }
        return result.toString()
    } catch (e: Exception) {
        // sg 不存在或调用异常, 降级
        return None
    }
}

/**
 * 解析 sg --json=stream 的单行 JSON
 *
 * 格式: {"text":"matched","fileName":"src/main.rs","range":{"start":{"line":1,"column":0},"end":{"line":3,"column":1}}}
 * 提取: fileName:line:column: text
 */
func parseSgJsonLine(line: String): ?String {
    try {
        let j = JsonValue.fromStr(line)
        match (j.kind()) {
            case JsonKind.JsObject => ()
            case _ => return None
        }
        let obj = j.asObject()
        var fileName: String = "?"
        var lineNum: Int64 = 0
        var colNum: Int64 = 0
        var text: String = ""
        if (let Some(fn) <- obj.get("fileName")) {
            match (fn.kind()) {
                case JsonKind.JsString => fileName = fn.asString().getValue()
                case _ => ()
            }
        }
        if (let Some(range) <- obj.get("range")) {
            match (range.kind()) {
                case JsonKind.JsObject =>
                    let rangeObj = range.asObject()
                    if (let Some(start) <- rangeObj.get("start")) {
                        match (start.kind()) {
                            case JsonKind.JsObject =>
                                let startObj = start.asObject()
                                if (let Some(l) <- startObj.get("line")) {
                                    match (l.kind()) {
                                        case JsonKind.JsInt => lineNum = l.asInt().getValue()
                                        case _ => ()
                                    }
                                }
                                if (let Some(c) <- startObj.get("column")) {
                                    match (c.kind()) {
                                        case JsonKind.JsInt => colNum = c.asInt().getValue()
                                        case _ => ()
                                    }
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        if (let Some(t) <- obj.get("text")) {
            match (t.kind()) {
                case JsonKind.JsString => text = t.asString().getValue()
                case _ => ()
            }
        }
        // 行号从 0 开始, 转 1-based
        let displayLine = lineNum + 1
        // 截断 text 用于显示 (最多 80 字符)
        var displayText = text.replace("\n", "\\n")
        if (displayText.size > 80) {
            displayText = displayText[0..77] + "..."
        }
        return "${fileName}:${displayLine}:${colNum}: ${displayText}"
    } catch (e: Exception) {
        return None
    }
}

/**
 * grep 降级: 按字面 pattern 匹配
 *
 * ast-grep 不可用时用 grep 近似. 无法理解 AST 结构,
 * 但至少能按 pattern 字面匹配.
 */
func grepFallback(pattern: String, path: String, skip: Int64): ToolResult {
    try {
        // 用 grep -rn 按字面 pattern 搜索
        // 转义 pattern 中的正则元字符
        let escapedPattern = escapeRegex(pattern)
        var grepArgs = ArrayList<String>()
        grepArgs.add("-rn")
        grepArgs.add("--include=*.rs")
        grepArgs.add("--include=*.ts")
        grepArgs.add("--include=*.py")
        grepArgs.add("--include=*.go")
        grepArgs.add("--include=*.java")
        grepArgs.add("--include=*.cj")
        grepArgs.add("--include=*.c")
        grepArgs.add("--include=*.h")
        grepArgs.add(escapedPattern)
        grepArgs.add(path)

        let (code, stdoutBytes, stderrBytes) = executeWithOutput("grep", grepArgs.toArray())
        let stdout = safeFromUtf8(stdoutBytes)

        var matches = ArrayList<String>()
        var matchCount: Int64 = 0
        let lines = stdout.split("\n", -1)
        for (line in lines) {
            if (line.size == 0) { continue }
            matchCount += 1
            if (matchCount <= skip) { continue }
            if (matches.size >= 50) { continue }
            matches.add(line)
        }

        var result = StringBuilder()
        if (matches.size == 0) {
            result.append("没有匹配 (grep 降级, pattern=${pattern}): 可能 ast-grep (sg) 未安装\n")
            result.append("建议安装 ast-grep: https://ast-grep.github.io/\n")
        } else {
            result.append("grep 降级匹配 ${matches.size} 处 (ast-grep 不可用):\n")
            for (m in matches) {
                result.append(m)
                result.append("\n")
            }
        }
        return ToolResult(result.toString(), false)
    } catch (e: Exception) {
        return ToolResult("ast_grep 降级失败: ${e}", true)
    }
}

/**
 * 转义正则元字符, 用于 grep 字面匹配
 */
func escapeRegex(s: String): String {
    // 简单实现: 转义 . * ? + ( ) [ ] { } | \ ^ $
    var sb = StringBuilder()
    let meta = ".*?+()[]{}|\\^$"
    let metaRunes = meta.toRuneArray()
    let metaSet = HashSet<UInt32>()
    for (r in metaRunes) {
        metaSet.add(UInt32(r))
    }
    for (ch in s.toRuneArray()) {
        if (metaSet.contains(UInt32(ch))) {
            sb.append("\\")
        }
        sb.append(ch)
    }
    return sb.toString()
}
