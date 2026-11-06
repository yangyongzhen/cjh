package cjh.tests

import std.collection.*
import std.time.*
import std.sync.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * 后台任务（B-1 bash_start / bash_poll / bash_kill）单元测试
 *
 * 分两半：
 * - BackgroundPureTest：纯函数（UTF-8 切点、交付切点、包装拼装、耗时格式、字节配置）
 *   与进程无关，各平台都跑；
 * - BashBackgroundTest：真起进程验证「不阻塞 / 增量交付 / 槽位拒绝 / kill / 超时 / 中文」，
 *   @When[os != "Windows"]——契约建立在 setsid + 进程组 kill + /bin/bash 上。
 */
@Test
public class BackgroundPureTest {

    /**
     * UTF-8 边界回退：非终态交付不能切开多字节字符（否则 poll 出中文乱码）
     */
    @TestCase
    public func testUtf8BoundaryCut(): Unit {
        // 「你」= 3 字节；切在 2 处必须回退到 0（整字都不完整）
        let yi = "你".toArray()
        @Assert(yi.size, 3)
        @Assert(utf8BoundaryCut(yi, 2), 0)
        @Assert(utf8BoundaryCut(yi, 3), 3)
        // 纯 ASCII：原样返回
        let abc = "abc".toArray()
        @Assert(utf8BoundaryCut(abc, 2), 2)
        // 边界值：0 / 负数都返回 0（空交付，不 panic）
        @Assert(utf8BoundaryCut(abc, 0), 0)
        @Assert(utf8BoundaryCut(abc, -1), 0)
        // 「a你」= 4 字节，切在 3 处回退到 1（保住完整的 a，把残缺的「你」留给下一批）
        let mixed = "a你".toArray()
        @Assert(mixed.size, 4)
        @Assert(utf8BoundaryCut(mixed, 3), 1)
    }

    /**
     * 交付切点：终态全交；非终态优先交到完整行；无完整行且未占满预算就等下一批
     */
    @TestCase
    public func testDeliverCut(): Unit {
        let twoLines = "line1\nline2".toArray()
        // 非终态：只交到最后一个换行（含换行本身）
        @Assert(bgDeliverCut(twoLines, twoLines.size, false, true), 6)
        // 终态：残尾一并交出去，不能把最后一段吞掉
        @Assert(bgDeliverCut(twoLines, twoLines.size, true, false), twoLines.size)
        // 无完整行且预算没满：等下一批，返回 0
        let noNl = "abc".toArray()
        @Assert(bgDeliverCut(noNl, 3, false, false), 0)
        // 无完整行但预算已满：硬切（否则超长单行永远交不出去）
        @Assert(bgDeliverCut(noNl, 3, false, true), 3)
        // 空输入
        @Assert(bgDeliverCut(noNl, 0, false, false), 0)
    }

    /** 状态机线上一词与终态判定（Web 帧/工具文案共用，改名会牵动协议） */
    @TestCase
    public func testStateWire(): Unit {
        @Assert(BgTaskState.BgRunning.wire(), "running")
        @Assert(BgTaskState.BgSucceeded.wire(), "succeeded")
        @Assert(BgTaskState.BgFailed.wire(), "failed")
        @Assert(BgTaskState.BgKilled.wire(), "killed")
        @Assert(BgTaskState.BgTimedOut.wire(), "timeout")
        @Assert(BgTaskState.BgRunning.isTerminal(), false)
        @Assert(BgTaskState.BgSucceeded.isTerminal(), true)
        @Assert(BgTaskState.BgTimedOut.isTerminal(), true)
    }

    /** 配置四键：非正数一律回落默认值（配 0 不能把槽位配成"永远满"） */
    @TestCase
    public func testConfigDefaults(): Unit {
        let d = BgTaskConfig()
        @Assert(d.maxSlots, 8)
        @Assert(d.timeoutMs, 1800000)
        @Assert(d.outputMaxKb, 256)
        @Assert(d.pollMaxBytes, 6000)
        // 显式 0/负数：回落到默认，而不是"0 个槽位"
        let z = BgTaskConfig(0, 0, 0, 0)
        @Assert(z.maxSlots, 8)
        @Assert(z.timeoutMs, 1800000)
        @Assert(z.outputMaxKb, 256)
        @Assert(z.pollMaxBytes, 6000)
        // 正常值原样保留，KB → 字节换算
        let c = BgTaskConfig(2, 5000, 1, 100)
        @Assert(c.maxSlots, 2)
        @Assert(c.timeoutMs, 5000)
        @Assert(c.outputMaxBytes(), 1024)
    }

    /** 耗时格式：三档单位，负数兜底 */
    @TestCase
    public func testFormatElapsed(): Unit {
        @Assert(formatElapsedMs(0), "0.0s")
        @Assert(formatElapsedMs(300), "0.3s")
        @Assert(formatElapsedMs(12300), "12.3s")
        @Assert(formatElapsedMs(83000), "1m23s")
        @Assert(formatElapsedMs(3720000), "1h02m")
        @Assert(formatElapsedMs(-5), "0.0s")
    }

    /** 单引号转义：cwd 里带单引号不能把包装拼碎（否则 cd 失败或命令注入） */
    @TestCase
    public func testShSingleQuote(): Unit {
        @Assert(shSingleQuote("abc"), "'abc'")
        @Assert(shSingleQuote("a'b"), "'a'\\''b'")
    }

    /**
     * shell 包装：三个坑必须钉住
     * 1. 命令体在 `( ... )` 子 shell 里——命令自带 exit 时末尾的 `echo $? > rc` 才写得到；
     * 2. 收尾 `}` 独占一行——heredoc 才收得住（会话 heredoc 踩过同一个坑）；
     * 3. `} < /dev/null`——后台任务没有 stdin，读 stdin 的命令不接 /dev/null 会永久挂住。
     */
    @TestCase
    public func testBuildWrapper(): Unit {
        let w = buildBgWrapper("echo hi", "/tmp", "/bin/bash", true, "/tmp/bg.rc")
        @Assert(w.contains("cd '/tmp' || exit 97; "), true)
        @Assert(w.contains("{ echo hi"), true)
        @Assert(w.contains("\n} < /dev/null 2>&1\n)"), true)
        // 退出码由 shell 自己落文件：父进程侧没有可靠的非阻塞判死手段
        @Assert(w.contains("echo $? > '/tmp/bg.rc'"), true)
        // 收尾大括号独占一行的直接后果：命令里带 heredoc 也能正常闭合
        let h = buildBgWrapper("cat <<EOF\nhello\nEOF", "", "/bin/bash", true, "/tmp/bg.rc")
        @Assert(h.contains("\n} < /dev/null 2>&1\n)"), true)
        // 不给 cwd 就不拼 cd（默认继承 cjh 进程 cwd）
        let noCwd = buildBgWrapper("pwd", "", "/bin/bash", true, "/tmp/bg.rc")
        @Assert(noCwd.contains("cd "), false)
    }
}

/**
 * 真进程契约：不阻塞、增量、槽位、kill、超时、中文。
 *
 * 时序容错按项目老坑留余量（机器满载时单次 sleep 会膨胀数倍），
 * 等待一律用「轮询到终态或上限」而不是固定 sleep。
 */
@When[os != "Windows"]
@Test
public class BashBackgroundTest {

    private func newRegistry(name: String, maxSlots: Int64): BackgroundTaskRegistry {
        return BackgroundTaskRegistry(BgTaskConfig(maxSlots, 600000, 64, 6000),
            testTempDir(name))
    }

    /** 轮询等到终态，返回 wire 值；超时返回 "wait-over" */
    private func waitTerminal(reg: BackgroundTaskRegistry, id: String, limitMs: Int64): String {
        var waited: Int64 = 0
        while (waited < limitMs) {
            // 终态没有监视线程通知，要靠轮询点收割（与产品里每秒节拍同一入口）
            reg.harvestAll()
            match (reg.find(id)) {
                case Some(t) =>
                    if (t.state().isTerminal()) {
                        return t.state().wire()
                    }
                case None => return "missing"
            }
            sleep(Duration.millisecond * 50)
            waited += 50
        }
        return "wait-over"
    }

    /**
     * 核心契约：长命令**不阻塞**。sleep 5 的启动必须在 3s 内返回
     * （若同步等待就是回到了"agent 循环被一条命令卡死"的老问题）。
     */
    @TestCase
    public func testStartDoesNotBlock(): Unit {
        let reg = this.newRegistry("bg_nonblock", 4)
        let t0 = DateTime.now()
        let r = reg.start("sleep 5", "sleeper", "", "/bin/bash", true, 0, 200)
        let elapsed = (DateTime.now() - t0).toMilliseconds()
        try {
            @Assert(r.ok, true)
            @Assert(r.taskId.size > 0, true)
            @Assert(r.text.contains("已启动"), true)
            // 明确告诉调用方"不共享会话 cwd/env"——这是本设计的代价，不能让模型自己撞
            @Assert(r.text.contains("不共享 bash 会话的 cwd/环境变量"), true)
            @Assert(elapsed < 3000, true)
            match (reg.find(r.taskId)) {
                case Some(t) => @Assert(t.state().wire(), "running")
                case None => @Assert("任务已登记", "missing")
            }
        } finally {
            let _ = reg.kill(r.taskId)
        }
    }

    /** 抢跑窗口：短命令一次调用就拿到结果，省掉"start 完再 poll"的一轮往返 */
    @TestCase
    public func testEagerWindowReturnsShortOutput(): Unit {
        let reg = this.newRegistry("bg_eager", 4)
        let r = reg.start("echo hello", "", "", "/bin/bash", true, 0, 3000)
        @Assert(r.ok, true)
        @Assert(r.text.contains("已在启动窗口内结束"), true)
        @Assert(r.text.contains("hello"), true)
    }

    /**
     * 事件源（协议 v6 的底座）：bash_start 成功必须推一条 running 事件
     *
     * Web 面板的第一行完全靠这条事件出现——没有它，任务跑起来了浏览器却一片空白。
     */
    @TestCase
    public func testStartEmitsRunningEvent(): Unit {
        let reg = this.newRegistry("bg_event_start", 4)
        let (events, guard) = this.collectEvents(reg)
        let r = reg.start("sleep 5", "event-sleeper", "", "/bin/bash", true, 0, 0)
        try {
            @Assert(r.ok, true)
            guard.lock()
            var seen: Option<BgTaskEventInfo> = None
            try {
                for (e in events) {
                    if (e.state.wire() == "running") {
                        seen = Some(e)
                    }
                }
            } finally {
                guard.unlock()
            }
            match (seen) {
                case Some(e) =>
                    @Assert(e.taskId, r.taskId)
                    @Assert(e.kind, "bash")
                    @Assert(e.label, "event-sleeper")
                    // running 时退出码是 -1：面板据此决定"还没结束，不显示 exit"
                    @Assert(e.exitCode, -1)
                case None => @Assert("收到 running 事件", "missing")
            }
        } finally {
            let _ = reg.kill(r.taskId)
        }
    }

    /**
     * 终态事件只推一次：重复 finish 不能让面板闪两次 / 客户端统计翻倍
     */
    @TestCase
    public func testTerminalEventEmittedOnce(): Unit {
        let reg = this.newRegistry("bg_event_done", 4)
        let (events, guard) = this.collectEvents(reg)
        let r = reg.start("echo done", "", "", "/bin/bash", true, 0, 3000)
        @Assert(r.ok, true)
        @Assert(this.waitTerminal(reg, r.taskId, 10000), "succeeded")
        // 给读线程收尾留出余量（机器满载时 sleep 会膨胀）
        sleep(Duration.millisecond * 300)
        guard.lock()
        var terminal: Int64 = 0
        var exit = -2
        try {
            for (e in events) {
                match (e.state) {
                    case BgRunning => ()
                    case _ =>
                        terminal += 1
                        exit = e.exitCode
                }
            }
        } finally {
            guard.unlock()
        }
        @Assert(terminal, 1)
        @Assert(exit, 0)
    }

    /**
     * kill 生效也要推终态事件：状态必须是 killed（不是 failed），退出码按真实回收值
     */
    @TestCase
    public func testKillEmitsKilledEvent(): Unit {
        let reg = this.newRegistry("bg_event_kill", 4)
        let (events, guard) = this.collectEvents(reg)
        let r = reg.start("sleep 5", "kill-me", "", "/bin/bash", true, 0, 0)
        @Assert(r.ok, true)
        let _ = reg.kill(r.taskId)
        sleep(Duration.millisecond * 300)
        guard.lock()
        var killed: Option<BgTaskEventInfo> = None
        try {
            for (e in events) {
                if (e.state.wire() == "killed") {
                    killed = Some(e)
                }
            }
        } finally {
            guard.unlock()
        }
        match (killed) {
            case Some(e) => @Assert(e.taskId, r.taskId)
            case None => @Assert("收到 killed 事件", "missing")
        }
        @Assert(this.waitTerminal(reg, r.taskId, 10000), "killed")
    }

    /**
     * 监听方（面板/广播器）抛异常绝不能掀翻任务状态机
     *
     * 同 WsSendGuard 的教训：旁路写失败只该丢一条事件，不该让任务永久卡在 running。
     */
    @TestCase
    public func testListenerExceptionDoesNotBreakTask(): Unit {
        let reg = this.newRegistry("bg_event_throw", 4)
        reg.onEvent = { _: BgTaskEventInfo =>
            throw Exception("面板写失败")
        }
        let r = reg.start("echo survived", "", "", "/bin/bash", true, 0, 3000)
        @Assert(r.ok, true)
        // 抢跑窗口内结束：输出已由 start 早交付（字节游标已推进），后续 poll 不再重复
        @Assert(r.text.contains("survived"), true)
        @Assert(this.waitTerminal(reg, r.taskId, 10000), "succeeded")
    }

    /** 挂事件收集器：返回事件表与其互斥锁（读线程会并发写入） */
    private func collectEvents(reg: BackgroundTaskRegistry): (ArrayList<BgTaskEventInfo>, Mutex) {
        let events = ArrayList<BgTaskEventInfo>()
        let guard = Mutex()
        reg.onEvent = { info: BgTaskEventInfo =>
            guard.lock()
            try {
                events.add(info)
            } finally {
                guard.unlock()
            }
        }
        return (events, guard)
    }

    /**
     * 增量交付：两次 poll 不重复吐同一段输出（字节游标语义），
     * 且第一次 poll 拿到的是完整行。
     */
    @TestCase
    public func testPollIsIncremental(): Unit {
        let reg = this.newRegistry("bg_incremental", 4)
        // eagerMs=0：不抢跑，输出全留给 poll
        let r = reg.start("echo one; sleep 1; echo two", "", "", "/bin/bash", true, 0, 0)
        @Assert(r.ok, true)
        // 等第一行落盘
        var first = ""
        var waited: Int64 = 0
        while (waited < 8000 && first.size == 0) {
            sleep(Duration.millisecond * 100)
            first = reg.poll(r.taskId, 0).output
            waited += 100
        }
        @Assert(first.contains("one"), true)
        @Assert(first.contains("two"), false)
        // 等终态并收剩余：不能把 one 再吐一遍
        let _ = this.waitTerminal(reg, r.taskId, 10000)
        let rest = reg.poll(r.taskId, 0)
        @Assert(rest.output.contains("two"), true)
        @Assert(rest.output.contains("one"), false)
        // 收完再 poll：无新增，不重复
        let again = reg.poll(r.taskId, 0)
        @Assert(again.newBytes, 0)
        @Assert(again.output.size, 0)
    }

    /** 中文与 UTF-8：后台任务输出不因分片解码而乱码 */
    @TestCase
    public func testChineseOutput(): Unit {
        let reg = this.newRegistry("bg_utf8", 4)
        let r = reg.start("echo 仓颉后台任务", "", "", "/bin/bash", true, 0, 3000)
        @Assert(r.ok, true)
        @Assert(r.text.contains("仓颉后台任务"), true)
    }

    /** 槽位满：直接拒绝并说清"几个/上限几个、在跑什么、怎么腾"——不排队 */
    @TestCase
    public func testSlotFullRejected(): Unit {
        let reg = this.newRegistry("bg_slots", 1)
        let r1 = reg.start("sleep 30", "占位", "", "/bin/bash", true, 0, 100)
        @Assert(r1.ok, true)
        try {
            let r2 = reg.start("sleep 30", "第二个", "", "/bin/bash", true, 0, 100)
            @Assert(r2.ok, false)
            @Assert(r2.text.contains("槽位已满"), true)
            @Assert(r2.text.contains("1/1"), true)
            // 必须给出腾槽位的两条路，否则模型只会原地重试
            @Assert(r2.text.contains("bash_poll"), true)
            @Assert(r2.text.contains("bash_kill"), true)
        } finally {
            let _ = reg.kill(r1.taskId)
        }
        // 杀掉后槽位释放，能再起
        let r3 = reg.start("echo ok", "", "", "/bin/bash", true, 0, 2000)
        @Assert(r3.ok, true)
    }

    /** kill：整组进程带走并回收，终态是 killed（不是 timeout/failed） */
    @TestCase
    public func testKill(): Unit {
        let reg = this.newRegistry("bg_kill", 4)
        let r = reg.start("sleep 30", "长任务", "", "/bin/bash", true, 0, 100)
        @Assert(r.ok, true)
        let k = reg.kill(r.taskId)
        @Assert(k.ok, true)
        match (reg.find(r.taskId)) {
            case Some(t) => @Assert(t.state().wire(), "killed")
            case None => @Assert("任务仍在表里", "missing")
        }
        // 已结束的任务再 kill：不是错误，只报告状态（幂等，方便模型随手清理）
        let k2 = reg.kill(r.taskId)
        @Assert(k2.ok, true)
        @Assert(k2.text.contains("已经结束"), true)
    }

    /** 超时：墙钟到点自动杀，终态是 timeout 而不是 failed */
    @TestCase
    public func testTimeout(): Unit {
        let reg = this.newRegistry("bg_timeout", 4)
        // 单任务超时覆盖为 500ms
        let r = reg.start("sleep 10", "超时任务", "", "/bin/bash", true, 500, 100)
        @Assert(r.ok, true)
        let st = this.waitTerminal(reg, r.taskId, 12000)
        @Assert(st, "timeout")
    }

    /** 未知 ID：poll/kill 都给出可诊断的报错，而不是静默 */
    @TestCase
    public func testUnknownId(): Unit {
        let reg = this.newRegistry("bg_unknown", 4)
        let p = reg.poll("bg-999", 0)
        @Assert(p.ok, false)
        @Assert(p.text.contains("未找到后台任务"), true)
        let k = reg.kill("bg-999")
        @Assert(k.ok, false)
        @Assert(k.text.contains("未找到后台任务"), true)
    }

    /**
     * 工具层端到端：三件套走 execute 公共 API（断言 observable 契约，不碰私有实现）。
     */
    @TestCase
    public func testToolsEndToEnd(): Unit {
        let reg = this.newRegistry("bg_tools", 4)
        let startTool = BashStartTool(reg)
        let pollTool = BashPollTool(reg)
        let killTool = BashKillTool(reg)
        // 三件套都必须按"写工具"分类：V2d 只并行只读工具，起进程不能并行
        @Assert(startTool.isReadOnly(), false)
        @Assert(pollTool.isReadOnly(), false)
        @Assert(killTool.isReadOnly(), false)
        @Assert(startTool.spec().name, "bash_start")
        @Assert(pollTool.spec().name, "bash_poll")
        @Assert(killTool.spec().name, "bash_kill")

        // 缺参：明确报错
        let noCmd = startTool.execute(JsonObject())
        @Assert(noCmd.isError, true)
        @Assert(noCmd.content.contains("command"), true)
        let noId = pollTool.execute(JsonObject())
        @Assert(noId.isError, true)
        @Assert(noId.content.contains("task_id"), true)

        // 正常运行：短命令在抢跑窗口内直接出结果
        var args = JsonObject()
        args.put("command", JsonString("echo tool-path-ok"))
        let started = startTool.execute(args)
        @Assert(started.isError, false)
        @Assert(started.content.contains("tool-path-ok"), true)
    }

    /**
     * 不共享会话 cwd：显式传 cwd 生效，不传则用进程 cwd。
     * 这是文档里必须正面说明的限制——测试把它钉成可执行事实。
     */
    @TestCase
    public func testCwdIsExplicitOnly(): Unit {
        let reg = this.newRegistry("bg_cwd", 4)
        let dir = testTempDir("bg_cwd_target")
        var args = JsonObject()
        args.put("command", JsonString("pwd"))
        args.put("cwd", JsonString(dir))
        let r = BashStartTool(reg).execute(args)
        @Assert(r.isError, false)
        @Assert(r.content.contains(dir), true)
    }

    /**
     * 回归（2026-11-06 界面整体卡死 100+ 秒）：后台任务在跑时不得占用共享线程池。
     *
     * 旧实现对每个任务 `spawn { readerLoop }` 阻塞读管道，2 核机器上几个任务就把
     * 线程池占满，TUI 主循环与 agent 调度一起饿死（gdb 主线程栈实测停在
     * BackgroundTask.readerLoop → ProcessInputStream.read → read(pipe)，
     * 管道另一端正是 `sleep 120`）。现在输出直接重定向落盘、零常驻线程，
     * 所以起满任务后再 spawn 一个标记任务必须立刻跑到；若还占着池子，
     * 它得排在 N 个 60s 的阻塞读后面。
     */
    @TestCase
    public func testRunningTasksDoNotStarveThreadPool(): Unit {
        let reg = this.newRegistry("bg_pool", 8)
        let hits = ArrayList<Int64>()
        let guard = Mutex()
        try {
            for (i in 0..8) {
                let r = reg.start("sleep 60", "pool-${i}", "", "/bin/bash", true, 0, 0)
                @Assert(r.ok, true)
            }
            spawn { =>
                guard.lock()
                try {
                    hits.add(1)
                } finally {
                    guard.unlock()
                }
            }
            var waited: Int64 = 0
            while (waited < 5000) {
                guard.lock()
                let done = hits.size > 0
                guard.unlock()
                if (done) {
                    break
                }
                sleep(Duration.millisecond * 20)
                waited += 20
            }
            guard.lock()
            let ran = hits.size > 0
            guard.unlock()
            @Assert(ran, true)
        } finally {
            let _ = reg.killAll()
        }
    }

    /**
     * 收割不依赖监视线程：没有常驻线程后，终态与退出码只能靠 harvestAll 轮询发现。
     * 少了它，跑完的任务会永远停在 running——面板槽位不释放、模型以为它还在跑。
     */
    @TestCase
    public func testHarvestDetectsExitAndCode(): Unit {
        let reg = this.newRegistry("bg_harvest", 4)
        let r = reg.start("sleep 0.2; exit 7", "", "", "/bin/bash", true, 0, 0)
        @Assert(r.ok, true)
        var waited: Int64 = 0
        var wire = "running"
        while (waited < 15000) {
            reg.harvestAll()
            match (reg.find(r.taskId)) {
                case Some(t) =>
                    wire = t.state().wire()
                    if (t.state().isTerminal()) {
                        @Assert(t.exitCode(), 7)
                        break
                    }
                case None =>
                    wire = "missing"
                    break
            }
            sleep(Duration.millisecond * 50)
            waited += 50
        }
        @Assert(wire, "failed")
    }
}
