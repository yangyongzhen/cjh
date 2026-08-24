package cjllm

/**
 * UTF-8 安全解码：遇到非法字节时用替换字符（U+FFFD �）代替，不抛异常
 *
 * 背景：String.fromUtf8() 遇到非法 UTF-8 字节序列时抛
 * IllegalArgumentException。LLM 流式响应（SSE）可能包含
 * 非法 UTF-8 字节（mojibake、编码错误），需要容错解码。
 */
public func safeFromUtf8(bytes: Array<UInt8>): String {
    var sb = StringBuilder()
    var i = 0
    let n = bytes.size
    while (i < n) {
        let b0 = bytes[i]
        var len = 1
        var valid = true
        if (b0 < 0x80u8) {
            len = 1
        } else if ((b0 & 0xE0u8) == 0xC0u8) {
            len = 2
        } else if ((b0 & 0xF0u8) == 0xE0u8) {
            len = 3
        } else if ((b0 & 0xF8u8) == 0xF0u8) {
            len = 4
        } else {
            valid = false
        }
        if (valid && i + len > n) {
            valid = false
        }
        if (valid) {
            for (j in 1..len) {
                if ((bytes[i + j] & 0xC0u8) != 0x80u8) {
                    valid = false
                    break
                }
            }
        }
        if (valid) {
            try {
                sb.append(String.fromUtf8(bytes[i..i + len]))
            } catch (e: Exception) {
                sb.append("�")
            }
            i += len
        } else {
            sb.append("�")
            i += 1
        }
    }
    return sb.toString()
}
