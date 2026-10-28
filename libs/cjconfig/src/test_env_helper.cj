package cjconfig

/**
 * 测试辅助：环境变量写入（libc setenv，POSIX）。
 * 独立文件避免 @Test 宏对文件级函数的限制。
 *
 * @When[os != "Windows"]：setenv 是 POSIX 符号，Windows 原生链接会报
 * `undefined symbol: setenv`（此前声明与用法都没守卫，Windows 上 cjconfig 一例都跑不了）。
 */
@When[os != "Windows"]
@C
foreign func setenv(name: CString, value: CString, overwrite: Int32): Int32

@When[os != "Windows"]
public func setEnvForTest(name: String, value: String): Unit {
    unsafe {
        setenv(LibC.mallocCString(name), LibC.mallocCString(value), 1)
    }
}

/**
 * 跨平台测试临时目录：POSIX `/tmp/<name>`，Windows `%TEMP%\<name>`。
 *
 * Windows 上绝对路径 "/tmp" 会落到当前盘根（C:\tmp），普通用户创建即
 * FSError -13 Permission denied（与 cjterm 同款坑）。
 */
@When[os == "Windows"]
public func testTmpPath(name: String): String {
    unsafe {
        let p = getenv(LibC.mallocCString("TEMP"))
        if (!p.isNull()) {
            let v = CString(p).toString()
            if (v.size > 0) {
                return v + "\\" + name
            }
        }
    }
    return ".\\" + name
}

@When[os != "Windows"]
public func testTmpPath(name: String): String {
    return "/tmp/" + name
}
