package cjconfig

/**
 * 测试辅助：环境变量写入（libc setenv，POSIX）。
 * 独立文件避免 @Test 宏对文件级函数的限制。
 */
@C
foreign func setenv(name: CString, value: CString, overwrite: Int32): Int32

public func setEnvForTest(name: String, value: String): Unit {
    unsafe {
        setenv(LibC.mallocCString(name), LibC.mallocCString(value), 1)
    }
}
