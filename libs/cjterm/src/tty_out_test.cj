package cjterm

import std.collection.*

/**
 * `ttyOutWrite` 家族的底层写路径测试。
 *
 * 只测"字节是否真的送到了目标 fd"这条可观测契约（用 pipe(2) 造一对 fd，
 * 写进去再从读端取回来逐字节比对）；`ttyOutSuppress/ttyOutRestore` 涉及**进程级
 * fd 1 重定向**，在单测进程里做会污染测试框架自己的输出（一旦断言失败，后续报告
 * 都会被写进 /dev/null），因此这两个函数的契约交给真实 PTY 场景验证：
 * scripts/tui_pty_test.py（全量场景）+ scripts/e2e_warn_harness.py 的
 * /proc/<pid>/fd/1 → /dev/null 结构性断言。
 *
 * 另：同款 dup/dup2 配方（suppressStderr）已在 term_posix.cj 跑了很久，
 * 这里不重复测系统调用本身。
 */
// pipe(2)：造一对 fd（读端 / 写端）
@C
foreign func pipe(fds: CPointer<Int32>): Int32

// 1.0.5 的 Option 没有 getOrThrow()，与 term_posix.cj 一致用 if (let p <- ...) 收口
private func allocI32(count: Int64): CPointer<Int32> {
    unsafe {
        if (let p <- LibC.malloc<Int32>(count: count)) {
            return p
        }
        throw Exception("malloc<Int32> 失败")
    }
}

private func allocBytes(count: Int64): CPointer<UInt8> {
    unsafe {
        if (let p <- LibC.malloc<UInt8>(count: count)) {
            return p
        }
        throw Exception("malloc<UInt8> 失败")
    }
}

@Test
public class TtyOutWriteTest {

    /** 从 fd 读回最多 cap 字节（按字节比对，不经过解码，避免把编码问题混进来） */
    private func readBytes(fd: Int32, cap: Int64): Array<Byte> {
        unsafe {
            let buf = allocBytes(cap)
            let n = read(fd, buf, UInt64(cap))
            var out = ArrayList<Byte>()
            if (n > 0) {
                for (i in 0..n) {
                    out.add(buf.read(i))
                }
            }
            LibC.free(buf)
            return out.toArray()
        }
    }

    private func assertBytesEqual(actual: Array<Byte>, expected: String): Unit {
        let exp = expected.toArray()
        @Assert(actual.size, exp.size)
        for (i in 0..exp.size) {
            @Assert(actual[i], exp[i])
        }
    }

    /** 主路径：多字节 UTF-8 整段送达（不是逐字节十进制那种坏法） */
    @TestCase
    public func testWriteAllRoundTripMultibyte(): Unit {
        unsafe {
            let fds = allocI32(2)
            @Assert(pipe(fds), 0)
            let rfd = fds.read(0)
            let wfd = fds.read(1)
            let text = "中文abc\n"
            @Assert(writeAllFd(wfd, text), true)
            close(wfd)
            this.assertBytesEqual(this.readBytes(rfd, 64), text)
            close(rfd)
            LibC.free(fds)
        }
    }

    /** 边界：空串算成功且不写任何字节 */
    @TestCase
    public func testWriteAllEmptyString(): Unit {
        unsafe {
            let fds = allocI32(2)
            @Assert(pipe(fds), 0)
            let rfd = fds.read(0)
            let wfd = fds.read(1)
            @Assert(writeAllFd(wfd, ""), true)
            close(wfd)  // 必须关掉写端：否则空管道 read() 永久阻塞
            @Assert(this.readBytes(rfd, 16).size, 0)
            close(rfd)
            LibC.free(fds)
        }
    }

    /** 错误路径：非法 fd 返回 false，不抛异常 */
    @TestCase
    public func testWriteAllBadFdReturnsFalse(): Unit {
        @Assert(writeAllFd(-1, "x"), false)
        @Assert(writeAllFd(999999, "x"), false)
    }
}
