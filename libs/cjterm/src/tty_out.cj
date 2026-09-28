package cjterm

/**
 * TUI 输出与 fd 1 解耦（结构性防护）。
 *
 * 动机：第三方库会把诊断信息**直接写到 fd 1**，它绕过仓颉日志系统
 * （`setGlobalLogger(NoopLogger())` 压不住），也绕过 TUI 自己的画布，
 * 于是在 TUI 里表现为输入栏凭空多出一行，例如
 * `[ConnNode#sendRequestTimeout readTimer] Client1.1 read response timeout`
 * （见 docs/开发文档与踩坑记录.md §3.17 / §3.41）。逐个堵"哪条路径会泄漏 WARN"
 * 只能算打补丁，这里改成结构性隔离：
 *
 *   1. 启动时 `dup(1)` 出一个私有 fd（仍指向终端），记下来；
 *   2. 把 **fd 1 重定向到 /dev/null**；
 *   3. TUI 改用私有 fd 渲染（ttyOutWrite），退出前 ttyOutRestore() 还原 fd 1。
 *
 * 效果：任何库（stdx 的 readTimer 线程、C/C++ 依赖里的 printf）往 fd 1 写的东西
 * 都进不了终端；TUI 画面照旧。与仓内既有 stderr 屏蔽同源
 * （term_posix.suppressStderr：dup(2) + dup2(/dev/null, 2)），区别是 stdout 这一侧
 * 必须**保留**一个可用 fd 继续写，所以多暴露 ttyOutFd()。
 *
 * 平台：POSIX 走 dup/dup2/open；Windows 不启用（ttyOutSuppress 返回 false，
 * 写入回落 print），Windows 行为与改动前完全一致。
 */

// O_WRONLY（Linux/macOS 同为 1）
private let TTY_O_WRONLY: Int32 = 1

// ===== POSIX：真正做隔离 =====

@When[os != "Windows"]
@C
foreign func write(fd: Int32, buf: CPointer<UInt8>, count: UInt64): Int64

@When[os != "Windows"]
private var ttyOutSavedFd: Int32 = -1

/**
 * 把 fd 1 换成 /dev/null，保留一个指向原终端的私有 fd。
 * 返回 false = 未启用隔离（Windows 或系统调用失败），调用方应回落 print。
 */
@When[os != "Windows"]
public func ttyOutSuppress(): Bool {
    unsafe {
        if (ttyOutSavedFd >= 0) {
            return true  // 已隔离
        }
        let saved = dup(1)
        if (saved < 0) {
            return false
        }
        let devnull = open(LibC.mallocCString("/dev/null"), TTY_O_WRONLY)
        if (devnull < 0) {
            close(saved)
            return false
        }
        if (dup2(devnull, 1) < 0) {
            close(devnull)
            close(saved)
            return false
        }
        close(devnull)
        ttyOutSavedFd = saved
        return true
    }
}

/** 还原 fd 1：还原后退出路径的常规 print 照常可见 */
@When[os != "Windows"]
public func ttyOutRestore(): Unit {
    unsafe {
        if (ttyOutSavedFd >= 0) {
            dup2(ttyOutSavedFd, 1)
            close(ttyOutSavedFd)
            ttyOutSavedFd = -1
        }
    }
}

/** 私有终端 fd；-1 = 当前未隔离（此时应走 print） */
@When[os != "Windows"]
public func ttyOutFd(): Int32 {
    return ttyOutSavedFd
}

/**
 * 整段写到任意 fd。返回 false = 写失败。
 *
 * 说明：对终端做一次 `write(2)` 即可写完（阻塞 fd、帧远小于内核缓冲）；
 * 这里不做部分写的指针偏移续写——仓内 CPointer 一律用 read/write(offset) 访问，
 * 不做指针算术（见 term_posix 的 readU32/writeU32 先例）。
 */
@When[os != "Windows"]
public func writeAllFd(fd: Int32, text: String): Bool {
    if (fd < 0) {
        return false
    }
    let bytes = text.toArray()
    if (bytes.size == 0) {
        return true
    }
    unsafe {
        if (let buf <- LibC.malloc<UInt8>(count: bytes.size)) {
            for (i in 0..bytes.size) {
                buf.write(i, bytes[i])
            }
            let n = write(fd, buf, UInt64(bytes.size))
            LibC.free(buf)
            return n == Int64(bytes.size)
        }
        return false
    }
}

/** TUI 渲染 / 终端控制统一出口：已隔离 → 私有 fd；未隔离 → print */
@When[os != "Windows"]
public func ttyOutWrite(text: String): Unit {
    if (ttyOutSavedFd >= 0) {
        let _ = writeAllFd(ttyOutSavedFd, text)
    } else {
        print(text, flush: true)
    }
}

// ===== Windows：不启用隔离（行为与改动前一致）=====

@When[os == "Windows"]
public func ttyOutSuppress(): Bool {
    return false
}

@When[os == "Windows"]
public func ttyOutRestore(): Unit {}

@When[os == "Windows"]
public func ttyOutFd(): Int32 {
    return -1
}

@When[os == "Windows"]
public func writeAllFd(fd: Int32, text: String): Bool {
    return false
}

@When[os == "Windows"]
public func ttyOutWrite(text: String): Unit {
    print(text, flush: true)
}
