package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import std.process.*
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
 * - edits: 同文件多段替换 [{old_string, new_string, replace_all?}, ...]，
 *   一次调用原子应用。与顶层 old_string/new_string 互斥。
 *
 * 安全机制:
 * - old_string 必须在文件中唯一匹配, 否则拒绝(防误改多处)
 * - replace_all=true 时允许匹配多处, 全部替换
 * - old_string 为空时拒绝(避免清空文件)
 * - old_string == new_string 时拒绝(无意义操作)
 * - edits 任意一段失败则整次调用不写入（原子）
 *
 * 示例:
 *   edit(path="src/main.cj", old_string="let x = 1", new_string="let x = 2")
 *   edit(path="src/main.cj", edits=[
 *       {old_string="let x = 1", new_string="let x = 2"},
 *       {old_string="let y = 3", new_string="let y = 4"}])
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
        props.add("path", JsonSchema.str("Absolute file path to edit (relative paths resolve against the workspace root)"))
        props.add("old_string", JsonSchema.str("Text to replace (must match exactly, including whitespace). Omit when using edits[]."))
        props.add("new_string", JsonSchema.str("Replacement text. Omit when using edits[]."))
        props.add("replace_all", JsonSchema.bool("Replace all occurrences (default: false, requires unique match)"))
        var editProps = HashMap<String, JsonValue>()
        editProps.add("old_string", JsonSchema.str("Text to replace (must match exactly)"))
        editProps.add("new_string", JsonSchema.str("Replacement text"))
        editProps.add("replace_all", JsonSchema.bool("Replace all occurrences of this segment (default: false)"))
        let editItem = JsonSchema.object(editProps, ArrayList<String>(["old_string", "new_string"]))
        props.add("edits", JsonSchema.array(
            "Multiple independent edits in the SAME file, applied in order and atomically. " +
            "Use this instead of several edit calls when changing 2+ separate places.",
            editItem))
        let schema = JsonSchema.object(props, ArrayList<String>(["path"]))
        return ToolSpec("edit",
            "Edit an existing file by replacing old_string with new_string. PRIMARY edit method; prefer over " +
            "bash sed/awk/perl. old_string must be unique (or set replace_all=true); whitespace must match exactly. " +
            "For 2+ separate changes in the same file, pass edits=[{old_string,new_string}, ...] in ONE call: " +
            "all segments are validated first and nothing is written if any fails. " +
            "Safer than a full rewrite for targeted changes.",
            schema)
    }

    /** 兼容 bool 与 "true"/"1" 两种 JSON 传法（模型常把布尔写成字符串）。 */
    private func readBoolFlag(obj: JsonObject, key: String): Bool {
        if (let Some(v) <- obj.get(key)) {
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case JsonKind.JsString =>
                    let s = v.asString().getValue()
                    return s == "true" || s == "1"
                case _ => ()
            }
        }
        return false
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path")) {
            return ToolResult("缺少参数: path", true)
        }
        let path = resolveFilePath(args.get("path").getOrThrow().asString().getValue())

        let hasTopOld = args.containsKey("old_string")
        let hasTopNew = args.containsKey("new_string")
        let hasEdits = args.containsKey("edits")
        if (hasEdits && (hasTopOld || hasTopNew)) {
            return ToolResult("参数冲突: edits[] 与顶层 old_string/new_string 不能同时使用.", true)
        }
        if (!hasEdits && !(hasTopOld && hasTopNew)) {
            return ToolResult("缺少参数: 需要 old_string + new_string，或 edits[]", true)
        }

        // 统一解析成编辑段列表：顶层单段也走同一条原子路径
        var edits = ArrayList<EditOp>()
        if (hasEdits) {
            let editsVal = args.get("edits").getOrThrow()
            match (editsVal.kind()) {
                case JsonKind.JsArray => ()
                case _ => return ToolResult("edits 必须是数组.", true)
            }
            let arr = editsVal.asArray()
            if (arr.size() == 0) {
                return ToolResult("edits 不能为空数组.", true)
            }
            for (idx in 0..arr.size()) {
                let item = arr[idx]
                match (item.kind()) {
                    case JsonKind.JsObject => ()
                    case _ => return ToolResult("edits[${idx}] 必须是对象.", true)
                }
                let obj = item.asObject()
                if (!obj.containsKey("old_string") || !obj.containsKey("new_string")) {
                    return ToolResult("edits[${idx}] 缺少 old_string/new_string.", true)
                }
                let oldS = obj.get("old_string").getOrThrow().asString().getValue()
                let newS = obj.get("new_string").getOrThrow().asString().getValue()
                edits.add(EditOp(oldS, newS, this.readBoolFlag(obj, "replace_all")))
            }
        } else {
            let oldS = args.get("old_string").getOrThrow().asString().getValue()
            let newS = args.get("new_string").getOrThrow().asString().getValue()
            edits.add(EditOp(oldS, newS, this.readBoolFlag(args, "replace_all")))
        }

        // 安全检查（逐段）
        for (idx in 0..edits.size) {
            let op = edits[idx]
            if (op.oldString.size == 0) {
                return ToolResult("edits[${idx}] old_string 不能为空. 如果想清空文件, 请用 write_file 写入空内容.", true)
            }
            if (op.oldString == op.newString) {
                return ToolResult("edits[${idx}] old_string 和 new_string 相同, 无需替换.", true)
            }
        }

        try {
            // 读取原文件
            let originalBytes = File.readFrom(path)
            let original = String.fromUtf8(originalBytes)

            // 先在内存里逐段应用；任一段失败直接返回，文件保持原样（原子）
            var newContent = original
            var totalReplacements: Int64 = 0
            for (idx in 0..edits.size) {
                let op = edits[idx]
                let matchCount = countOccurrences(newContent, op.oldString)
                if (matchCount == 0) {
                    let detail = if (edits.size == 1) {
                        buildNoMatchError(path, original, op.oldString)
                    } else {
                        "edit 失败: edits[${idx}] 的 old_string 未匹配；未写入任何修改。\n" +
                        buildNoMatchError(path, newContent, op.oldString)
                    }
                    return ToolResult(detail, true)
                }
                if (matchCount > 1 && !op.replaceAll) {
                    return ToolResult(
                        "old_string 在文件中匹配 ${matchCount} 处, 非唯一" +
                        (if (edits.size == 1) { "" } else { " (edits[${idx}])" }) + "；未写入任何修改.\n" +
                        "解决方法:\n" +
                        "  1. 在 old_string 中加入更多上下文行, 使其唯一匹配\n" +
                        "  2. 设置 replace_all=true 替换所有匹配处\n" +
                        "注意: old_string 必须精确匹配文件内容, 包括缩进和换行.", true)
                }
                newContent = replaceString(newContent, op.oldString, op.newString, op.replaceAll)
                totalReplacements += if (op.replaceAll) { matchCount } else { 1 }
            }

            // 写回文件 (先写临时文件再重命名, 避免写一半崩溃损坏原文件)
            let tmpPath = path + ".cjh-tmp"
            File.writeTo(tmpPath, newContent.toArray())
            // 仓颉 std.fs 没有直接的 rename, 用 bash mv 原子替换
            try {
                // 先尝试 rename (同分区原子操作)
                renameFile(tmpPath, path)
            } catch (e: Exception) {
                // rename 失败, 回退到 copy + delete
                File.writeTo(path, newContent.toArray())
                removeTmpFile(tmpPath)
            }

            // 返回摘要
            var summary = "edit 成功: 替换 ${totalReplacements} 处\n"
            summary += "文件: ${path}\n"
            if (edits.size == 1) {
                summary += "旧: ${truncateForDisplay(edits[0].oldString)}\n"
                summary += "新: ${truncateForDisplay(edits[0].newString)}\n"
            } else {
                summary += "段数: ${edits.size}\n"
                for (idx in 0..edits.size) {
                    if (idx >= 3) {
                        summary += "  ... 其余 ${edits.size - 3} 段省略\n"
                        break
                    }
                    summary += "  [${idx + 1}] ${truncateForDisplay(edits[idx].oldString)} -> ${truncateForDisplay(edits[idx].newString)}\n"
                }
            }
            return ToolResult(summary, false, buildDiffInfo(path, original, newContent))
        } catch (e: Exception) {
            return ToolResult("edit 失败: ${path}: ${e}", true)
        }
    }
}

/** 单段编辑参数（顶层单段与 edits[] 元素统一走这里）。 */
class EditOp {
    let oldString: String
    let newString: String
    let replaceAll: Bool

    public init(oldString: String, newString: String, replaceAll: Bool) {
        this.oldString = oldString
        this.newString = newString
        this.replaceAll = replaceAll
    }
}

/**
 * 构造 "old_string 未匹配" 的诊断错误信息
 *
 * 帮助模型定位匹配失败的原因:
 * 1. 缩进不匹配 (tab vs 空格)
 * 2. 多行字符串换行符不一致 (\n vs \r\n)
 * 3. old_string 只是文件内容的子串, 缺少前后边界
 *
 * 诊断策略:
 * - 检查 old_string 的首行是否在文件中出现
 * - 如果出现, 提示可能是缩进/空白/换行不一致
 * - 如果未出现, 提示 old_string 可能不存在于文件中
 */
func buildNoMatchError(path: String, original: String, oldString: String): String {
    var sb = StringBuilder()
    sb.append("edit 失败: old_string 未在文件 ${path} 中找到.\n\n")

    // 检查 old_string 的首行是否在文件中出现
    let firstNewline: Int64 = indexOfByte(oldString, 10u8)  // \n
    let firstLine: String = if (firstNewline >= 0) {
        oldString[0..firstNewline]
    } else {
        oldString
    }

    if (firstLine.size == 0) {
        sb.append("old_string 首行为空, 可能多行字符串格式有误.\n")
        return sb.toString()
    }

    // 检查首行是否在文件中出现 (trim 后比较, 忽略首尾空白)
    let trimmedFirst: String = firstLine.trimAscii()
    var foundTrimmed: Bool = false
    var foundExact: Bool = false
    let lines = original.split("\n", -1)
    for (line in lines) {
        if (line == firstLine) {
            foundExact = true
            break
        }
        if (line.trimAscii() == trimmedFirst) {
            foundTrimmed = true
        }
    }

    if (foundExact) {
        sb.append("首行精确匹配, 但完整 old_string 不匹配.\n")
        sb.append("可能原因:\n")
        sb.append("  - 多行 old_string 的后续行不匹配\n")
        sb.append("  - 换行符不一致 (文件用 \\r\\n, old_string 用 \\n)\n")
        sb.append("建议: 用 read_file 读取目标行附近内容, 复制精确文本作为 old_string.\n")
    } else if (foundTrimmed) {
        sb.append("首行内容匹配但空白不一致.\n")
        sb.append("可能原因:\n")
        sb.append("  - 缩进不匹配 (文件用 tab, old_string 用空格, 或相反)\n")
        sb.append("  - 首尾空格/换行不一致\n")
        sb.append("建议: 用 read_file 读取目标行, 复制精确缩进和空白.\n")
    } else {
        sb.append("old_string 首行在文件中未找到.\n")
        sb.append("可能原因:\n")
        sb.append("  - old_string 内容不存在于文件中 (文件可能已被修改)\n")
        sb.append("  - old_string 包含不可见字符 (BOM, 零宽空格等)\n")
        sb.append("建议: 用 read_file 或 grep 确认目标文本确实存在于文件中.\n")
    }

    return sb.toString()
}

/**
 * 查找字节 b 在字符串 s 中首次出现的位置, 未找到返回 -1
 */
func indexOfByte(s: String, b: UInt8): Int64 {
    var i: Int64 = 0
    let n = s.size
    while (i < n) {
        if (s[i] == b) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 重命名文件 (同分区原子操作)
 * 仓颉 std.fs 没有直接的 rename API, 用 Process 调 mv
 */
func renameFile(from: String, to: String): Unit {
    var args = Array<String>(3, repeat: "")
    args[0] = "-c"
    args[1] = "mv -f '" + from + "' '" + to + "'"
    let (code, _, _) = executeWithOutput("/bin/bash", args)
    if (code != 0) {
        throw Exception("rename failed: ${from} -> ${to}")
    }
}

/**
 * 删除临时文件
 */
func removeTmpFile(tmpPath: String): Unit {
    try {
        var args = Array<String>(3, repeat: "")
        args[0] = "-c"
        args[1] = "rm -f '" + tmpPath + "'"
        let _ = executeWithOutput("/bin/bash", args)
    } catch (e: Exception) {
        // 忽略删除失败
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
            // 前进到下一个字符边界（UTF-8 多字节按首字节跳），避免窗口从
            // 多字节字符中间开始导致误匹配
            i += utf8CharLen(text[i])
        }
    }
    return count
}

/**
 * UTF-8 字符字节数（按首字节判断）
 */
func utf8CharLen(firstByte: Byte): Int64 {
    let b = UInt8(firstByte)
    if (b >= 0xF0) { return 4 }
    if (b >= 0xE0) { return 3 }
    if (b >= 0xC0) { return 2 }
    return 1
}

/**
 * 替换字符串
 * - replaceAll=true: 替换所有匹配
 * - replaceAll=false: 只替换第一个匹配 (调用方已确保唯一性)
 */
func replaceString(text: String, oldStr: String, newStr: String, replaceAll: Bool): String {
    // 整段切片替换：text[i] 返回 Byte，逐字节 append 会把字节当整数输出十进制
    // （实测 "let x = 1" 变 "101010810111632..."），必须按 UTF-8 安全的 String 切片整段追加。
    // 切片边界 lastCopy/i 均为匹配边界或 0，不会切在多字节字符中间。
    var result = StringBuilder()
    var i: Int64 = 0
    var lastCopy: Int64 = 0
    let tn = text.size
    let sn = oldStr.size
    while (i <= tn - sn) {
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
            result.append(text[lastCopy..i])  // 未匹配前缀整段拷贝
            result.append(newStr)
            i += sn
            lastCopy = i
            if (!replaceAll) {
                // 只替换第一个：剩余部分整段追加后返回
                result.append(text[lastCopy..tn])
                return result.toString()
            }
        } else {
            // 前进到下一个字符边界：逐字节前进会让 i 落在多字节 UTF-8 字符
            // （如 ×）中间，text[lastCopy..i] 切片抛 Invalid utf8 byte sequence
            i += utf8CharLen(text[i])
        }
    }
    result.append(text[lastCopy..tn])
    return result.toString()
}

/**
 * 截断字符串用于显示 (最多 80 字符)
 */
func truncateForDisplay(s: String): String {
    if (s.size <= 80) {
        return s
    }
    // 字节安全截断：77 字节可能落在多字节 UTF-8 字符中间，递减到合法边界
    var k: Int64 = 77
    while (k > 0) {
        try {
            return s[0..k] + "..."
        } catch (e: Exception) {
            k -= 1
        }
    }
    return "..."
}
