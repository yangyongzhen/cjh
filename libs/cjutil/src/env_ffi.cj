package cjutil

/**
 * getenv FFI（独立包避免重复声明）
 * foreign 函数名与 libc 符号 getenv 一致，链接时解析到 libc
 */
@C
foreign func getenv(name: CString): CPointer<UInt8>

// chdir：切换进程工作目录（web 工作区切换用）
@C
foreign func chdir(path: CString): Int32

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

    /**
     * 运行时切换进程工作目录（工作区切换）。
     * 成功后后续相对路径工具（read_file/bash 等）在新 cwd 下工作。
     */
    public static func changeWorkingDirectory(path: String): Bool {
        unsafe {
            let r = chdir(LibC.mallocCString(path))
            return r == 0
        }
    }

    /**
     * 跨平台用户主目录：
     *   Windows → USERPROFILE（C:\Users\<name>，无 HOME 环境变量）
     *   POSIX   → HOME
     *   均缺失  → /root（极端兜底）
     */
    public static func homeDir(): String {
        let up = getenv("USERPROFILE")
        if (up.isSome()) {
            let v = up.getOrThrow()
            if (v.size > 0) {
                return v
            }
        }
        return getenv("HOME") ?? "/root"
    }
}
