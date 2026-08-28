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
func formatToolArgs(name: String, args: JsonObject): String {
    let fields = args.getFields()
    if (fields.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    var first: Bool = true
    // 主字段：bash→command，其余→path（直接展示值，无 key 前缀）
    let mainKey = if (name == "bash") { "command" } else { "path" }
    if (let Some(v) <- args.get(mainKey)) {
        sb.append(shortArgValue(v))
        first = false
    }
    // 其余字段：key: value 平铺（无大括号）
    for ((k, v) in fields) {
        if (k == mainKey) {
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
func shortArgValue(v: JsonValue): String {
    var raw = ""
    match (v.kind()) {
        case JsonKind.JsString => raw = v.asString().getValue()
        case _ => raw = v.toJsonString()
    }
    return if (raw.size > 120) { truncateUtf8(raw, 120) + "…" } else { raw }
}
