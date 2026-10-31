package cjh.tools

import std.collection.*
import std.process.*
import cjutil.*
import cjterm.*

/**
 * shell 会话异常时的**进程现场快照**（灵渠迁移台 0.39.5 现场复盘的产物）
 *
 * 现象：agent 跑 `main.exe build … 2>&1 | tail -50`，命令 27 秒就跑完、落档也写了，
 * 但 tool_done 永远不来。会话的完成判据是「stdout 上出现结束标记」，而标记排在
 * 整条管道**之后**；`tail` 要等 stdin EOF 才退出，只要左端命令留下任何**后代**
 * 还握着同一个写端，tail 就不退、`}` 不返回、标记永不出现。
 * 实测：`{ bash -c 'sleep 6 & echo hi' | tail -1; }` 里 tail 真的多等了 6 秒。
 *
 * 事后复盘最缺的不是推理，而是"当时谁还活着"。所以超时时**先存证再杀会话**：
 * 抓一份进程快照塞进 ToolResult —— 它会随 tool_done 进灵渠的
 * `<工程>/.lingqu/agent/trace.jsonl`，事后可追。
 */

// 快照上限：bash 工具结果整体截断阈值 2000 字符，得给"提示"和命令已有输出留位置
public const SNAP_MAX_LINES: Int64 = 15
public const SNAP_MAX_CHARS: Int64 = 900
public const SNAP_MAX_LINE_CHARS: Int64 = 200

/**
 * 裁剪进程快照（纯函数，可单测）：去空行、去 ps 表头，逐行裁长，
 * 按行数与字符数截断。**首行必留**——只剩一行的极端输入也要给出线索，
 * 不能因为"第一行就超预算"而返回空串。
 *
 * @param text 原始输出（ps -ef / tasklist 的文本）
 * @return 带标题的快照文本；无线索时返回空串（调用方据此不回投垃圾）
 */
public func clipProcSnapshot(text: String): String {
    if (text.trimAscii().size == 0) {
        return ""
    }
    var kept = ArrayList<String>(0)
    var used: Int64 = 0
    var clipped = false
    for (line in text.split("\n", -1)) {
        var t = line.trimAscii()
        if (t.size == 0) {
            continue
        }
        // ps -ef 表头（UID PID PPID C STIME TTY TIME CMD）
        if (t.startsWith("UID") && t.contains("PID") && t.contains("CMD")) {
            continue
        }
        if (t.size > SNAP_MAX_LINE_CHARS) {
            t = t[0..SNAP_MAX_LINE_CHARS] + "…"
        }
        // 字符预算只对第二条起生效：首行信息量最大，宁可超一点也不丢
        if (kept.size >= SNAP_MAX_LINES || (kept.size > 0 && used + t.size > SNAP_MAX_CHARS)) {
            clipped = true
            break
        }
        kept.add(t)
        used += t.size
    }
    if (kept.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    sb.append("现场快照（那一刻还活着的进程，看有没有 tail/head/grep 之类的在握着管道）：\n")
    var first = true
    for (k in kept) {
        if (!first) {
            sb.append("\n")
        }
        sb.append(k)
        first = false
    }
    if (clipped) {
        sb.append("\n（快照已截断）")
    }
    return sb.toString()
}

/**
 * 采集 + 裁剪进程快照。取不到就返回空串——诊断信息绝不能把错误路径本身搞崩。
 *
 * 注：Windows 上走 Git Bash 时 `ps -ef` 只看得到 MSYS 进程（bash/tail/python…），
 * 够用：握着管道的正是这些；PowerShell 模式退化为 tasklist。
 */
public func procSnapshotOf(shell: ShellProvider): String {
    let argv: Array<String> = if (shell.isBash) {
        ["-c", "ps -ef"]
    } else {
        ["-NoProfile", "-Command", "tasklist /fo table /nh"]
    }
    try {
        let (_, stdoutBytes, _) = executeWithOutput(shell.shellPath, argv)
        return clipProcSnapshot(safeFromUtf8(stdoutBytes))
    } catch (e: Exception) {
        return ""
    }
}
