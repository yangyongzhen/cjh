package cjh

/**
 * 环境变量读取（FFI getenv 封装）
 *
 * 单一职责：把 libc getenv 包装成类型安全的 Option<String> API。
 * 供 makeProvider、各入口模式（runWeb/runCli/runJson/runTui）读取
 * CJH_PROVIDER、ANTHROPIC_API_KEY、CJH_MOCK 等环境变量。
 */

@C
foreign func getenv(name: CString): CPointer<UInt8>

/**
 * 读取环境变量（FFI getenv，返回空指针表示未设置）
 */
func readEnv(name: String): Option<String> {
    unsafe {
        let p = getenv(LibC.mallocCString(name))
        if (p.isNull()) {
            return None
        }
        let cs = CString(p)
        return Some(cs.toString())
    }
}
