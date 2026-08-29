package cjterm

/**
 * 字节安全截断：最多截取 maxBytes 字节，若落在 UTF-8 多字节字符中间则递减到合法边界。
 *
 * 内联自 cjutil（独立库自包含，零外部依赖）；避免 String 切片在字符中间抛
 * IllegalArgumentException: Invalid utf8 byte sequence。
 */
internal func truncateUtf8(text: String, maxBytes: Int64): String {
    if (text.size <= maxBytes) {
        return text
    }
    var k = maxBytes
    while (k > 0) {
        try {
            return text[0..k]
        } catch (e: Exception) {
            k -= 1
        }
    }
    return ""
}
