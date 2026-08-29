package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import cjllm.ToolSpec

/**
 * edit 工具: str_replace 精确替换
 *
 * 移植自 omp EditTool. 比 hashline_edit 行号锚点更直观,
 * 模型出错率更低. omp 核心编辑工具.
 *
 * 参数:
 * - path: 文件路径
 * - old_string: 要替换的文本(必须精确匹配, 含缩进)
 * - new_string: 替换后的文本
 * - replace_all: 是否替换所有匹配(默认 false, 即要求 old_string 唯一)
 *
 * 安全机制:
 * - old_string 必须在文件中唯一匹配, 否则拒绝(防误改多处)
 * - replace_all=true 时允许匹配多处, 全部替换
 * - old_string 为空时拒绝(避免清空文件)
 * - old_string == new_string 时拒绝(无意义操作)
 *
 * 示例:
 *   edit(path="src/main.cj", old_string="let x = 1", new_string="let x = 2")
 *   edit(path="config.json", old_string="\"debug\": false",
 *        new_string="\"debug\": true", replace_all=true)
 */
public class EditTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return false  // 写文件: V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("File path to edit"))
        props.add("old_string", JsonSchema.str("Text to replace (must match exactly, including whitespace)"))
        props.add("new_string", JsonSchema.str("Replacement text"))
        props.add("replace_all", JsonSchema.str("Replace all occurrences (default: false, requires unique match)"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path", "old_string", "new_string"]))
        return ToolSpec("edit",
            "Edit a file by replacing old_string with new_string. " +
            "old_string must be unique in the file (or set replace_all=true). " +
            "Whitespace and indentation must match exactly. " +
            "Safer than write_file for targeted changes.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("old_string") || !args.containsKey("new_string")) {
            return ToolResult("缺少参数: path/old_string/new_string", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let oldString = args.get("old_string").getOrThrow().asString().getValue()
        let newString = args.get("new_string").getOrThrow().asString().getValue()

        // 解析 replace_all (默认 false)
        var replaceAll: Bool = false
        if (let Some(ra) <- args.get("replace_all")) {
            match (ra.kind()) {
                case JsonKind.JsBool => replaceAll = ra.asBool().getValue()
                case JsonKind.JsString =>
                    let s = ra.asString().getValue()
                    replaceAll = (s == "true" || s == "1")
                case _ => ()
            }
        }

        // 安全检查
        if (oldString.size == 0) {
            return ToolResult("old_string 不能为空", true)
        }
        if (oldString == newString) {
            return ToolResult("old_string 和 new_string 相同, 无需替换", true)
        }

        try {
            // 读取原文件
            let originalBytes = File.readFrom(path)
            let original = String.fromUtf8(originalBytes)

            // 统计 old_string 在文件中的匹配次数
            let matchCount = countOccurrences(original, oldString)

            if (matchCount == 0) {
                return ToolResult("old_string 未在文件中找到. 请检查缩进和空白字符是否精确匹配.", true)
            }

            if (matchCount > 1 && !replaceAll) {
                return ToolResult("old_string 在文件中匹配 ${matchCount} 处, 非唯一. " +
                    "请提供更多上下文使其唯一, 或设置 replace_all=true 替换所有匹配.", true)
            }

            // 执行替换
            let newContent = replaceString(original, oldString, newString, replaceAll)

            // 写回文件
            File.writeTo(path, newContent.toArray())

            // 返回摘要
            var summary = "edit 成功: 替换 ${if (replaceAll) { matchCount } else { 1 }} 处\n"
            summary += "文件: ${path}\n"
            summary += "旧: ${truncateForDisplay(oldString)}\n"
            summary += "新: ${truncateForDisplay(newString)}\n"
            return ToolResult(summary, false)
        } catch (e: Exception) {
            return ToolResult("edit 失败: ${e}", true)
        }
    }
}

/**
 * 统计 substring 在 text 中出现的次数
 */
func countOccurrences(text: String, sub: String): Int64 {
    if (sub.size == 0) {
        return 0
    }
    var count: Int64 = 0
    var i: Int64 = 0
    let tn = text.size
    let sn = sub.size
    while (i <= tn - sn) {
        var found: Bool = true
        var j: Int64 = 0
        while (j < sn) {
            if (text[i + j] != sub[j]) {
                found = false
                break
            }
            j += 1
        }
        if (found) {
            count += 1
            i += sn
        } else {
            i += 1
        }
    }
    return count
}

/**
 * 替换字符串
 * - replaceAll=true: 替换所有匹配
 * - replaceAll=false: 只替换第一个匹配 (调用方已确保唯一性)
 */
func replaceString(text: String, oldStr: String, newStr: String, replaceAll: Bool): String {
    var result = StringBuilder()
    var i: Int64 = 0
    let tn = text.size
    let sn = oldStr.size
    var replaced: Bool = false
    while (i < tn) {
        // 检查从 i 开始是否匹配 oldStr
        if ((!replaced || replaceAll) && i <= tn - sn) {
            var found: Bool = true
            var j: Int64 = 0
            while (j < sn) {
                if (text[i + j] != oldStr[j]) {
                    found = false
                    break
                }
                j += 1
            }
            if (found) {
                result.append(newStr)
                i += sn
                replaced = true
                continue
            }
        }
        result.append(text[i])
        i += 1
    }
    return result.toString()
}

/**
 * 截断字符串用于显示 (最多 80 字符)
 */
func truncateForDisplay(s: String): String {
    if (s.size <= 80) {
        return s
    }
    return s[0..77] + "..."
}
