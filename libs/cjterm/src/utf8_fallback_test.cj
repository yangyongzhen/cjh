package cjterm

import std.collection.*

/**
 * v1.3.16 Windows 框线混排修复的单元测试（回归防护）
 *
 * 根因回顾：isUtf8() 旧实现仅判 GetConsoleOutputCP()==65001，而 Windows
 * Terminal 内部恒按 UTF-8 渲染、根本不读控制台代码页（中文系统 CP 仍 936）
 * → 误判 false → logo/标题栏降级 ASCII 而 InputBox/StatusBar/TabBar/
 * TasksPanel 硬编码 UTF-8 框线 → 同屏混排。
 *
 * 修复三件套（本文件逐一锁定）：
 *   1. 现代终端环境判据 isModernTerminalEnv()（环境变量，纯函数可测）：
 *      能开 VT 的终端必按 UTF-8 渲染 → WT_SESSION/ConEmuANSI 等命中即 true
 *   2. enableRaw() 主动 SetConsoleOutputCP(65001) + disableRaw 恢复
 *      （FFI 行为，Windows 实机覆盖，此处测判据）
 *   3. 框线字符统一走 BoxChars + 各组件按 utf8 标志降级（渲染断言）
 *
 * 环境变量操控走 env_test_helper.cj 的 setEnvForTest（libc setenv）。
 */

@Test
public class BoxCharsTest {
    /** UTF-8：圆角 + 直角 + T 型连接齐全 */
    @TestCase
    public func testUtf8Chars(): Unit {
        let bx = BoxChars(true)
        @Assert(bx.tl, "╭")
        @Assert(bx.tr, "╮")
        @Assert(bx.bl, "╰")
        @Assert(bx.br, "╯")
        @Assert(bx.hc, "─")
        @Assert(bx.vc, "│")
        @Assert(bx.stl, "┌")
        @Assert(bx.str, "┐")
        @Assert(bx.sbl, "└")
        @Assert(bx.sbr, "┘")
        @Assert(bx.tTop, "┬")
        @Assert(bx.tBottom, "┴")
        @Assert(bx.tLeft, "├")
        @Assert(bx.tRight, "┤")
        @Assert(bx.tCross, "┼")
    }

    /** 非 UTF-8：全部降级 ASCII（框线混排修复的核心契约） */
    @TestCase
    public func testAsciiFallback(): Unit {
        let bx = BoxChars(false)
        @Assert(bx.tl, "+")
        @Assert(bx.tr, "+")
        @Assert(bx.bl, "+")
        @Assert(bx.br, "+")
        @Assert(bx.hc, "-")
        @Assert(bx.vc, "|")
        @Assert(bx.stl, "+")
        @Assert(bx.tTop, "+")
        @Assert(bx.tLeft, "+")
        @Assert(bx.tCross, "+")
    }
}

// setEnvForTest 依赖 POSIX setenv，Windows 构建排除本类（判据本身平台无关，
// 已在 Linux 覆盖；Windows 侧靠 enableRaw 主动切 65001 兜底）
@When[os != "Windows"]
@Test
public class ModernTerminalEnvTest {
    // 用例隔离：进入前清空所有判据环境变量（上一用例可能残留）
    private func clearEnv(): Unit {
        setEnvForTest("WT_SESSION", "")
        setEnvForTest("WT_PROFILE_ID", "")
        setEnvForTest("ConEmuANSI", "")
        setEnvForTest("ConEmuTask", "")
        setEnvForTest("CJH_FORCE_UTF8", "")
    }

    /** 无现代终端标记 → false（裸 conhost CP=936 场景的兜底判据） */
    @TestCase
    public func testPlainEnvFalse(): Unit {
        this.clearEnv()
        @Assert(isModernTerminalEnv(), false)
    }

    /** Windows Terminal：WT_SESSION 命中即 true（v1.3.7 混排根因场景） */
    @TestCase
    public func testWindowsTerminal(): Unit {
        this.clearEnv()
        setEnvForTest("WT_SESSION", "test-guid")
        @Assert(isModernTerminalEnv(), true)
        this.clearEnv()
    }

    /** WT_PROFILE_ID 单独命中也 true */
    @TestCase
    public func testWtProfileId(): Unit {
        this.clearEnv()
        setEnvForTest("WT_PROFILE_ID", "{0aff}")
        @Assert(isModernTerminalEnv(), true)
        this.clearEnv()
    }

    /** ConEmu ANSI 模式（ConEmuANSI=1）命中 */
    @TestCase
    public func testConEmu(): Unit {
        this.clearEnv()
        setEnvForTest("ConEmuANSI", "1")
        @Assert(isModernTerminalEnv(), true)
        this.clearEnv()
    }

    /** 显式强制开关 CJH_FORCE_UTF8 最高优先 */
    @TestCase
    public func testForceFlag(): Unit {
        this.clearEnv()
        setEnvForTest("CJH_FORCE_UTF8", "1")
        @Assert(isModernTerminalEnv(), true)
        this.clearEnv()
    }
}

@Test
public class ComponentUtf8FallbackTest {
    /** 剥离 ANSI（测试辅助） */
    private func stripAnsi(s: String): String {
        var sb = StringBuilder()
        var inEsc: Bool = false
        for (r in s.toRuneArray()) {
            let ch = r.toString()
            if (ch == "\u{1b}") { inEsc = true; continue }
            if (inEsc) {
                if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) { inEsc = false }
                continue
            }
            sb.append(ch)
        }
        return sb.toString()
    }

    /** 渲染单个 Component 到画布并剥离 ANSI，返回可见文本 */
    private func renderToText(component: Component, row: Int64, width: Int64, height: Int64): String {
        let canvas = TuiCanvas()
        canvas.begin(10, width, true)
        component.render(canvas, row, width, height)
        return this.stripAnsi(canvas.flush())
    }

    /** InputBox UTF-8：omp 风格 ╰─ ❯ 提示符（主路径回归） */
    @TestCase
    public func testInputBoxUtf8(): Unit {
        let box = InputBox()
        box.setUtf8(true)
        let out = this.renderToText(box, 0, 80, 1)
        @Assert(out.contains("╰─"), true)
        @Assert(out.contains("❯"), true)
    }

    /** InputBox 非 UTF-8：降级 +--（框线混排修复：不再硬编码 ╰） */
    @TestCase
    public func testInputBoxAscii(): Unit {
        let box = InputBox()
        box.setUtf8(false)
        let out = this.renderToText(box, 0, 80, 1)
        @Assert(out.contains("+--"), true)
        @Assert(out.contains("╰"), false)
    }

    /** InputBox 非 UTF-8 + 搜索模式：图标 🔍 也降级（框线混排修复） */
    @TestCase
    public func testInputBoxAsciiSearch(): Unit {
        let box = InputBox()
        box.setUtf8(false)
        box.handleKey(KeyEvent(18))  // Ctrl+R 进入搜索
        let out = this.renderToText(box, 0, 80, 1)
        @Assert(out.contains("+--"), true)
        @Assert(out.contains("🔍"), false)
        @Assert(out.contains("╰"), false)
    }

    /** InputBox 搜索模式 UTF-8：🔍 图标保留（主路径回归） */
    @TestCase
    public func testInputBoxUtf8Search(): Unit {
        let box = InputBox()
        box.setUtf8(true)
        box.handleKey(KeyEvent(18))
        let out = this.renderToText(box, 0, 80, 1)
        @Assert(out.contains("╰─"), true)
        @Assert(out.contains("🔍"), true)
    }

    /** StatusBar UTF-8：上边框 ┌─（主路径回归） */
    @TestCase
    public func testStatusBarUtf8(): Unit {
        let bar = StatusBar()
        bar.setUtf8(true)
        bar.setModel("test-model")
        bar.setStatus("Ready")
        let out = this.renderToText(bar, 0, 80, 1)
        @Assert(out.contains("┌"), true)
        @Assert(out.contains("─"), true)
    }

    /** StatusBar 非 UTF-8：上边框降级 +（框线混排修复：不再硬编码 ┌） */
    @TestCase
    public func testStatusBarAscii(): Unit {
        let bar = StatusBar()
        bar.setUtf8(false)
        bar.setModel("test-model")
        bar.setStatus("Ready")
        let out = this.renderToText(bar, 0, 80, 1)
        @Assert(out.contains("┌"), false)
        @Assert(out.contains("─"), false)
        @Assert(out.contains("+"), true)
    }

    /** TabBar UTF-8：标签分隔符 │（主路径回归） */
    @TestCase
    public func testTabBarUtf8(): Unit {
        let tab = TabBar()
        tab.setUtf8(true)
        var tabs = ArrayList<String>()
        tabs.add("对话")
        tabs.add("帮助")
        tab.setTabs(tabs)
        let out = this.renderToText(tab, 0, 80, 1)
        @Assert(out.contains("│"), true)
    }

    /** TabBar 非 UTF-8：分隔符降级 |（框线混排修复：不再硬编码 │） */
    @TestCase
    public func testTabBarAscii(): Unit {
        let tab = TabBar()
        tab.setUtf8(false)
        var tabs = ArrayList<String>()
        tabs.add("对话")
        tabs.add("帮助")
        tab.setTabs(tabs)
        let out = this.renderToText(tab, 0, 80, 1)
        @Assert(out.contains("│"), false)
        @Assert(out.contains("|"), true)
    }

    /** TasksPanel 非 UTF-8：面板边框 + 任务标记降级 ASCII（框线混排修复） */
    @TestCase
    public func testTasksPanelAscii(): Unit {
        let panel = TasksPanel()
        panel.setUtf8(false)
        var items = ArrayList<TaskSnapshot>()
        items.add(TaskSnapshot(1, "task one", TaskState.Completed))
        items.add(TaskSnapshot(2, "task two", TaskState.InProgress))
        items.add(TaskSnapshot(3, "task three", TaskState.Pending))
        panel.updateSnapshots(items)
        // cols=120：面板宽 = min(60, cols*2/5)=48（<30 不渲染，60 列不够）
        // outH=16：maxH=8 容纳 3 任务行+边框（outH/2=4 会截断第 3 行）
        // canvas 14 行：startRow=8 + 面板 5 行 = 8..12 在界内
        let canvas = TuiCanvas()
        canvas.begin(14, 120, true)
        panel.render(canvas, 8, 120, 16)
        let out = this.stripAnsi(canvas.flush())
        @Assert(out.contains("+--"), true)
        @Assert(out.contains("╭"), false)
        @Assert(out.contains("╮"), false)
        @Assert(out.contains("╰"), false)
        @Assert(out.contains("✓"), false)
        @Assert(out.contains("▶"), false)
        @Assert(out.contains("☐"), false)
    }

    /** TasksPanel UTF-8：圆角边框 + ✓/▶/☐ 标记（主路径回归） */
    @TestCase
    public func testTasksPanelUtf8(): Unit {
        let panel = TasksPanel()
        panel.setUtf8(true)
        var items = ArrayList<TaskSnapshot>()
        items.add(TaskSnapshot(1, "task one", TaskState.Completed))
        items.add(TaskSnapshot(2, "task two", TaskState.InProgress))
        items.add(TaskSnapshot(3, "task three", TaskState.Pending))
        panel.updateSnapshots(items)
        // cols=120：面板宽 = min(60, cols*2/5)=48（<30 不渲染，60 列不够）
        // outH=16：maxH=8 容纳 3 任务行+边框（outH/2=4 会截断第 3 行）
        let canvas = TuiCanvas()
        canvas.begin(12, 120, true)
        panel.render(canvas, 8, 120, 16)
        let out = this.stripAnsi(canvas.flush())
        @Assert(out.contains("╭─"), true)
        @Assert(out.contains("╮"), true)
        @Assert(out.contains("╰"), true)
        @Assert(out.contains("✓"), true)
        @Assert(out.contains("▶"), true)
        @Assert(out.contains("☐"), true)
    }
}
