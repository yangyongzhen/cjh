package cjcfg

/**
 * getenv FFI（独立包避免重复声明）
 * foreign 函数名与 libc 符号 getenv 一致，链接时解析到 libc
 */
@C
foreign func getenv(name: CString): CPointer<UInt8>

public class EnvFfi {
    /**
     * 读取环境变量；未设置返回 None
     */
    public static func getenv(name: String): Option<String> {
        unsafe {
            let p = getenv(LibC.mallocCString(name))
            if (p.isNull()) {
                return None
            }
            let cs = CString(p)
            return Some(cs.toString())
        }
    }
}
