package cjcfg

import cjutil.*

/**
 * 跨平台测试临时目录（测试专供；文件名 `*_test.cj` → 发布构建排除）
 *
 * POSIX 沿用 `/tmp/<name>`（仓库既有约定）；Windows 上绝对路径 "/tmp" 会落到当前盘根
 * （C:\tmp / E:\tmp），普通用户创建即 `FSException ... return -13: Permission denied`，
 * 故统一落到 %TEMP%（可用 CJH_TEST_TMP 覆盖）。
 */
@When[os == "Windows"]
internal func testTmpPath(name: String): String {
    var root = EnvFfi.getenv("CJH_TEST_TMP") ?? ""
    if (root.size == 0) {
        root = EnvFfi.getenv("TEMP") ?? ""
    }
    if (root.size == 0) {
        root = "."
    }
    return root + "\\" + name
}

@When[os != "Windows"]
internal func testTmpPath(name: String): String {
    return "/tmp/" + name
}
