package cjh.tools

/**
 * UTF-8 安全解码（cjh.tools 版）
 *
 * 遇到非法字节时用替换字符（U+FFFD �）代替，不抛异常。
 * 用于工具输出解析（bash stdout/stderr、read_file、grep 等），
 * 避免非法 UTF-8 字节导致 IllegalArgumentException 崩溃 TUI。
 *
 * 注意：cjllm 包有同名函数 safeFromUtf8，用于 LLM 响应解析。
 * 本包不依赖 cjllm，故独立实现（逻辑一致）。
 */
public func safeFromUtf8Decode(bytes: Array<UInt8>): String {
    var sb = StringBuilder()
    var i = 0
    let n = bytes.size
    while (i < n) {
        let b0 = bytes[i]
        var len = 1
        var valid = true
        // 判断 UTF-8 字符长度
        if (b0 < 0x80u8) {
            len = 1
        } else if ((b0 & 0xE0u8) == 0xC0u8) {
            len = 2
        } else if ((b0 & 0xF0u8) == 0xE0u8) {
            len = 3
        } else if ((b0 & 0xF8u8) == 0xF0u8) {
            len = 4
        } else {
            // 非法首字节
            valid = false
        }
        // 检查后续字节是否是 10xxxxxx
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
            // 合法 UTF-8 字符，直接复制字节
            try {
                sb.append(String.fromUtf8(bytes[i..i + len]))
            } catch (e: Exception) {
                // 理论不可达：已验证合法
                sb.append("�")
            }
            i += len
        } else {
            // 非法字节，用替换字符
            sb.append("�")
            i += 1
        }
    }
    return sb.toString()
}

