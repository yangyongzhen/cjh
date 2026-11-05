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
        @Assert(panel.heartbeat(), "")
        let rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        rows.add(BgTaskRow("bg-2", "b", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        @Assert(panel.heartbeat(), "2 bg (2 running)")
        @Assert(panel.runningCount(), 2)
        let done = ArrayList<BgTaskRow>()
        done.add(BgTaskRow("bg-1", "a", BgRowSucceeded, 1000, 0, DateTime.now()))
        let _ = panel.updateRows(done)
        @Assert(panel.heartbeat(), "1 bg")
        @Assert(panel.runningCount(), 0)
    }

    @TestCase
    public func testHeight(): Unit {
        let panel = BgTaskPanel()
        // 空面板不占行
        @Assert(panel.height(20, 80), 0)
        var rows = ArrayList<BgTaskRow>()
        rows.add(BgTaskRow("bg-1", "a", BgRowRunning, 0, 0, DateTime.now()))
        let _ = panel.updateRows(rows)
        // 1 行 → 标题 + 1 行正文 + 底边 = 3
        @Assert(panel.height(20, 80), 3)
        // 窄终端不画（同 render 判据，否则会顶出空白）
        @Assert(panel.height(20, 39), 0)
        // 行数多时封顶 4
        var many = ArrayList<BgTaskRow>()
        var i = 0
        while (i < 8) {
            many.add(BgTaskRow("bg-${i}", "t${i}", BgRowRunning, 0, 0, DateTime.now()))
            i += 1
        }
        let _ = panel.updateRows(many)
        @Assert(panel.height(20, 80), 4)
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
        @Assert(text.contains("后台任务"), true)
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
}
