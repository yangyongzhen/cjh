package cjh.tools

import std.collection.*

/**
 * 会话 shell 的 PATH 修复（v1.3.x）
 *
 * **问题**：cjh 用**绝对路径**找到 Git Bash（`ShellProvider`），但那个 bash 的
 * `/usr/bin` 未必在继承来的 PATH 上。此时 agent 一跑 `cat` / `sed` / `grep` / `head`
 * 就是 `command not found`，退出码 127 —— 看起来像"命令写错了"，其实是 shell 环境缺件。
 *
 * 实测现场（Windows + Git Bash）：
 *
 * ```
 * 会话内 PATH = /d/cangjie-stdx/…:/d/Program Files (x86)/Cangjie/bin:…（一个 Git/MSYS 目录都没有）
 * /usr/bin/bash: line 3: cat: command not found
 * ```
 *
 * 复现：`export PATH="/c/Windows/system32:/c/Windows"; command -v cat` → MISSING；
 * 追加 `<git>/usr/bin` 后 → `/D/Program Files/Git/usr/bin/cat`（GNU coreutils 8.32）。
 *
 * **处置**：在会话里**追加**（不覆盖）`<shell 所在目录>` 与 `<shell 上级>/usr/bin`，
 * 并用 `__CJH_PATH_FIXED` 保证只做一次（幂等）。追加而非前置，是为了不改变用户
 * 已装同名命令的优先级。盘符大小写保留即可（实测 `/D/…` 与 `/d/…` 都认，
 * 所以这里不做小写转换，省掉 Byte 大小写运算的坑）。
 */

public const PATH_FIX_FLAG: String = "__CJH_PATH_FIXED"

/**
 * 最后一个路径分隔符的下标（`/` 与 `\` 都认；找不到返回 -1）
 */
func lastSepIdx(s: String): Int64 {
    var idx: Int64 = -1
    var i: Int64 = 0
    for (b in s.toArray()) {
        if (b == 47 || b == 92) {
            idx = i
        }
        i += 1
    }
    return idx
}

/**
 * 反斜杠换成正斜杠（逐字节重建，避免 `StringBuilder.append(Byte)` 按十进制输出的坑）
 */
func forwardSlashes(s: String): String {
    let src = s.toArray()
    var out = Array<Byte>(src.size, repeat: 0)
    for (i in 0..src.size) {
        out[i] = if (src[i] == 92) { 47 } else { src[i] }
    }
    return String.fromUtf8(out)
}

/**
 * Windows 路径 → MSYS 形式：`D:\Program Files\Git\bin` → `/D/Program Files/Git/bin`。
 * 已经是 POSIX 形式（以 `/` 开头）或相对路径时，只把反斜杠换掉。
 */
public func msysPathOf(p: String): String {
    let s = p.trimAscii()
    if (s.size == 0) {
        return ""
    }
    if (s.startsWith("/")) {
        return s
    }
    var prefix = ""
    var body = s
    if (s.size >= 2 && s[1] == 58) {  // '<盘符>:'
        prefix = "/" + s[0..1] + "/"
        body = s[2..]
    }
    var rest = forwardSlashes(body)
    while (rest.startsWith("/")) {
        rest = rest[1..]
    }
    return prefix + rest
}

/**
 * 取所在目录并转成 MSYS 形式。
 * 传文件路径（`…/bin/bash.exe`）→ 返回它所在目录；传以分隔符结尾的目录（`…/bin/`）
 * → 原样返回该目录（不越级到上级，否则调用方会拿到意料之外的路径）。
 */
public func msysDirOf(p: String): String {
    var s = p.trimAscii()
    if (s.size == 0) {
        return ""
    }
    var hadTrail = false
    while (s.size > 1 && (s[s.size - 1] == 47 || s[s.size - 1] == 92)) {
        s = s[0..s.size - 1]
        hadTrail = true
    }
    if (hadTrail) {
        return msysPathOf(s)
    }
    let idx = lastSepIdx(s)
    if (idx <= 0) {
        return ""
    }
    return msysPathOf(s[0..idx])
}

/**
 * 会话 shell 需要补进 PATH 的目录：
 * ① shell 自身目录（Git for Windows 的 `<git>/bin`，里面有 bash/sh）
 * ② `<git>/usr/bin`（coreutils：cat/sed/grep/awk…）
 * ③ `<git>/mingw64/bin`（MSYS2 布局；不存在也无害）
 */
public func shellPathDirs(shellPath: String): Array<String> {
    var dirs = ArrayList<String>(0)
    let bin = msysDirOf(shellPath)
    if (bin.size == 0) {
        return dirs.toArray()
    }
    dirs.add(bin)
    let parent = msysDirOf(bin)
    if (parent.size > 0) {
        dirs.add(parent + "/usr/bin")
        dirs.add(parent + "/mingw64/bin")
    }
    return dirs.toArray()
}

/**
 * 幂等的 PATH 修复片段（以 `; ` 结尾，可直接拼在命令前面）。
 * `isBash=false`（PowerShell 模式）返回空串——那边没有这套目录约定。
 */
public func shellPathFix(shellPath: String, isBash: Bool): String {
    if (!isBash) {
        return ""
    }
    let dirs = shellPathDirs(shellPath)
    if (dirs.size == 0) {
        return ""
    }
    var add = ""
    for (d in dirs) {
        if (add.size > 0) {
            add += ":"
        }
        add += d
    }
    return "if [ -z \"$" + PATH_FIX_FLAG + "\" ]; then " + PATH_FIX_FLAG +
        "=1; PATH=\"$PATH:" + add + "\"; export PATH; fi; "
}
