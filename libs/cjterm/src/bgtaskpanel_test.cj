package cjterm

import std.collection.*
import std.time.*

/**
 * BgTaskPanel 单元测试（B-2 TUI 侧）
 *
 * 覆盖：字节/耗时格式化边界、行签名（运行中耗时不计入 → 不触发无谓重绘）、
 * updateRows 变更检测返回值、心跳文案、高度判据（空/窄终端/上限 4）、
 * 渲染内容（状态词/耗时/输出量）、多余行折 "+N more"、ASCII 降级。
 *
 * 仓颉测试坑遵守：零参 lambda、enum 无 == 运算符（断言走可见文本）、
 * 块注释内禁写星斜序列。
 */

@Test
public class BgTaskPanelTest {

    /**
     * 按行渲染：把差分输出的 ESC[r;1H 光标定位序列当作行分隔符——
     * 直接 stripAnsi 会把所有行拼成一行，行序断言全部失效（同 agentspanel_test 的教训）。
     */
    private func renderLines(panel: BgTaskPanel, cols: Int64, outH: Int64): ArrayList<String> {
        let canvas = TuiCanvas()
        canvas.begin(14, cols, true)
        let _ = panel.render(canvas, 14, cols, outH)
        let raw = canvas.flush()
        let lines = ArrayList<String>()
        var cur = StringBuilder()
        var inEsc = false
        for (r in raw.toRuneArray()) {
            let ch = r.toString()
            if (inEsc) {
                if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) {
                    inEsc = false
                    if (ch == "H") {
                        lines.add(stripAnsi(cur.toString()))
                        cur = StringBuilder()
                    }
                }
                continue
            }
            if (ch == "\u{1b}") {
                inEsc = true
                continue
            }
            cur.append(ch)
        }
        if (cur.size > 0) {
            lines.add(stripAnsi(cur.toString()))
        }
        let out = ArrayList<String>()
        for (l in lines) {
            if (l.size > 0) {
                out.add(l)
            }
        }
        return out
    }

    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc = false
        for (r in s.toRuneArray()) {
            let ch = r.toString()
            if (ch == "\u{1b}") {
                inEsc = true
                continue
            }
            if (inEsc) {
                if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) {
                    inEsc = false
                }
                continue
            }
            sb.append(ch)
        }
        return sb.toString()
    }

    private func joinLines(lines: ArrayList<String>): String {
        var sb = StringBuilder()
        for (l in lines) {
            sb.append(l)
            sb.append("\n")
        }
        return sb.toString()
    }

    // ---- 格式化纯函数 ----

    @TestCase
    public func testFmtByteSize(): Unit {
        @Assert(fmtByteSize(0), "0B")
        @Assert(fmtByteSize(1023), "1023B")
        @Assert(fmtByteSize(1024), "1.0KB")
        // 12700 * 10 / 1024 = 124 → 一位小数 12.4KB
        @Assert(fmtByteSize(12700), "12.4KB")
        @Assert(fmtByteSize(1310720), "1.2MB")
        // 负数当 0 处理：输出量理论上不会为负，但状态快照损坏时不能显示 "-1B"
        @Assert(fmtByteSize(-5), "0B")
    }

    @TestCase
    public func testFmtBgElapsed(): Unit {
        @Assert(fmtBgElapsed(0), "0s")
        @Assert(fmtBgElapsed(42000), "42s")
        // 分钟补零：宽度一致才不跳列（1m02s 而非 1m2s）
        @Assert(fmtBgElapsed(62000), "1m02s")
        @Assert(fmtBgElapsed(3720000), "1h02m")
        @Assert(fmtBgElapsed(-1), "0s")
    }

    // ---- 行签名与变更检测 ----

    @TestCase
    public func testSignatureIgnoresRunningElapsed(): Unit {
        // 运行中行的耗时由渲染实时算：进签名就等于每秒"有变化"，白重绘
        let a = ArrayList<BgTaskRow>()
        a.add(BgTaskRow("bg-1", "npm install", BgRowRunning, 1000, 512, DateTime.now()))
        let b = ArrayList<BgTaskRow>()
        b.add(BgTaskRow("bg-1", "npm install", BgRowRunning, 42000, 512, DateTime.now()))
        @Assert(bgTaskRowsSignature(a) == bgTaskRowsSignature(b), true)
        // 但输出量变化必须触发重绘
        let c = ArrayList<BgTaskRow>()
        c.add(BgTaskRow("bg-1", "npm install", BgRowRunning, 42000, 2048, DateTime.now()))
        @Assert(bgTaskRowsSignature(a) == bgTaskRowsSignature(c), false)
    }

    @TestCase
    public func testSignatureTracksTerminalState(): Unit {
        let running = ArrayList<BgTaskRow>()
        running.add(BgTaskRow("bg-1", "build", BgRowRunning, 1000, 512, DateTime.now()))
        let done = ArrayList<BgTaskRow>()
        done.add(BgTaskRow("bg-1", "build", BgRowSucceeded, 8000, 512, DateTime.now()))
        @Assert(bgTaskRowsSignature(running) == bgTaskRowsSignature(done), false)
        // 终态耗时固定，不同耗时算不同快照（面板终态列要显示真实耗时）
        let done2 = ArrayList<BgTaskRow>()
        done2.add(BgTaskRow("bg-1", "build", BgRowSucceeded, 9000, 512, DateTime.now()))
        @Assert(bgTaskRowsSignature(done) == bgTaskRowsSignature(done2), false)
    }

    @TestCase
    public func testUpdateRowsReportsChange(): Unit {
        let panel = BgTaskPanel()
        let rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "build", BgRowRunning, 0, 0, DateTime.now()))
        // 首推 true（从无到有必须重绘）
        @Assert(panel.updateRows(rows), true)
        // 同一份快照再推 false（不重绘）
        let same = ArrayList<BgTaskRow>()
        same.add(BgTaskRow("bg-1", "build", BgRowRunning, 5000, 0, DateTime.now()))
        @Assert(panel.updateRows(same), false)
        // 状态变化 true
        let changed = ArrayList<BgTaskRow>()
        changed.add(BgTaskRow("bg-1", "build", BgRowSucceeded, 8000, 0, DateTime.now()))
        @Assert(panel.updateRows(changed), true)
    }

    // ---- 心跳与高度 ----

    @TestCase
    public func testHeartbeat(): Unit {
        let panel = BgTaskPanel()
        // 无任务：状态行不挂尾巴
        @Assert(panel.heartbeat(), "")
        let _ = panel.setSlots(BgSlots(0, 8, 0, 4))
        let rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        rows.add(BgTaskRow("bg-2", "b", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 面板已无标题：槽位账 + 各状态真实计数全落在状态行心跳里
        @Assert(panel.heartbeat(), "bg 0/8  agents 0/4  2 running")
        @Assert(panel.runningCount(), 2)
        let done = ArrayList<BgTaskRow>()
        done.add(BgTaskRow("bg-1", "a", BgRowSucceeded, 1000, 0, DateTime.now()))
        let _ = panel.updateRows(done)
        // 终态必须报具体状态，不能笼统写 done（killed/failed 不是 done）
        @Assert(panel.heartbeat(), "bg 0/8  agents 0/4  1 succeeded")
        @Assert(panel.runningCount(), 0)
    }

    /**
     * 心跳只数"非终态"：终态与运行中混在一起时，括号里必须只出运行中的那个数
     *
     * 这是状态行降级显示的边界——面板不渲染（窄终端/高度不足）时，用户只能看到
     * 这句话，把终态也算进 running 会让人以为还有活没干完。
     */
    @TestCase
    public func testHeartbeatSeparatesTerminalStates(): Unit {
        let panel = BgTaskPanel()
        let _ = panel.setSlots(BgSlots(0, 8, 0, 4))
        let rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowSucceeded, 1000, 0, DateTime.now()))
        rows.add(BgTaskRow("bg-2", "b", BgRowRunning, 0, 0, DateTime.now()))
        rows.add(BgTaskRow("bg-3", "c", BgRowFailed, 2000, 1, DateTime.now()))
        rows.add(BgTaskRow("bg-4", "d", BgRowKilled, 4000, 2, DateTime.now()))
        rows.add(BgTaskRow("bg-5", "e", BgRowTimeout, 5000, 3, DateTime.now()))
        let _ = panel.updateRows(rows)
        // killed / failed / timeout 各有其名：笼统算 done 会让人以为任务"完成了"
        // （实测投诉：被 kill 的 bg-1 显示成 "1 done"）
        @Assert(panel.heartbeat(),
            "bg 0/8  agents 0/4  1 running  1 failed  1 killed  1 timeout  1 succeeded")
        @Assert(panel.runningCount(), 1)
    }

    @TestCase
    public func testFmtBgStateSummary(): Unit {
        // 只列非零项，顺序 running → failed → killed → timeout → succeeded
        @Assert(fmtBgStateSummary(0, 0, 0, 0, 1), "1 killed")
        @Assert(fmtBgStateSummary(2, 3, 1, 0, 0), "2 running  1 failed  3 succeeded")
        @Assert(fmtBgStateSummary(0, 0, 0, 0, 0), "")
    }

    @TestCase
    public func testHeight(): Unit {
        let panel = BgTaskPanel()
        // 空面板不占行
        @Assert(panel.height(20, 80), 0)
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 1 行任务 = 1 行紧凑条（无边框/无标题，不再 +2）
        @Assert(panel.height(20, 80), 1)
        // 窄终端不画（同 render 判据，否则会顶出空白）
        @Assert(panel.height(20, 39), 0)
        // 行数多时封顶 2（超过的第二行让位给 "+N more"）
        var many = ArrayList<BgTaskRow>()
        var i = 0
        while (i < 8) {
            many.add(BgTaskRow("bg-${i}", "t${i}", BgRowRunning, 0, 0, DateTime.now()))
            i += 1
        }
        let _ = panel.updateRows(many)
        @Assert(panel.height(20, 80), 2)
        // 可用高度极小时按 outH/3 收缩
        @Assert(panel.height(3, 80), 1)
    }

    // ---- 渲染 ----

    @TestCase
    public func testRenderShowsRowsAndStateWords(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(true)
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "npm install", BgRowRunning, 0, 12700, DateTime.now()))
        rows.add(BgTaskRow("bg-2", "cargo build", BgRowSucceeded, 8000, 2048, DateTime.now()))
        let _ = panel.updateRows(rows)
        let text = this.joinLines(this.renderLines(panel, 100, 20))
        // 紧凑条：不画边框与标题框（用户反馈"大框压在 todo 上面"）
        @Assert(text.contains("后台任务"), false)
        @Assert(text.contains("╭"), false)
        @Assert(text.contains("╰"), false)
        @Assert(text.contains("│"), false)
        @Assert(text.contains("bg-1"), true)
        @Assert(text.contains("npm install"), true)
        @Assert(text.contains("running"), true)
        @Assert(text.contains("12.4KB"), true)
        @Assert(text.contains("bg-2"), true)
        @Assert(text.contains("succeeded"), true)
        @Assert(text.contains("8s"), true)
        @Assert(text.contains("2.0KB"), true)
    }

    @TestCase
    public func testRenderRunningElapsedIsLive(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(true)
        var rows = ArrayList<BgTaskRow>()
        // 起始时刻 = 现在 → 实时耗时约 0s（快照里的 999s 属终态值，不该被运行中行采用）
        rows.add(BgTaskRow("bg-1", "sleep", BgRowRunning, 999000, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        let text = this.joinLines(this.renderLines(panel, 100, 20))
        @Assert(text.contains("0s"), true)
        @Assert(text.contains("999s"), false)
    }

    @TestCase
    public func testRenderFoldsExtraRows(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(true)
        var rows = ArrayList<BgTaskRow>()
        var i = 0
        while (i < 6) {
            rows.add(BgTaskRow("bg-${i}", "t${i}", BgRowRunning, 0, 0, DateTime.now()))
            i += 1
        }
        let _ = panel.updateRows(rows)
        let text = this.joinLines(this.renderLines(panel, 100, 20))
        // 正文 2 行：显示 1 行后第 2 行让位给 "+N more"（6 - 1 = 5 行未显示）
        @Assert(text.contains("+5 more"), true)
        @Assert(text.contains("bg-0"), true)
        @Assert(text.contains("bg-5"), false)
    }

    @TestCase
    public func testRenderAsciiFallback(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(false)
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        let text = this.joinLines(this.renderLines(panel, 100, 20))
        // ASCII 降级：不出现 unicode 标记与框线（历史上反复修的混排问题）
        @Assert(text.contains(">"), true)
        @Assert(text.contains("▶"), false)
        @Assert(text.contains("╭"), false)
    }

    @TestCase
    public func testRenderEmptyAndNarrow(): Unit {
        let panel = BgTaskPanel()
        @Assert(panel.render(TuiCanvas(), 14, 100, 20), 0)
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 窄终端不渲染（与 height 同判据）
        @Assert(panel.render(TuiCanvas(), 14, 39, 20), 0)
    }

    // ---- 两本槽位账（B-3 收敛版：账可见，Agents 面板与焦点交互不动）----

    @TestCase
    public func testFmtSlotLedger(): Unit {
        @Assert(fmtSlotLedger(3, 8, 2, 4), "bg 3/8  agents 2/4")
        // 上限 <= 0 = 不限（settings 四键 0 的语义）：只写用量
        @Assert(fmtSlotLedger(3, 0, 2, 0), "bg 3  agents 2")
        // 子代理未启用（上限 0 且用量 0）：整段省略，不留恒为 0 的尾巴
        @Assert(fmtSlotLedger(1, 8, 0, 0), "bg 1/8")
        @Assert(fmtSlotLedger(0, 8, 0, 4), "bg 0/8  agents 0/4")
    }

    @TestCase
    public func testFmtAgentLedger(): Unit {
        // 回合总结条用："N/4 agents (x✓ y✗)"——上限可见才知道 4 是天花板
        @Assert(fmtAgentLedger(3, 4), "3/4 agents")
        // 上限 <= 0 = 不限：只写用量
        @Assert(fmtAgentLedger(3, 0), "3 agents")
        @Assert(fmtAgentLedger(2, -1), "2 agents")
    }

    @TestCase
    public func testSetSlotsChangeDetection(): Unit {
        let panel = BgTaskPanel()
        // 首次推送必算变化（否则首帧标题不会带上账）
        @Assert(panel.setSlots(BgSlots(1, 8, 0, 4)), true)
        // 同值不触发重绘：槽位是低频量，重复 markDirty 就是无谓的全屏重绘
        @Assert(panel.setSlots(BgSlots(1, 8, 0, 4)), false)
        @Assert(panel.setSlots(BgSlots(1, 8, 1, 4)), true)
        @Assert(panel.currentSlots().agentsUsed, 1)
    }

    @TestCase
    public func testHeartbeatShowsSlotLedger(): Unit {
        let panel = BgTaskPanel()
        let _ = panel.setSlots(BgSlots(1, 8, 2, 4))
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "npm install", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 碰撞场景的关键信息：是哪一本账满了（上限来自两个不同配置键）
        // 面板无标题后，账与计数只在状态行心跳里可见
        let hb = panel.heartbeat()
        @Assert(hb.contains("bg 1/8"), true)
        @Assert(hb.contains("agents 2/4"), true)
        @Assert(hb.contains("1 running"), true)
    }

    /** 40 列（面板渲染下限）仍是紧凑条：窄终端降级只在 <40，见 height/render 判据 */
    @TestCase
    public func testRenderAt40ColsStillCompact(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(true)
        let _ = panel.setSlots(BgSlots(1, 8, 2, 4))
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        let text = this.joinLines(this.renderLines(panel, 40, 20))
        @Assert(text.contains("bg-1"), true)
        @Assert(text.contains("╭"), false)
    }

    /**
     * 全终态 + 到点 → 自动收起
     *
     * 收起必须同时让 height() 归零：只让 render 不画而 height 仍占位，
     * 就是底部留一块洗不掉的空白（S3 复核 #9 同款坑）。
     */
    @TestCase
    public func testFadeCollapsesAfterAllTerminal(): Unit {
        let panel = BgTaskPanel()
        panel.setUtf8(true)
        let _ = panel.setSlots(BgSlots(0, 8, 0, 4))
        // 固定时钟：不依赖真实时间，断言才有确定性
        panel.setClock({ => 1000 })
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "done-1", BgRowSucceeded, 3000, 10, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 回看窗口内照常显示
        @Assert(panel.tick(1005), false)
        @Assert(panel.shouldShow(), true)
        @Assert(panel.height(20, 100) > 0, true)
        @Assert(panel.heartbeat(), "bg 0/8  agents 0/4  1 succeeded")
        // 到点：收起，高度归零，心跳不再挂尾巴
        @Assert(panel.tick(1008), true)
        @Assert(panel.shouldShow(), false)
        @Assert(panel.height(20, 100), 0)
        @Assert(panel.heartbeat(), "")
        // 幂等：已收起再 tick 不重复报变化（否则每秒白重绘一次）
        @Assert(panel.tick(1009), false)
        // 收起后不必再空转
        @Assert(panel.needsTick(), false)
    }

    /** 收起后被新任务打回可见：不能让"已淡出"吃掉新起的任务 */
    @TestCase
    public func testFadeResetsWhenNewTaskStarts(): Unit {
        let panel = BgTaskPanel()
        panel.setClock({ => 1000 })
        let _ = panel.setSlots(BgSlots(0, 8, 0, 4))
        var done = ArrayList<BgTaskRow>()
        done.add(BgTaskRow("bg-1", "old", BgRowSucceeded, 1000, 0, DateTime.now()))
        let _ = panel.updateRows(done)
        @Assert(panel.tick(1008), true)
        @Assert(panel.shouldShow(), false)
        var live = ArrayList<BgTaskRow>()
        live.add(BgTaskRow("bg-1", "old", BgRowSucceeded, 1000, 0, DateTime.now()))
        live.add(BgTaskRow("bg-2", "new", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(live)
        @Assert(panel.shouldShow(), true)
        @Assert(panel.height(20, 100) > 0, true)
        @Assert(panel.heartbeat(), "bg 0/8  agents 0/4  1 running  1 succeeded")
    }

    /** 运行中的任务永不收起：等到天荒地老也得看得见 */
    @TestCase
    public func testFadeNeverCollapsesWhileRunning(): Unit {
        let panel = BgTaskPanel()
        panel.setClock({ => 1000 })
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "long", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        @Assert(panel.tick(1000 + 100000), false)
        @Assert(panel.shouldShow(), true)
        @Assert(panel.needsTick(), true)
    }

    /** 表被清空后收起状态复位；fadeAfterSecs <= 0 表示永不自动收起 */
    @TestCase
    public func testFadeResetAndDisabled(): Unit {
        let panel = BgTaskPanel()
        panel.setClock({ => 1000 })
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "x", BgRowKilled, 500, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        @Assert(panel.tick(1009), true)
        @Assert(panel.shouldShow(), false)
        // 空表：本来就不显示，且不必再驱动
        let _ = panel.updateRows(ArrayList<BgTaskRow>())
        @Assert(panel.shouldShow(), false)
        @Assert(panel.needsTick(), false)
        var again = ArrayList<BgTaskRow>()
        again.add(BgTaskRow("bg-2", "y", BgRowSucceeded, 100, 0, DateTime.now()))
        let _ = panel.updateRows(again)
        @Assert(panel.shouldShow(), true)
        // 关掉自动收起：终态行常驻（需要长期回看时的配置）
        panel.fadeAfterSecs = 0
        @Assert(panel.tick(1000 + 100000), false)
        @Assert(panel.shouldShow(), true)
    }
}
