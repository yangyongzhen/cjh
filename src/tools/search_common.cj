package cjh.tools

import std.collection.*
import std.process.*
import std.env.*

/**
 * grep/glob 共享搜索基础设施（单一职责：常量 + 文件枚举 + 路径组件过滤）
 *
 * 快速路径（find 枚举）与原生路径（显式递归 Directory.walk）必须输出**字节级一致**
 * 的 ToolResult。为保证这一点，设计上让两边共享：
 *   1. 同一份忽略目录常量（GREP_IGNORED_DIRS / GLOB_IGNORED_DIRS）——原生
 *      GrepWalkState / GlobTool 直接引用这里的数组，单一来源避免漂移（AGENTS §2）。
 *   2. 同一份"每文件渲染/匹配"逻辑（见 builtin.cj 的 GrepTool.grepSearchFile 与
 *      glob.cj 的 considerGlobFile）：原生与快速路径都调用它。
 *
 * 文本扩展名判断不复用这里的常量——原生 isTextFile 是 GrepWalkState 方法，
 * 快速路径直接复用该实例方法（state.isTextFile），保持单一实现。
 *
 * 快速路径只做"文件枚举"：用 `find`（POSIX/GNU，普遍存在）以**与原生 readdir
 * 相同的预序 DFS 顺序**列出所有 常规文件 + 符号链接；读文件/切行/正则匹配/渲染
 * 全部走原生实现。这样彻底避免 rg 与 std.regex 在行尾/\r/多字节上的差异——
 * 只在"枚举"阶段借 find 的 C 级速度（原生 walk 每个条目都要 managed stat +
 * 每层 checkDirectoryPath 规范化，find 一次进程内完成）。
 *
 * 关键等价性（已逐条实测）：
 *   - 原生 walk 的 fi.path == FileInfo(base).path + "/" + (find base -printf '%P')
 *     （对 "./"、"//"、尾部"/"、绝对/相对 base 全部成立，含双斜杠 quirk）。
 *   - find 顺序 == 原生显式递归 DFS 顺序（同一 readdir 序，无排序）。
 *   - 原生遇忽略目录"跳过不递归" ⇔ find 全量枚举后按路径组件做后置过滤
 *     （任一组件命中忽略规则 ⇒ 该文件被原生跳过，故排除；集合与顺序都一致）。
 *
 * 回退：find 不存在 / 进程异常 / 退出码非 0（含部分权限错误）⇒ 返回 None ⇒
 * 调用方走原生路径，行为与现状完全一致。
 */

/**
 * grep 忽略目录（原生 grep 搜索隐藏文件，只按目录名排除这 9 个）
 */
public let GREP_IGNORED_DIRS: Array<String> =
    [".git", "node_modules", "target", ".next", "dist", "build", ".cache", "__pycache__", ".venv"]

/**
 * glob 忽略目录（原生 glob 额外跳过隐藏文件；12 目录比 grep 多 .gradle/.idea/.vscode）
 */
public let GLOB_IGNORED_DIRS: Array<String> =
    [".git", "node_modules", "target", ".next", "dist", "build", ".cache", "__pycache__", ".venv", ".gradle", ".idea", ".vscode"]

/**
 * 取路径最后一个组件（"a/b/c.txt" → "c.txt"；无 "/" 返回自身）
 */
public func lastComponentOf(path: String): String {
    var i: Int64 = path.size - 1
    while (i >= 0) {
        if (path[i] == 47u8) {
            return path[(i + 1)..path.size]
        }
        i -= 1
    }
    return path
}

/**
 * 路径（单斜杠相对路径）的任一组件是否命中忽略列表。
 *
 * 等价于原生"遇忽略目录跳过不递归"：文件 P 被原生枚举到，当且仅当其
 * 所有祖先目录与自身文件名都不在忽略列表 ⇒ 快速路径排除条件即"任一组件命中"。
 */
public func anyComponentIn(relPath: String, list: Array<String>): Bool {
    for (comp in relPath.split("/", -1)) {
        for (item in list) {
            if (comp == item) {
                return true
            }
        }
    }
    return false
}

/**
 * 路径的任一组件是否"隐藏（. 开头）或命中忽略列表"。
 *
 * glob 语义：shouldSkip 对文件与目录都按 basename 判断（隐藏文件跳过、
 * 隐藏/忽略目录不递归）⇒ 文件 P 被原生枚举到，当且仅当其所有组件都
 * 非隐藏且不在 12 目录列表。
 */
public func anyComponentHiddenOrIn(relPath: String, list: Array<String>): Bool {
    for (comp in relPath.split("/", -1)) {
        if (comp.startsWith(".")) {
            return true
        }
        for (item in list) {
            if (comp == item) {
                return true
            }
        }
    }
    return false
}

/**
 * 快速路径开关：默认开启；设环境变量 CJH_DISABLE_FIND_FASTPATH 为 1/true/yes 时关闭
 * （回退原生路径，便于排障与基准对比）。
 */
public func isFindFastPathEnabled(): Bool {
    if (let Some(v) <- getVariable("CJH_DISABLE_FIND_FASTPATH")) {
        if (v == "1" || v == "true" || v == "yes") {
            return false
        }
    }
    return true
}

/**
 * 用 find 枚举 base 下所有 常规文件 + 符号链接，返回 **base 相对** 的单斜杠路径列表
 * （预序 DFS 顺序，与原生 walk 一致）。
 *
 *   find base \( -type f -o -type l \) -printf '%P\0'
 *
 * - `-type f`：常规文件。
 * - `-type l`：符号链接（**不跟随**）。与原生一致：原生把符号链接当文件列出
 *   （`FileInfo.isDirectory()` 对 symlink-to-dir 返回 false，不递归进入），
 *   `-type l` 正好枚举这些符号链接且不下钻符号链接目录。
 * - `-printf '%P\0'`：输出相对 base 的路径（NUL 分隔），base 前缀被剥离，
 *   单斜杠、无 `./`/`..`/尾 `/`。NUL 分隔保证文件名含空格/换行也安全。
 *
 * 失败（find 不存在、进程异常、退出码非 0——含部分权限错误）返回 None，
 * 调用方回退原生路径，保证行为与现状一致。
 */
public func enumerateFilesWithFind(base: String): ?ArrayList<String> {
    var fa = ArrayList<String>()
    fa.add(base)
    fa.add("(")
    fa.add("-type")
    fa.add("f")
    fa.add("-o")
    fa.add("-type")
    fa.add("l")
    fa.add(")")
    fa.add("-printf")
    fa.add("%P\\0")
    try {
        let (code, out, _err) = executeWithOutput("find", fa.toArray())
        if (code != 0) {
            // 退出码非 0（base 不存在 / 部分子目录无权限等）⇒ 不可信任其部分输出，
            // 整体回退原生（原生按文件捕获错误，行为与现状一致）。
            return None
        }
        let s = String.fromUtf8(out)
        var rels = ArrayList<String>()
        for (part in s.split("\0", -1)) {
            if (part.size > 0) {
                rels.add(part)
            }
        }
        return rels
    } catch (e: Exception) {
        // find 不存在 / fork 失败等 ⇒ 回退原生
        return None
    }
}
