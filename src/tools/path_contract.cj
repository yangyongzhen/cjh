package cjh.tools

import std.collection.*
import std.env.*

/**
 * 文件工具路径契约（P0）
 *
 * 问题：bash 是持久会话，`cd` 后的相对路径以**会话 cwd** 为基准；文件工具
 * 却按**进程 cwd** 解析。同一个 `read_file("agent/loop.cj")` 在两处含义不同，
 * 模型很容易在 `cd src/agent` 之后读到错误文件。
 *
 * 契约：
 * - 所有文件工具的 path 在入口统一解析到**固定 workspace root**（进程 cwd；
 *   Web 切换工作区时随之变化，但 bash 会话 cd 不影响它）。
 * - 相对路径继续接受（兼容旧模型习惯），解析后按绝对路径执行。
 * - 输出/错误里回显解析后的绝对路径；read_file 在入参非绝对路径时额外
 *   打一行 `[path] ...`，让模型看到真实位置。
 *
 * 只做词法规范化（`.` / `..` / 重复分隔符），不解析符号链接：安全边界
 * （capability / writeScope）按用户看到的字面路径判断，与操作系统解析一致。
 */
public func resolveFilePath(raw: String): String {
    if (raw.size == 0) {
        return ""
    }
    let root = getWorkingDirectory().toString()
    let win = isWindowsAbsolute(root) || isWindowsAbsolute(raw)
    let joined = if (isAbsolutePath(raw, win)) { raw } else { root + "/" + raw }
    return lexicalNormalize(joined, win)
}

/**
 * 绝对路径判定（不依赖平台：Windows 盘符/UNC 在 Linux 上也按绝对路径处理，
 * 避免把 `C:\tmp` 误拼到 cwd 后面）。
 */
public func isAbsolutePath(p: String, win: Bool): Bool {
    if (p.startsWith("/")) {
        return true
    }
    if (win && p.size >= 2 && p[1] == UInt8(58)) {  // "C:"
        return true
    }
    if (p.size >= 2 && p[0] == UInt8(92) && p[1] == UInt8(92)) {  // "\\\\"
        return true
    }
    return false
}

/**
 * 入参不是绝对路径时，给 read_file 结果加一行解析后路径；已是绝对路径则不重复。
 */
public func pathResolutionNotice(raw: String, resolved: String): String {
    if (raw.size == 0 || raw == resolved) {
        return ""
    }
    return "[path] ${resolved}\n"
}

/**
 * 给工具结果前置路径提示（read_file 用）。diff 原样保留。
 */
public func withPathNotice(result: ToolResult, notice: String): ToolResult {
    if (notice.size == 0) {
        return result
    }
    return ToolResult(notice + result.content, result.isError, result.diff)
}

private func isWindowsAbsolute(p: String): Bool {
    if (p.size >= 2 && p[1] == UInt8(58)) {
        return true
    }
    if (p.size >= 2 && p[0] == UInt8(92) && p[1] == UInt8(92)) {
        return true
    }
    return false
}

/**
 * 词法规范化：折叠重复分隔符、`.`、`..`。
 *
 * Windows 路径先统一成 `/` 计算，最后换回 `\`，保证输出与传入风格一致
 * （测试/配置里 Windows 路径多用反斜杠，不能悄悄改成混合分隔符）。
 */
private func lexicalNormalize(path: String, win: Bool): String {
    var s = path
    if (win) {
        s = s.replace("\\", "/")
    }
    var prefix = ""
    var rest = s
    if (s.startsWith("//") && win) {
        // UNC：保留双斜杠，避免后续被折叠成单斜杠
        prefix = "//"
        rest = s[2..s.size]
    } else if (s.startsWith("/")) {
        prefix = "/"
        var i = 0
        while (i < s.size && s[i] == UInt8(47)) {
            i += 1
        }
        rest = s[i..s.size]
    } else if (s.size >= 2 && s[1] == UInt8(58)) {  // "C:"
        prefix = s[0..1] + ":/"
        if (s.size > 2 && s[2] == UInt8(47)) {
            rest = s[3..s.size]
        } else {
            rest = s[2..s.size]
        }
    }

    let parts = ArrayList<String>()
    for (seg in rest.split("/", -1)) {
        if (seg.size == 0 || seg == ".") {
            continue
        }
        if (seg == "..") {
            if (parts.size > 0 && parts[parts.size - 1] != "..") {
                parts.remove(at: parts.size - 1)
            } else if (prefix.size == 0) {
                // 相对路径越过起点：保留 `..`，不要静默吞掉（安全边界要如实体现）
                parts.add("..")
            }
            continue
        }
        parts.add(seg)
    }

    var out = StringBuilder()
    out.append(prefix)
    var first = true
    for (seg in parts) {
        if (!first) {
            out.append("/")
        }
        out.append(seg)
        first = false
    }
    var result = out.toString()
    if (result.size == 0) {
        result = if (prefix.size > 0) { prefix } else { "." }
    }
    if (win) {
        result = result.replace("/", "\\")
    }
    return result
}
