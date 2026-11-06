package cjh

/**
 * 工具调用参数紧凑显示
 *
 * 从 main.cj 抽出，降低单文件体积。所有符号在 package cjh 内跨文件可见。
 */

import stdx.encoding.json.*
import cjutil.*

/**
 * 工具参数紧凑显示（无大括号）：
 *   bash → 直接展示命令文本：▶ bash cat hello.cpp && ./hello
 *   read/list/write → 直接展示路径：▶ read_file hello.cpp
 *   grep 等多字段 → 主字段值 + 其余 "key: value" 平铺
 * 字符串值取原始文本（避免 toJsonString 的 \u0026 等 JSON 转义），超长截断。
 */
public func formatToolArgs(name: String, args: JsonObject): String {
    let fields = args.getFields()
    if (fields.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    var first: Bool = true
    // 主字段：bash/barge_start→command，bash_poll/kill→task_id，其余→path（直接展示值，无 key 前缀）
    let mainKey = match (name) {
        case "bash" => "command"
        case "bash_start" => "command"
        case "bash_poll" => "task_id"
        case "bash_kill" => "task_id"
        case _ => "path"
    }
    if (let Some(v) <- args.get(mainKey)) {
        sb.append(shortArgValue(v))
        first = false
    }
    // 其余字段：key: value 平铺（无大括号）
    // intent 不进参数行：它已经是条目标题，重复显示只会让两行都变长
    for ((k, v) in fields) {
        if (k == mainKey || k == "intent") {
            continue
        }
        if (!first) {
            sb.append(" ")
        }
        first = false
        sb.append(k)
        sb.append(": ")
        sb.append(shortArgValue(v))
    }
    return sb.toString()
}

/**
 * 单值紧凑显示：字符串取原始文本（无引号/转义），超长截断
 */
public func shortArgValue(v: JsonValue): String {
    var raw = ""
    match (v.kind()) {
        case JsonKind.JsString => raw = v.asString().getValue()
        case _ => raw = v.toJsonString()
    }
    return if (raw.size > 120) { truncateUtf8(raw, 120) + "…" } else { raw }
}

/** 会话流里展示的工具名：bash_start → BashStart（与 atomcode 的写法一致） */
public func displayToolName(name: String): String {
    match (name) {
        case "bash_start" => return "BashStart"
        case "bash_poll" => return "BashPoll"
        case "bash_kill" => return "BashKill"
        case _ => return name
    }
}

/**
 * 后台三件套判定：只有这三个工具的调用走「● 标题 + └ 调用」两行式。
 *
 * 其余工具维持单行 `▶ name args`——它们的结果本身就是用户要看的内容，
 * 多一行标题只是噪音；后台调用恰恰相反：命令很长、用户在等结果，先用
 * 一句话说清"这次在干嘛"比读命令行有用。
 */
public func isBgTool(name: String): Bool {
    return name == "bash_start" || name == "bash_poll" || name == "bash_kill"
}

/**
 * 后台调用在会话流里的条目标题。
 *
 * 优先级：intent（模型填的一句话）→ bash_start 的 label / 命令首行
 * → poll/kill 按任务 ID 的模板。三级回退保证任何一次调用都有可读标题，
 * 即使模型没填 intent（intent 是可选参数，不能指望每次都有）。
 */
public func bgToolTitle(name: String, args: JsonObject): String {
    let intent = tfStrArg(args, "intent").trimAscii()
    if (intent.size > 0) {
        return tfClip(intent, 120)
    }
    match (name) {
        case "bash_start" =>
            let label = tfStrArg(args, "label").trimAscii()
            if (label.size > 0) {
                return tfClip(label, 120)
            }
            let cmd = tfFirstLine(tfStrArg(args, "command"))
            if (cmd.size > 0) {
                return tfClip(cmd, 120)
            }
            return "后台执行命令"
        case "bash_poll" =>
            let id = tfStrArg(args, "task_id").trimAscii()
            return if (id.size > 0) { "取 ${id} 的新增输出" } else { "取后台任务输出" }
        case "bash_kill" =>
            let id = tfStrArg(args, "task_id").trimAscii()
            return if (id.size > 0) { "结束 ${id}" } else { "结束后台任务" }
        case _ => return displayToolName(name)
    }
}

/** 取参数为字符串（缺失 → 空串）：标题逻辑不必到处 match JsonValue */
func tfStrArg(args: JsonObject, key: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return v.toJsonString()
            }
        case None => return ""
    }
}

/** 命令首行（标题回退用）：多行命令只取第一条非空行 */
func tfFirstLine(s: String): String {
    for (line in s.split("\n", -1)) {
        let t = line.trimAscii()
        if (t.size > 0) {
            return t
        }
    }
    return ""
}

func tfClip(s: String, maxBytes: Int64): String {
    return if (Int64(s.size) > maxBytes) { truncateUtf8(s, maxBytes) + "…" } else { s }
}
