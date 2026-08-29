package cjh.tests

import std.collection.*
import cjterm.*
import cjh.tui.*

/**
 * TuiApp 事件循环按键分发单元测试（此前零覆盖）
 *
 * 前提（已核实）：Term() 构造不碰终端 FFI（FFI 在 enableRaw/readKey），
 * isUtf8() 只读环境变量——TuiApp 可在无 TTY 测试环境实例化。
 * handleKey 不依赖终端渲染，仅改内部状态 + 组件分发，可直接驱动。
 *
 * 覆盖：Ctrl+C 退出、普通输入、Enter 提交回调、/命令补全、Esc 关闭、
 * 视图切换、多行编辑进出/Alt+Enter 提交、Tab 补全。
 *
 * 不测：审批弹窗（requestApproval 阻塞等待主循环，且 pendingApproval 为私有无法预设）、
 * render 渲染（TermSize.ioctl 需终端）。
 */
@Test
public class TuiAppKeyTest {

    private func buildApp(): (TuiApp, ArrayList<String>) {
        let app = TuiApp()
        let submitted = ArrayList<String>()
        app.onSubmit = { line => submitted.add(line) }
        return (app, submitted)
    }

    private func buildApp2(): (TuiApp, ArrayList<String>) {
        let app = TuiApp()
        let interrupts = ArrayList<String>()
        app.onInterrupt = { => interrupts.add("yes") }
        return (app, interrupts)
    }

    private func keyChar(c: Int32): KeyEvent {
        // 普通输入字符：ch + seq=字符（text 取 seq）
        return KeyEvent(c, Rune(c).toString())
    }

    @TestCase
    public func testCtrlCQuits(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(KeyEvent(3))   // 第一次 Ctrl+C：确认退出（不退出）
        @Assert(app.testRunning(), true)
        app.handleKey(KeyEvent(3))   // 第二次：退出
        @Assert(app.testRunning(), false)
    }

    @TestCase
    public func testCtrlCSingleConfirmsNotQuit(): Unit {
        // P0-2：空闲第一次 Ctrl+C 只提示确认，不退出（防误触丢会话）
        let (app, _) = this.buildApp()
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), true)
        // 其他按键取消退出
        app.handleKey(this.keyChar(120))  // x
        app.handleKey(KeyEvent(3))
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), false)  // 取消后需再按两次
    }

    @TestCase
    public func testCtrlCWhileBusyInterruptsNotQuit(): Unit {
        // P0-2：agent 忙时 Ctrl+C 触发中断回调，不退出 TUI
        let (app, interrupted) = this.buildApp2()
        app.setAgentRunning(true)  // 模拟 agent 执行中
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), true)      // 不退出
        @Assert(interrupted[0], "yes")        // 中断回调已触发
        app.setAgentRunning(false)
        app.handleKey(KeyEvent(3))
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), false)
    }

    @TestCase
    public func testTypeCharacters(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(104))  // h
        app.handleKey(this.keyChar(105))  // i
        @Assert(app.testInputText(), "hi")
    }

    @TestCase
    public func testBackspaceDeletes(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(97))  // a
        app.handleKey(this.keyChar(98))  // b
        app.handleKey(KeyEvent(127))     // Backspace
        @Assert(app.testInputText(), "a")
    }

    @TestCase
    public func testEnterSubmits(): Unit {
        let (app, submitted) = this.buildApp()
        app.handleKey(this.keyChar(108))   // l
        app.handleKey(this.keyChar(115))   // s
        app.handleKey(KeyEvent(13))        // Enter
        @Assert(submitted.size, 1)
        @Assert(submitted[0], "ls")
        @Assert(app.testInputText(), "")   // 提交后清空
    }

    @TestCase
    public func testEnterEmptyNotSubmitted(): Unit {
        let (app, submitted) = this.buildApp()
        app.handleKey(KeyEvent(13))  // 空输入 Enter
        @Assert(submitted.size, 0)
    }

    @TestCase
    public func testSlashCommandCandidates(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(47))  // /
        app.handleKey(this.keyChar(116)) // t
        app.handleKey(this.keyChar(104)) // h
        @Assert(app.testPickerVisible(), true)
        @Assert(app.testPickerCurrent(), "/theme")
    }

    @TestCase
    public func testEscClosesPicker(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(47))  // /
        app.handleKey(this.keyChar(116)) // t
        @Assert(app.testPickerVisible(), true)
        app.handleKey(KeyEvent(27, TermEsc.ESC))  // 裸 Esc（escapeSeq=ESC）
        @Assert(app.testPickerVisible(), false)
        @Assert(app.testRunning(), true) // 不退出
    }

    @TestCase
    public func testTabCompletesCandidate(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(47))  // /
        app.handleKey(this.keyChar(116)) // t
        app.handleKey(this.keyChar(104)) // h（/th 唯一匹配 /theme）
        app.handleKey(KeyEvent(9))       // Tab 补全
        @Assert(app.testInputText(), "/theme")
        @Assert(app.testPickerVisible(), false)
    }

    @TestCase
    public func testViewSwitchToHelp(): Unit {
        let (app, _) = this.buildApp()
        // Tab 切换视图（对话→帮助）；TabBar activeIndex 从 0 到 1（ch=9 即 Tab）
        app.handleKey(KeyEvent(9))
        @Assert(app.testViewMode(), 1)
        // Esc 回对话视图
        app.handleKey(KeyEvent(27, TermEsc.ESC))
        @Assert(app.testViewMode(), 0)
    }

    @TestCase
    public func testCtrlEEditModeToggle(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(104))  // h 到输入框
        app.handleKey(KeyEvent(5))        // Ctrl+E 进入编辑
        @Assert(app.testEditMode(), true)
        // 编辑模式：输入框内容带入编辑器
        app.handleKey(KeyEvent(5))        // Ctrl+E 再按退出
        @Assert(app.testEditMode(), false)
        @Assert(app.testInputText(), "h") // 内容回填输入框
    }

    @TestCase
    public func testAltEnterSubmitsEditor(): Unit {
        let (app, submitted) = this.buildApp()
        app.handleKey(KeyEvent(5))        // Ctrl+E 进入编辑
        // 编辑器输入字符
        app.handleKey(this.keyChar(109))  // m
        app.handleKey(this.keyChar(117))  // u
        // Alt+Enter 提交（ESC + \r 序列）
        app.handleKey(KeyEvent(27, TermEsc.ESC + "\r"))
        @Assert(submitted.size, 1)
        @Assert(submitted[0], "mu")
        @Assert(app.testEditMode(), false)
    }

    @TestCase
    public func testArrowKeysDoNotCorruptInput(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(120))  // x
        // 方向键序列不污染输入文本
        app.handleKey(KeyEvent(27, TermEsc.UP))
        app.handleKey(KeyEvent(27, TermEsc.DOWN))
        @Assert(app.testInputText(), "x")
    }

    @TestCase
    public func testQuitStopsRunning(): Unit {
        let (app, _) = this.buildApp()
        @Assert(app.testRunning(), true)
        app.quit()
        @Assert(app.testRunning(), false)
    }

    @TestCase
    public func testMouseEventIgnored(): Unit {
        let (app, _) = this.buildApp()
        app.handleKey(this.keyChar(111))  // o
        // SGR 鼠标事件（ESC[<0;10;5M）不应改变输入
        app.handleKey(KeyEvent(27, TermEsc.ESC + "[<0;10;5M"))
        @Assert(app.testInputText(), "o")
        @Assert(app.testRunning(), true)
    }
}
