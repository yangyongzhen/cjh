package cjterm

/**
 * 测试辅助：环境变量写入（libc setenv，POSIX）。
 * 独立文件避免 @Test 宏对文件级函数的限制（对齐 cjconfig 的 test_env_helper）。
 * @When[os != "Windows"]：setenv 是 POSIX 符号，Windows 构建必须排除
 * （否则编进静态库后链接 undefined symbol——v1.3.16 winbuild 踩坑）。
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
