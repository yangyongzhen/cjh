package cjh.tools

import std.collection.*
import std.process.*
import std.io.*
import std.sync.*
import std.time.*
import std.convert.Parsable
import cjutil.*

/**
 * 持久 bash 会话（P1-3，对齐 omp brush shell）：
 * 单个 bash 进程跨命令保留 cwd/env，避免多步构建/测试反复重设环境。
 *
 * 实现（异步线程 + 超时 kill）：
 * - 读线程阻塞读 stdout 管道直到完成标记（std.io InputStream.read 阻塞无超时，
 *   但由独立线程承担，主线程不阻塞）
 * - 主线程轮询共享完成标志（Mutex 保护），超时 → terminate(force) 杀会话，
 *   读线程随管道 EOF 自然结束；下次调用重建会话
 * - 命令 `exit N` 直接退出会话进程 → 读线程 EOF → wait() 取退出码
 * - 大括号 { cmd; } 当前 shell 执行（cd/export 持久），2>&1 合并 stderr
 * - Mutex 串行化（V2d 并发下 bash 调用逐个执行）
 */
public class BashSession {
    private var proc: Option<SubProcess> = None
    private let lock: Mutex = Mutex()
    private var seq: Int64 = 0
    // 已回收(terminate+wait)的会话进程计数——退出/超时后必须 wait 才回收僵尸。
    // 旧实现只 terminate(force) 不 wait：每个超时命令都留下一个未回收僵尸，
    // 长会话累计出"4 个未回收僵尸子进程"（2026-09-03 事故现场）。
    private var reapedCount: Int64 = 0

    public init() {}

    /**
     * 执行命令，返回 (退出码, 合并输出)。
     * 超时返回 (-1, 超时提示)；会话自动重建。
     */
    public func execute(cmd: String, timeoutSecs: Int64): (Int64, String) {
        this.lock.lock()
        try {
            let p = this.ensureStarted()
            this.seq += 1
            let marker = "__CJH_END_${this.seq}__"
            // 大括号当前 shell 执行（cwd/env 持久）；2>&1 合并 stderr；
            // exit N 会退出会话进程（EOF 路径由 wait() 取退出码）
            let full = "{ " + cmd + "; } 2>&1; echo \"__CJH_CODE_$?__\"; echo " + marker + "\n"
            p.stdInPipe.write(full.toArray())
            p.stdInPipe.flush()  // 必须 flush：否则 bash 收不到命令（管道缓冲）→ 读线程无输出 → wait() 死锁
            // 读线程：阻塞读 stdout 直到 marker（或 EOF），结果写共享状态
            let state = SessionReadState()
            spawn {
                let (out, found) = BashSession.readUntilMarker(p.stdOutPipe, marker)
                state.lock.lock()
                try {
                    state.output = out
                    state.foundMarker = found
                    state.done = true
                } finally {
                    state.lock.unlock()
                }
            }
            // 主线程轮询完成标志（超时用真实时间——sleep 在系统负载高时
            // 实际远大于 50ms，逻辑计数会导致超时严重滞后）
            let timeoutMs = if (timeoutSecs > 0) { timeoutSecs * 1000 } else { Int64(600000) }
            let start = DateTime.now()
            var done: Bool = false
            while (true) {
                state.lock.lock()
                let d = state.done
                state.lock.unlock()
                if (d) {
                    done = true
                    break
                }
                if ((DateTime.now() - start).toMilliseconds() >= timeoutMs) {
                    break
                }
                sleep(Duration.millisecond * 50)
            }
            if (!done) {
                // 超时：杀会话（命令可能挂死），读线程随 EOF 结束
                this.killSession()
                return (-1, "⚠️ 命令超时（${timeoutSecs}s 未完成，已终止会话）")
            }
            // 完成：取输出；EOF 提前（如 exit N，未遇到 marker）→ wait() 拿退出码
            state.lock.lock()
            let output = state.output
            let found = state.foundMarker
            state.lock.unlock()
            if (found) {
                return BashSession.parseOutput(output, marker)
            }
            // EOF 路径：命令退出会话（exit N 或崩溃），退出码 = 进程退出码。
            // wait 带超时防死锁（进程可能未真正退出）
            let exitCode = try {
                p.wait(timeout: Duration.second * 5)
            } catch (e: Exception) {
                this.killSession()
                Int64(-1)
            }
            this.proc = None  // 进程已死，下次重建
            return (exitCode, output)
        } catch (e: Exception) {
            this.killSession()
            return (-1, "命令执行异常: ${e}")
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 关闭会话（释放进程）
     */
    public func close(): Unit {
        this.lock.lock()
        try {
            this.killSession()
        } finally {
            this.lock.unlock()
        }
    }

    private func ensureStarted(): SubProcess {
        match (this.proc) {
            case Some(p) =>
                if (p.isAlive()) {
                    return p
                }
                this.proc = None
            case None => ()
        }
        // 持久 bash：stdin 管道写命令，stdout/stderr 管道（读线程消费），
        // stderr 由命令 2>&1 合并进 stdout
        let p = launch("/bin/bash", Array<String>(0, repeat: ""), stdIn: Pipe, stdOut: Pipe, stdErr: Pipe)
        this.proc = Some(p)
        return p
    }

    private func killSession(): Unit {
        match (this.proc) {
            case Some(p) =>
                try {
                    p.terminate(force: true)
                } catch (e: Exception) {
                    ()
                }
                // terminate(force) 只发 SIGKILL——进程随即变僵尸，须 wait 才回收。
                // 带 5s 超时兜底（防极端情况 SIGKILL 未即时生效）；wait 成功后
                // 僵尸被回收，读线程随管道 EOF 自然结束，不再泄漏子进程。
                try {
                    let _ = p.wait(timeout: Duration.second * 5)
                    this.reapedCount += 1
                } catch (e: Exception) {
                    ()
                }
                this.proc = None
            case None => ()
        }
    }

    /**
     * 已回收的会话进程数（测试观测：killSession/close 必须 wait 回收僵尸）
     */
    public func testReapedCount(): Int64 { return this.reapedCount }

    /**
     * 读管道直到出现 marker（或 EOF），返回 marker 前内容。
     * 阻塞读——由独立线程承担，主线程轮询完成标志控制超时。
     *
     * UTF-8 安全解码（踩坑 §3.15）：旧实现逐字节 `String(Rune(byte))` 拼接，
     * 把中文 stdout 的每个 UTF-8 字节当成独立 Latin-1 码点（"读"=E8 AF BB →
     * "éè»"）——bash 输出中文全乱码。现累积字节，每轮在最后一个完整 UTF-8
     * 字符边界处整段 safeFromUtf8 解码；半截多字节字符留 pending 等下个块。
     * marker 为纯 ASCII（__CJH_END_N__），其字节必为 0x00-0x7F，永远落在已解码
     * 段（边界探测只可能把 ≥0x80 的多字节尾字节留 pending），搜索不受影响。
     */
    private static func readUntilMarker(input: InputStream, marker: String): (String, Bool) {
        var decoded = StringBuilder()
        var pending = ArrayList<Byte>(0)
        let buf = Array<Byte>(4096, repeat: 0)
        while (true) {
            let n = input.read(buf)
            if (n <= 0) {
                break  // EOF：会话进程退出（如 exit N）
            }
            for (i in 0..n) {
                pending.add(buf[i])
            }
            // 找最后一个完整 UTF-8 字符的边界：从末尾向前探测，遇到多字节
            // 起始字节且剩余字节不足其序列长度时，尾字节留 pending
            let total = pending.size
            var safeEnd = total
            var probe = total - 1
            while (probe >= 0 && probe >= total - 4) {
                let b = pending[probe]
                if (b >= 0x80u8) {
                    let cont = probe + 1 < total  // 仍有后续字节（当前块末尾）
                    var need: Int64 = 1
                    if ((b & 0xE0u8) == 0xC0u8) { need = 2 }
                    else if ((b & 0xF0u8) == 0xE0u8) { need = 3 }
                    else if ((b & 0xF8u8) == 0xF0u8) { need = 4 }
                    if (cont && total - probe < need) { safeEnd = probe }
                    break
                }
                probe -= 1
            }
            if (safeEnd > 0) {
                var part = Array<Byte>(safeEnd, repeat: 0)
                for (i in 0..safeEnd) {
                    part[i] = pending[i]
                }
                decoded.append(safeFromUtf8(part))
            }
            // pending 保留 [safeEnd, total) 的尾字节（半截多字节字符），整体替换
            var tail = ArrayList<Byte>(0)
            for (i in safeEnd..total) {
                tail.add(pending[i])
            }
            pending = tail
            let cur = decoded.toString()
            let idx = cur.indexOf(marker)
            if (idx.isSome()) {
                return (cur[0..idx.getOrThrow()], true)
            }
        }
        // EOF：flush 残留（容错替换非法尾部字节）
        if (pending.size > 0) {
            var rest = Array<Byte>(pending.size, repeat: 0)
            for (i in 0..pending.size) {
                rest[i] = pending[i]
            }
            decoded.append(safeFromUtf8(rest))
        }
        return (decoded.toString(), false)
    }

    /**
     * 解析输出：去掉完成标记，提取退出码行（__CJH_CODE_N__）。
     */
    private static func parseOutput(raw: String, marker: String): (Int64, String) {
        var body = raw
        let markerIdx = raw.indexOf(marker)
        if (markerIdx.isSome()) {
            body = raw[0..markerIdx.getOrThrow()]
        }
        let lines = body.split("\n", -1)
        var code: Int64 = 0
        var content = body
        var li = lines.size - 1
        while (li >= 0 && lines[li].size == 0) {
            li -= 1
        }
        if (li >= 0 && lines[li].startsWith("__CJH_CODE_") && lines[li].endsWith("__")) {
            let codeLine = lines[li]
            let numPart = codeLine[11..codeLine.size - 2]
            try {
                code = Int64.parse(numPart)
            } catch (e: Exception) {
                code = -1
            }
            var contentEnd = body.size - codeLine.size
            if (contentEnd > 0 && body[contentEnd - 1] == 10u8) {  // '\n'
                contentEnd -= 1
            }
            content = body[0..contentEnd]
        }
        return (code, content)
    }
}

/**
 * 读线程共享状态（仓颉 lambda 捕获可变局部限制 → 类实例 + Mutex）
 */
class SessionReadState {
    public let lock: Mutex = Mutex()
    public var done: Bool = false
    public var foundMarker: Bool = false
    public var output: String = ""
}
