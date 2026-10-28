package cjterm

import std.fs.*

/**
 * 跨平台测试临时目录（测试专供；文件名 `*_test.cj` → 发布构建排除）
 *
 * POSIX 沿用 `/tmp/cjh_ut_*`（仓库既有约定）；Windows 上绝对路径 "/tmp" 会落到
 * 当前盘根目录（`C:\tmp`），普通用户无权限创建（实测 FSError -13 Permission denied），
 * 因此统一落到 %TEMP%（可用 CJH_TEST_TMP 覆盖）。
 */
@When[os == "Windows"]
internal func testTmpPath(name: String): String {
    var root = ""
    if (let Some(t) <- TermEnv.getenv("CJH_TEST_TMP")) {
        root = t
    }
    if (root.size == 0) {
        if (let Some(t) <- TermEnv.getenv("TEMP")) {
            root = t
        }
    }
    if (root.size == 0) {
        root = "."
    }
    return root + "\\cjh_ut_" + name
}

@When[os != "Windows"]
internal func testTmpPath(name: String): String {
    return "/tmp/cjh_ut_" + name
}

/**
 * 递归清理后重建测试目录。
 *
 * `std.fs.removeIfExists(path, recursive: true)` 即可递归删除（旧注释称"仓颉无递归
 * 删除 API → bash rm -rf"已过期：那条 bash 依赖在 Windows 上直接抛异常，导致目录
 * 残留、下次 Directory.create 因不幂等而失败）。
 */
internal func freshTestDir(path: String): String {
    try {
        removeIfExists(path, recursive: true)
    } catch (e: Exception) {
        ()
    }
    Directory.create(path, recursive: true)
    return path
}
