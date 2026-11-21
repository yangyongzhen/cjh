package cjh.tui

/**
 * 归一化斜杠命令输入（只用于命令识别，不改用户消息正文）：
 * - 去掉前导空白（ASCII 空白、全角空格 U+3000、NBSP）——中文输入法常在行首留全角空格；
 * - 行首全角斜杠 `／`（U+FF0F）按 ASCII `/` 处理——中文输入法下直接敲 `/` 常得到全角字符。
 *
 * 不做归一化时 `／theme` / ` /theme` 不满足 `startsWith("/")`，会被当成普通消息发给模型。
 */
public func normalizeSlashCommand(input: String): String {
    let runes = input.toRuneArray()
    var start = 0
    while (start < runes.size && isSlashCommandPad(runes[start])) {
        start += 1
    }
    if (start >= runes.size) {
        return ""
    }
    let sb = StringBuilder()
    if (UInt32(runes[start]) == 0xFF0Fu32) {
        sb.append("/")
    } else {
        sb.append(runes[start])
    }
    var i = start + 1
    while (i < runes.size) {
        sb.append(runes[i])
        i += 1
    }
    return sb.toString()
}

/** 命令前导空白：ASCII 空白 + 全角空格 + NBSP */
private func isSlashCommandPad(r: Rune): Bool {
    let v = UInt32(r)
    return v == 32u32 || v == 9u32 || v == 10u32 || v == 13u32 || v == 0x3000u32 || v == 0xA0u32
}
