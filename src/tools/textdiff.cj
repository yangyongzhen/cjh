package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import cjutil.*

/**
 * 结构化 diff：工具改文件时，把"改了哪几行"作为结构化数据回给客户端
 *
 * 为什么要有（客户端约定 #7）：只给工具的文字输出时，客户端只能把整段结果当文本贴出来——
 * 用户看不出"具体改了哪几行"，也没法做审阅 / 回滚视图（只能从文字里认 sha 或靠猜）。
 * 给出 {path, unified_diff, before_sha, after_sha} 后：
 *   - 客户端可直接渲染 diff 视图（+/- 着色、折叠）
 *   - before_sha / after_sha 让客户端判断"这次改动是不是我以为的那次"（可对接版本回滚）
 *
 * 本文件只放纯函数（不碰文件系统）：I/O 与"读旧内容"由调用方工具负责。
 * 这样纯函数可被测试直接断言，工具层也不必为算 diff 改自己的失败路径。
 */

/** 单个 hunk 的上下文行数（与 git 默认一致） */
private const DIFF_CONTEXT_LINES: Int64 = 3

/**
 * 一次文件改动的结构化描述
 */
public class DiffInfo {
    public let path: String
    public let unifiedDiff: String
    public let beforeSha: String
    public let afterSha: String

    public init(path: String, unifiedDiff: String, beforeSha: String, afterSha: String) {
        this.path = path
        this.unifiedDiff = unifiedDiff
        this.beforeSha = beforeSha
        this.afterSha = afterSha
    }

    /**
     * 转 JSON：客户端按 unified_diff 渲染，按 before_sha / after_sha 识别版本
     */
    public func toJson(): JsonObject {
        var obj = JsonObject()
        obj.put("path", JsonString(this.path))
        obj.put("unified_diff", JsonString(this.unifiedDiff))
        obj.put("before_sha", JsonString(this.beforeSha))
        obj.put("after_sha", JsonString(this.afterSha))
        return obj
    }
}

/**
 * 按行切分（末尾换行不产生额外空行；空串 = 0 行）
 */
func splitLines(text: String): ArrayList<String> {
    var lines = ArrayList<String>()
    if (text.size == 0) {
        return lines
    }
    let parts = text.split('\n')
    for (i in 0..parts.size) {
        lines.add(parts[i])
    }
    if (lines[lines.size - 1].size == 0) {
        lines.remove(at: lines.size - 1)
    }
    return lines
}

/**
 * 生成 unified diff（单 hunk + 3 行上下文）；内容相同回空串
 *
 * 为什么是单 hunk：工具改文件绝大多数是一处局部改动（改几行 / 追加一段），
 * 用"公共前缀 + 公共后缀 + 中间整段替换"就能得到与 git 一致的结果，
 * O(n) 时间、O(1) 额外空间。多 hunk 需要 LCS 对齐（O(n·m) 内存），
 * 为罕见的"一个文件里多处分散改动"付这个代价不划算——那种情况这里会输出
 * 一个包住全部改动的大 hunk：内容正确，只是长（客户端可折叠）。
 *
 * 已知简化：不输出 "\ No newline at end of file" 标记（行级 diff 够用）。
 */
public func unifiedDiffText(oldText: String, newText: String, path: String): String {
    if (oldText == newText) {
        return ""
    }
    let oldLines = splitLines(oldText)
    let newLines = splitLines(newText)

    // 公共前缀：从头逐行比
    var head: Int64 = 0
    while (head < oldLines.size && head < newLines.size && oldLines[head] == newLines[head]) {
        head += 1
    }
    // 公共后缀：从尾逐行比（不与前缀重叠，避免前后缀抢同一行）
    var tail: Int64 = 0
    while (tail < oldLines.size - head && tail < newLines.size - head &&
        oldLines[oldLines.size - 1 - tail] == newLines[newLines.size - 1 - tail]) {
        tail += 1
    }

    // hunk 范围：改动段各向外扩 DIFF_CONTEXT_LINES 行上下文，并夹在文件边界内
    let start = if (head > DIFF_CONTEXT_LINES) { head - DIFF_CONTEXT_LINES } else { 0 }
    let oldChangedEnd = oldLines.size - tail
    let newChangedEnd = newLines.size - tail
    var oldStop = oldChangedEnd + DIFF_CONTEXT_LINES
    if (oldStop > oldLines.size) { oldStop = oldLines.size }
    var newStop = newChangedEnd + DIFF_CONTEXT_LINES
    if (newStop > newLines.size) { newStop = newLines.size }

    let lineNo = start + 1
    let oldCount = oldStop - start
    let newCount = newStop - start

    let sb = StringBuilder()
    sb.append("--- a/${path}\n")
    sb.append("+++ b/${path}\n")
    sb.append("@@ -${lineNo},${oldCount} +${lineNo},${newCount} @@\n")
    var i = start
    while (i < head) {                       // 改动前的公共上下文
        let line = oldLines[i]
        sb.append(" ${line}\n")
        i += 1
    }
    i = head
    while (i < oldChangedEnd) {              // 删掉的旧行
        let line = oldLines[i]
        sb.append("-${line}\n")
        i += 1
    }
    i = head
    while (i < newChangedEnd) {              // 新增的行
        let line = newLines[i]
        sb.append("+${line}\n")
        i += 1
    }
    i = oldChangedEnd
    while (i < oldStop) {                    // 改动后的公共上下文
        let line = oldLines[i]
        sb.append(" ${line}\n")
        i += 1
    }
    return sb.toString()
}

/**
 * 组装一次改动的结构化信息；内容未变回 None（调用方据此不带 diff 字段）
 *
 * sha 用完整 64 位十六进制：客户端可能拿它做"同一版本"判断或对接回滚，
 * 短形式省不下多少字节却可能撞车，不给捷径。
 */
public func buildDiffInfo(path: String, before: String, after: String): ?DiffInfo {
    if (before == after) {
        return None
    }
    return Some(DiffInfo(path, unifiedDiffText(before, after, path),
        sha256HexStr(before), sha256HexStr(after)))
}
