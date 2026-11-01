package cjh.tests

import cjh.tools.*

/**
 * 现场快照裁剪（clipProcSnapshot）单测。
 *
 * 背景：超时时要把"那一刻还活着的进程"回投给模型/灵渠 trace ——
 * 0.39.5 的 `main.exe build … | tail -50` 卡死现场，事后已无从查证是谁握着管道。
 * 这里是纯函数，主路径 + 截断 + 边界（首行超长 / 空输入）全覆盖。
 */
@Test
public class ShellDiagTest {

    @TestCase
    public func testClipDropsHeaderAndBlankLines(): Unit {
        let raw = "UID        PID  PPID  C STIME TTY      TIME CMD\n" +
            "root  1000  1  0 10:00 ? 00:00:00 bash\n" +
            "\n" +
            "root  1001  1000  0 10:01 ? 00:00:00 tail -50\n"
        let got = clipProcSnapshot(raw)
        @Assert(got.contains("UID"), false)        // ps 表头不占预算
        @Assert(got.contains("tail -50"), true)     // 真线索保留
        @Assert(got.contains("bash"), true)
        @Assert(got.contains("\n\n"), false)        // 空行已去
    }

    @TestCase
    public func testClipTruncatesByLines(): Unit {
        var raw = ""
        for (i in 0..40) {
            raw += "proc-${i}\n"
        }
        let got = clipProcSnapshot(raw)
        @Assert(got.contains("proc-0"), true)
        @Assert(got.contains("proc-14"), true)       // 恰好 15 行（SNAP_MAX_LINES）
        @Assert(got.contains("proc-15"), false)      // 第 16 行起被截掉
        @Assert(got.contains("快照已截断"), true)
    }

    @TestCase
    public func testClipKeepsLongFirstLineButClipsIt(): Unit {
        // 边界：第一行就超过字符预算 —— 必须仍然给出线索，不能返回空串
        let long = repeatStr("x", 950)
        let got = clipProcSnapshot(long)
        @Assert(got.size > 0, true)
        @Assert(got.contains("现场快照"), true)
        @Assert(got.size < 950, true)                // 单行已被裁短
        @Assert(got.contains("…"), true)             // 裁短有标记
    }

    @TestCase
    public func testClipCharBudgetStopsMidway(): Unit {
        // 每行先被裁到 SNAP_MAX_LINE_CHARS(200)+1，于是 4 行约 804 字符、
        // 第 5 行就会顶破 SNAP_MAX_CHARS(900) —— 字符预算真的会生效
        var raw = ""
        for (i in 1..7) {
            raw += "L${i}" + repeatStr("z", 300) + "\n"
        }
        let got = clipProcSnapshot(raw)
        @Assert(got.contains("L4"), true)            // 第 4 行还在
        @Assert(got.contains("L5"), false)           // 第 5 行因字符预算被砍
        @Assert(got.contains("快照已截断"), true)
    }

    @TestCase
    public func testClipEmptyReturnsEmpty(): Unit {
        @Assert(clipProcSnapshot("").size, 0)
        @Assert(clipProcSnapshot("  \n\n \n").size, 0)
        // 只有表头 = 没有线索，同样返回空串（调用方据此不回投垃圾）
        @Assert(clipProcSnapshot("UID PID PPID C STIME TTY TIME CMD\n").size, 0)
    }
}
