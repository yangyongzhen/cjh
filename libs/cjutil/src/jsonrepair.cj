package cjutil

import stdx.encoding.json.*

/**
 * JSON 补全工具：处理 LLM 响应被 max_tokens 截断的情况
 *
 * 场景：LLM 生成 write_file 的 content（HTML/JS，很长）时，
 * 输出长度超过 max_tokens，被强制截断。content 字段没有闭合的 "，
 * JSON 不完整，JsonValue.fromStr 解析失败。
 *
 * 方案：参考 OpenAI SDK 的 partialParse，正向扫描 JSON，
 * 跟踪字符串状态和字段边界，找到最后一个完整字段后截断补 }。
 *
 * 用法：
 *   try {
 *     let parsed = JsonValue.fromStr(raw)
 *   } catch (e: Exception) {
 *     let fixed = repairTruncatedJson(raw)
 *     let parsed = JsonValue.fromStr(fixed)
 *   }
 */

/**
 * 尝试解析 JSON，返回 JsonObject
 * 解析失败或非 Object 类型时返回 None
 */
public func tryParseJson(s: String): ?JsonObject {
    try {
        let parsed = JsonValue.fromStr(s)
        match (parsed.kind()) {
            case JsonKind.JsObject => return Some(parsed.asObject())
            case _ => return None
        }
    } catch (e: Exception) {
        return None
    }
}

/**
 * 修复被截断的 JSON
 *
 * 正向扫描，跟踪：
 * - 是否在字符串内（考虑 \" 转义）
 * - 当前字段是否完整（key: value, 或 key: value}）
 *
 * 找到最后一个完整字段的结束位置，截断到那里，补 } 闭合。
 * 如果最后一个字段不完整（字符串被截断），补 " 闭合字符串，再补 } 闭合 JSON。
 */
public func repairTruncatedJson(raw: String): String {
    if (raw.size == 0) {
        return "{}"
    }
    // 确保以 { 开头
    var s = raw
    if (s.size > 0 && s[0] != 123u8 /* { */) {
        return "{}"
    }
    // 正向扫描，跟踪状态
    var i = 0
    let n = s.size
    var inString: Bool = false       // 是否在字符串内
    var lastCompleteEnd: Int64 = -1   // 最后一个完整字段的结束位置（含 , 或 }）
    while (i < n) {
        let c = s[i]
        if (inString) {
            // 在字符串内
            if (c == 92u8 /* \ */) {
                // 转义字符，跳过下一个
                i += 2
                continue
            }
            if (c == 34u8 /* " */) {
                // 字符串闭合
                inString = false
                // 检查后面是否是 , 或 }（字段完整）
                var j = i + 1
                while (j < n && (s[j] == 32u8 /* space */ || s[j] == 9u8 /* tab */ || s[j] == 10u8 /* \n */ || s[j] == 13u8 /* \r */)) {
                    j += 1
                }
                if (j < n && (s[j] == 44u8 /* , */ || s[j] == 125u8 /* } */)) {
                    // 字段完整，记录结束位置
                    lastCompleteEnd = j + 1
                }
            }
        } else {
            // 不在字符串内
            if (c == 34u8 /* " */) {
                // 字符串开始
                inString = true
            }
        }
        i += 1
    }
    // 方案1：有完整字段，截断到最后一个完整字段的结束位置
    if (lastCompleteEnd > 0) {
        var result = s[0..lastCompleteEnd]
        // 确保以 } 结尾
        if (result.size > 0 && result[result.size - 1] != 125u8 /* } */) {
            // 去掉末尾的 ,
            while (result.size > 0 && (result[result.size - 1] == 44u8 /* , */ || result[result.size - 1] == 32u8 /* space */ || result[result.size - 1] == 10u8 /* \n */ || result[result.size - 1] == 13u8 /* \r */ || result[result.size - 1] == 9u8 /* tab */)) {
                result = result[0..result.size - 1]
            }
            result = result + "}"
        }
        return result
    }
    // 方案2：没有完整字段，但字符串被截断（inString 仍然为 true）
    if (inString) {
        // 补 " 闭合字符串，再补 } 闭合 JSON
        return s + "\"}"
    }
    // 方案3：没有字符串字段，或字符串已闭合但字段不完整
    // 截断到最后一个 , 或 { ，补 }
    var j = n - 1
    while (j >= 0) {
        if (s[j] == 44u8 /* , */ || s[j] == 123u8 /* { */) {
            return s[0..j + 1] + "}"
        }
        j -= 1
    }
    return "{}"
}

