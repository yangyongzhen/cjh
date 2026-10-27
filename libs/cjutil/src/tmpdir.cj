package cjutil

/**
 * 跨平台临时目录根
 *
 * POSIX：`/tmp`（仓库既有约定）；Windows：`%TEMP%`（可用 `CJH_TMP` 覆盖）。
 *
 * 为什么需要：Windows 上绝对路径 `/tmp/...` 会落到**当前盘根**（`C:\tmp` / `E:\tmp`），
 * 普通用户创建即 `FSException ... return -13: Permission denied`（实测），
 * 于是所有以 `/tmp/` 为默认落点的路径（mock 校验文件、spill、测试临时目录）全部炸掉。
 */
@When[os == "Windows"]
public func tmpDir(): String {
    if (let Some(v) <- EnvFfi.getenv("CJH_TMP")) {
        if (v.size > 0) {
            return v
        }
    }
    if (let Some(v) <- EnvFfi.getenv("TEMP")) {
        if (v.size > 0) {
            return v
        }
    }
    return "."
}

@When[os != "Windows"]
public func tmpDir(): String {
    return "/tmp"
}

/**
 * 临时目录下的相对路径拼接（跨平台分隔符归一化）
 *
 * `tmpPath("cjh_ut_x")` → POSIX `/tmp/cjh_ut_x`；Windows `%TEMP%\cjh_ut_x`。
 * 传入的 name 可含 `/`（如 `"cjh_ut_x/sub"`），Windows 上统一改成 `\`。
 */
@When[os == "Windows"]
public func tmpPath(name: String): String {
    return tmpDir() + "\\" + name.replace("/", "\\")
}

@When[os != "Windows"]
public func tmpPath(name: String): String {
    return tmpDir() + "/" + name
}
