package cjllm

/**
 * Mojibake 修复：某些 LLM 服务端（如 DeepSeek）把 UTF-8 中文按 Latin-1
 * 误解码再编码返回（"你好"→"ä½\xa0å¥½"，即每个字节被当成 Latin-1 字符
 * 再 UTF-8 编码）。本工具把每个字符码点还原为原始字节（U+00E4→0xE4），
 * 重组后按 UTF-8 解码还原中文。
 *
 * 安全：仅当重组后是合法 UTF-8 且含 CJK 字符时修复，否则原样返回。
 */
public class MojibakeFix {
    /**
     * 检测并修复 mojibake 字符串；无 mojibake 时原样返回
     */
    public static func fix(s: String): String {
        // 快路径：无高位字符（>127 的字节）则无 mojibake
        var hasHigh = false
        for (b in s) {
            if (UInt32(b) > 127) {
                hasHigh = true
                break
            }
        }
        if (!hasHigh) {
            return s
        }
        // 取码点数组
        let runes = s.toRuneArray()
        // 每个码点低 8 位 = 原始字节
        var ob = Array<UInt8>(runes.size, repeat: 0)
        for (i in 0..runes.size) {
            ob[i] = UInt8(UInt32(runes[i]) & 0xFF)
        }
        try {
            let fixed = String.fromUtf8(ob)
            // 仅当含 CJK 字符（中文修复成功的标志）才替换
            // 检查重组结果是否含 CJK（用 toRuneArray 迭代码点，非 Byte）
            var hasCjk = false
            let fixedRunes = fixed.toRuneArray()
            for (r in fixedRunes) {
                let v = UInt32(r)
                if (v >= 0x4E00 && v <= 0x9FFF) {
                    hasCjk = true
                    break
                }
            }
            return if (hasCjk) { fixed } else { s }
        } catch (e: Exception) {
            return s
        }
    }
}
