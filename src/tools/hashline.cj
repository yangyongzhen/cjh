package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import std.convert.*
import cjutil.*
import cjllm.ToolSpec

/**
 * Hashline 哈希锚点编辑（P0，对齐 omp Hashline 机制）
 *
 * 核心思想：模型用目标行的内容哈希前缀标识位置，不需要重打整行内容。
 * 文件变了导致哈希对不上，patch 会被拒绝而不是打错地方。
 *
 * patch 格式（每行一种类型）：
 * ```
 * @@{a3f2}              ← 锚点：定位 hash=a3f2 的行
 * +  const result = compute(x, options)   ← 在锚点行后插入
 * -  const result = compute(x)            ← 删除锚点行（必须哈希匹配）
 * ```
 *
 * 操作语义：
 * - `@@{hash}` 锚点：定位行内容 SHA-256 前 4 hex == hash 的行
 * - `+content` 插入：在锚点行**之后**插入 content
 * - `-content` 删除：删除锚点行（content 必须匹配锚点行内容，双保险）
 * - 无 `-` 无 `+` 的锚点：纯定位，配合下一个锚点做区间操作
 *
 * 哈希算法：行内容（不含换行符）UTF-8 字节 SHA-256，取前 4 hex 字符
 * 前缀碰撞概率：4 hex = 65536 种，单文件 < 1000 行时碰撞概率 < 1.5%
 * 碰撞处理：多个行匹配同一 hash 时，patch 被拒绝（要求模型提供更多上下文行）
 *
 * 效率收益（omp 实测基准）：
 * - 编辑成功率 6.7% → 68.3%（10× 提升）
 * - 输出 Token 减少 61%（重试循环消失）
 */
public class HashlineEditTool <: CjhTool {
    public init() {}

    public func isReadOnly(): Bool {
        return false  // 写文件：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("path", JsonSchema.str("要编辑的文件路径"))
        props.add("patch", JsonSchema.str("行号锚点补丁：@@N 定位第 N 行（1-based，推荐）；或 @@{hash} 哈希锚点。紧跟 +/- 改动行"))
        let schema = JsonSchema.object(props, ArrayList<String>(["path", "patch"]))
        return ToolSpec("hashline_edit",
            "用行号锚点编辑文件（比 write_file 全文覆盖高效）。" +
            "patch 格式（每行一种）：@@N 定位第 N 行（1-based，read_file 已给行号）；" +
            "+content 在锚点行后插入；-content 删除锚点行（content 必须精确匹配）；" +
            "-old +new 替换锚点行。" +
            "示例替换第 2 行：'@@2\\n-line2 this is a test\\n+line2 MODIFIED'。" +
            "内容不匹配会拒绝（防打错地方）。",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("path") || !args.containsKey("patch")) {
            return ToolResult("缺少参数: path/patch", true)
        }
        let path = args.get("path").getOrThrow().asString().getValue()
        let patch = args.get("patch").getOrThrow().asString().getValue()

        try {
            // 1. 读取原文件
            let originalBytes = File.readFrom(path)
            let original = safeFromUtf8(originalBytes)
            let lines = original.split("\n", -1)

            // 2. 解析 patch
            let ops = HashlineEditParser.parse(patch)
            if (ops.size == 0) {
                return ToolResult("patch 解析失败：无有效操作", true)
            }

            // 3. 应用 patch
            let result = HashlineEditApplier.apply(lines, ops)
            match (result) {
                case Applied(newLines, summary) =>
                    // 4. 写回文件
                    var newContent = ""
                    var first: Bool = true
                    for (line in newLines) {
                        if (!first) {
                            newContent += "\n"
                        }
                        newContent += line
                        first = false
                    }
                    File.writeTo(path, newContent.toArray())
                    return ToolResult("Hashline 编辑成功：${summary}", false)
                case ApplyError(reason) =>
                    return ToolResult("Hashline 编辑被拒绝：${reason}", true)
            }
        } catch (e: Exception) {
            return ToolResult("Hashline 编辑异常: ${e}", true)
        }
    }
}

/**
 * patch 操作类型
 *
 * V2 设计变更：原方案用 FNV-1a 哈希锚点（@@{hash}），但模型无法预先
 * 计算哈希值，实测 LLM 反复尝试各种 hash 格式都失败。
 *
 * 新方案：行号锚点（@@N，N=1-based 行号）+ 内容验证（-old 必须匹配）
 * - 模型用 read_file 读文件时已看到行号（1-based），直接引用
 * - -old 的 old 必须精确匹配该行内容，不匹配则拒绝（防打错地方）
 * - 比 omp Hashline 简单，但对模型友好（omp 要求模型输出哈希前缀）
 */
public enum PatchOp {
    | LineAnchor(Int64)           // @@N：定位第 N 行（1-based）
    | HashAnchor(String)          // @@{hash}：哈希锚点（向后兼容，但模型难用）
    | Insert(String)              // +content：在锚点行后插入
    | Delete(String)              // -content：删除锚点行（content 双保险匹配）
    | Replace(String, String)     // -old +new：替换锚点行
}

/**
 * patch 应用结果
 */
public enum ApplyResult {
    | Applied(ArrayList<String>, String)  // 新行列表 + 摘要
    | ApplyError(String)                  // 拒绝原因
}

/**
 * Hashline patch 解析器
 *
 * 解析规则：
 * - 以 `@@{` 开头且以 `}` 结尾的行 → Anchor（提取花括号内 hash）
 * - 以 `+` 开头的行 → Insert（`+` 后内容为插入行）
 * - 以 `-` 开头的行 → Delete（`-` 后内容为待删除行内容）
 * - 连续的 `-old` + `+new` → Replace（锚点行替换）
 * - 其他行忽略（注释/空行）
 */
public class HashlineEditParser {
    /**
     * 解析 patch 文本为操作列表
     *
     * 锚点格式（三种都支持，降低 LLM 使用门槛）：
     *   @@3        → 行号锚点（定位第 3 行，1-based，推荐）
     *   @@{a3f2}   → 哈希锚点（hash = a3f2，向后兼容）
     *   @@a3f2     → 哈希锚点（hash = a3f2，向后兼容）
     *
     * 操作格式（紧跟锚点）：
     *   +content    → 在锚点行后插入
     *   -content    → 删除锚点行（content 双保险匹配）
     *   -old\n+new  → 替换锚点行
     */
    public static func parse(patch: String): ArrayList<PatchOp> {
        var ops = ArrayList<PatchOp>()
        let lines = patch.split("\n", -1)
        var i = 0
        while (i < lines.size) {
            let line = lines[i]
            if (line.startsWith("@@")) {
                // 先尝试行号锚点：@@N
                let lineNoResult = parseLineAnchor(line)
                match (lineNoResult) {
                    case Some(lineNo) =>
                        ops.add(PatchOp.LineAnchor(lineNo))
                        i += 1
                        i = collectOps(lines, i, ops)
                    case None =>
                        // 行号解析失败，尝试哈希锚点
                        let hash = parseHashAnchor(line)
                        if (hash.size > 0) {
                            ops.add(PatchOp.HashAnchor(hash))
                            i += 1
                            i = collectOps(lines, i, ops)
                        } else {
                            i += 1  // @@ 后无内容，跳过
                        }
                }
            } else {
                i += 1  // 跳过非锚点行
            }
        }
        return ops
    }

    /**
     * 收集紧跟锚点的 +/- 操作，返回下一个待处理行索引
     */
    private static func collectOps(lines: Array<String>, start: Int64, ops: ArrayList<PatchOp>): Int64 {
        var i = start
        var pendingDelete: String = ""
        var hasDelete: Bool = false
        while (i < Int64(lines.size)) {
            let opLine = lines[i]
            if (opLine.startsWith("+")) {
                let content = opLine[1..opLine.size]
                if (hasDelete) {
                    ops.add(PatchOp.Replace(pendingDelete, content))
                    hasDelete = false
                    pendingDelete = ""
                } else {
                    ops.add(PatchOp.Insert(content))
                }
                i += 1
            } else if (opLine.startsWith("-")) {
                let content = opLine[1..opLine.size]
                if (hasDelete) {
                    ops.add(PatchOp.Delete(pendingDelete))
                }
                pendingDelete = content
                hasDelete = true
                i += 1
            } else if (opLine.startsWith("@@")) {
                break  // 遇到下一个锚点，结束当前块
            } else {
                break  // 非操作行，结束当前锚点块
            }
        }
        // 处理末尾未配对的 Delete
        if (hasDelete) {
            ops.add(PatchOp.Delete(pendingDelete))
        }
        return i
    }

    /**
     * 解析行号锚点：@@N → N（1-based）
     * 返回 None 表示不是行号锚点
     */
    private static func parseLineAnchor(line: String): Option<Int64> {
        let rest = line[2..line.size]  // 去掉 @@
        if (rest.size == 0) {
            return None
        }
        // 检查是否全数字（用 Rune 字面量比较）
        var allDigits: Bool = true
        for (ch in rest) {
            if (ch < 48 || ch > 57) {  // '0'=48, '9'=57
                allDigits = false
                break
            }
        }
        if (!allDigits) {
            return None
        }
        try {
            return Some(Int64.parse(rest))
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 解析哈希锚点：@@{hash} 或 @@hash → hash
     */
    private static func parseHashAnchor(line: String): String {
        if (line.startsWith("@@{") && line.endsWith("}")) {
            return line[3..line.size - 1]
        }
        if (line.startsWith("@@")) {
            return line[2..line.size]
        }
        return ""
    }
}

/**
 * Hashline patch 应用器
 *
 * 应用策略：
 * 1. 遍历 ops，遇到 Anchor 时在原文件定位行
 * 2. 定位规则：行内容 SHA-256 前 4 hex == anchor.hash
 * 3. 定位成功后，处理紧跟的 Insert/Delete/Replace
 * 4. 定位失败（哈希不匹配或碰撞）→ 拒绝整个 patch
 *
 * 多锚点处理：每个锚点独立定位，操作按锚点顺序应用
 * 行号偏移：Insert/Delete 会改变后续行号，用"已处理行数"跟踪
 */
public class HashlineEditApplier {
    /**
     * 应用 patch 到原文件行列表
     *
     * 行号锚点（@@N）：直接定位第 N 行（1-based）
     * 哈希锚点（@@{hash}）：行内容 FNV-1a 低 16 位 == hash
     *
     * 内容验证：-old 的 old 必须精确匹配锚点行内容，不匹配则拒绝
     * 防打错地方：文件变了导致行号/哈希对不上，patch 被拒绝
     */
    public static func apply(originalLines: Array<String>, ops: ArrayList<PatchOp>): ApplyResult {
        // 转为可变列表
        var lines = ArrayList<String>()
        for (line in originalLines) {
            lines.add(line)
        }

        var appliedCount: Int64 = 0
        var i = 0
        while (i < ops.size) {
            match (ops[i]) {
                case LineAnchor(lineNo) =>
                    // 行号锚点：1-based → 0-based
                    let lineIdx: Int64 = lineNo - 1
                    if (lineIdx < 0 || lineIdx >= Int64(lines.size)) {
                        return ApplyResult.ApplyError("行号 ${lineNo} 超出范围（文件共 ${lines.size} 行）")
                    }
                    var insertAfterLine: Int64 = lineIdx
                    i += 1
                    while (i < ops.size) {
                        match (ops[i]) {
                            case Insert(content) =>
                                lines = ArrayListOps.insertAfter(lines, insertAfterLine, content)
                                insertAfterLine += 1
                                appliedCount += 1
                                i += 1
                            case Delete(oldContent) =>
                                // 内容验证：-old 必须匹配锚点行
                                if (oldContent.size > 0 && lines[lineIdx] != oldContent) {
                                    return ApplyResult.ApplyError(
                                        "删除内容不匹配：期望「${oldContent}」，实际「${lines[lineIdx]}」")
                                }
                                lines = ArrayListOps.removeAt(lines, lineIdx)
                                appliedCount += 1
                                i += 1
                            case Replace(oldContent, newContent) =>
                                // 内容验证：-old 必须匹配锚点行
                                if (oldContent.size > 0 && lines[lineIdx] != oldContent) {
                                    return ApplyResult.ApplyError(
                                        "替换内容不匹配：期望「${oldContent}」，实际「${lines[lineIdx]}」")
                                }
                                lines[lineIdx] = newContent
                                appliedCount += 1
                                i += 1
                            case LineAnchor(_) | HashAnchor(_) =>
                                break  // 遇到下一个锚点，结束当前块
                        }
                    }
                case HashAnchor(hash) =>
                    // 哈希锚点：行内容 FNV-1a 低 16 位 == hash
                    let locateResult = HashlineHash.locate(lines, hash)
                    match (locateResult) {
                        case LocateError(reason) =>
                            return ApplyResult.ApplyError("锚点 @@{${hash}} 定位失败：${reason}")
                        case Located(lineIdx) =>
                            var insertAfterLine: Int64 = lineIdx
                            i += 1
                            while (i < ops.size) {
                                match (ops[i]) {
                                    case Insert(content) =>
                                        lines = ArrayListOps.insertAfter(lines, insertAfterLine, content)
                                        insertAfterLine += 1
                                        appliedCount += 1
                                        i += 1
                                    case Delete(oldContent) =>
                                        if (oldContent.size > 0 && lines[lineIdx] != oldContent) {
                                            return ApplyResult.ApplyError(
                                                "删除内容不匹配：期望「${oldContent}」，实际「${lines[lineIdx]}」")
                                        }
                                        lines = ArrayListOps.removeAt(lines, lineIdx)
                                        appliedCount += 1
                                        i += 1
                                    case Replace(oldContent, newContent) =>
                                        if (oldContent.size > 0 && lines[lineIdx] != oldContent) {
                                            return ApplyResult.ApplyError(
                                                "替换内容不匹配：期望「${oldContent}」，实际「${lines[lineIdx]}」")
                                        }
                                        lines[lineIdx] = newContent
                                        appliedCount += 1
                                        i += 1
                                    case LineAnchor(_) | HashAnchor(_) =>
                                        break
                                }
                            }
                    }
                case _ =>
                    i += 1  // 跳过非锚点操作（Insert/Delete/Replace 无锚点时不应用）
            }
        }
        return ApplyResult.Applied(lines, "应用 ${appliedCount} 个操作")
    }
}

/**
 * ArrayList 辅助操作（仓颉 ArrayList 无 insert/removeAt）
 */
public class ArrayListOps {
    /**
     * 在 idx 行后插入 content，返回新列表
     */
    public static func insertAfter(lines: ArrayList<String>, idx: Int64, content: String): ArrayList<String> {
        var newLines = ArrayList<String>()
        var j: Int64 = 0
        for (line in lines) {
            newLines.add(line)
            if (j == idx) {
                newLines.add(content)
            }
            j += 1
        }
        return newLines
    }

    /**
     * 删除 idx 行，返回新列表
     */
    public static func removeAt(lines: ArrayList<String>, idx: Int64): ArrayList<String> {
        var newLines = ArrayList<String>()
        var j: Int64 = 0
        for (line in lines) {
            if (j != idx) {
                newLines.add(line)
            }
            j += 1
        }
        return newLines
    }
}

/**
 * Hashline 哈希工具
 *
 * 哈希算法：FNV-1a 32-bit，行内容（不含换行符）UTF-8 字节，
 * 取前 4 hex 字符（16-bit 摘要，单文件 < 1000 行碰撞概率 < 1.5%）
 *
 * FNV-1a 实现（无外部依赖）：
 *   hash = 2166136261
 *   for each byte: hash = (hash ^ byte) * 16777619
 *   hash &= 0xFFFFFFFF  // 保持 32-bit
 */
public class HashlineHash {
    /**
     * 计算行内容的哈希前缀（4 hex 字符）
     */
    public static func hashLine(line: String): String {
        let bytes = line.toArray()
        var hash: UInt32 = 2166136261
        for (b in bytes) {
            hash = hash ^ UInt32(b)
            hash = hash * UInt32(16777619)
        }
        // 取低 16 位，转 4 hex
        let low16 = hash & UInt32(0xFFFF)
        return toHex4(low16)
    }

    /**
     * 在行列表中定位哈希匹配的行
     */
    public static func locate(lines: ArrayList<String>, hash: String): LocateResult {
        var matchIdx: Int64 = -1
        var matchCount: Int64 = 0
        var idx: Int64 = 0
        for (line in lines) {
            let lineHash = HashlineHash.hashLine(line)
            if (lineHash == hash) {
                matchIdx = idx
                matchCount += 1
            }
            idx += 1
        }
        if (matchCount == 0) {
            return LocateResult.LocateError("无匹配行（文件可能已被修改）")
        }
        if (matchCount > 1) {
            return LocateResult.LocateError("哈希碰撞：${matchCount} 行匹配，需提供更多上下文")
        }
        return LocateResult.Located(matchIdx)
    }

    /**
     * UInt32 低 16 位转 4 hex 字符
     */
    private static func toHex4(value: UInt32): String {
        let hexChars = "0123456789abcdef"
        let v = UInt64(value)
        let c3 = hexChars[Int64((v >> 12) & UInt64(0xF))]
        let c2 = hexChars[Int64((v >> 8) & UInt64(0xF))]
        let c1 = hexChars[Int64((v >> 4) & UInt64(0xF))]
        let c0 = hexChars[Int64(v & UInt64(0xF))]
        return "${c3}${c2}${c1}${c0}"
    }
}

/**
 * 定位结果
 */
public enum LocateResult {
    | Located(Int64)      // 匹配行的索引
    | LocateError(String) // 不匹配/碰撞
}
