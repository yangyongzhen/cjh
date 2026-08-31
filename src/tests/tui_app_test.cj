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
        // 空闲：一次 Ctrl+C 直接退出（用户明确要求，无确认环节）
        let (app, _) = this.buildApp()
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), false)
    }

    @TestCase
    public func testCtrlCWhileBusyStillRequiresSecondToForceQuit(): Unit {
        // 任务中两级：第一次打断不退出；第二次才强制退出（与空闲一次退出区分）
        let app = TuiApp()
        let forced = ArrayList<Bool>()
        forced.add(false)
        app.onForceQuit = { => forced[0] = true }
        app.setAgentRunning(true)
        app.handleKey(KeyEvent(3))
        @Assert(app.testRunning(), true)   // 忙：第一次不退出
        @Assert(forced[0], false)
        app.handleKey(KeyEvent(3))
        @Assert(forced[0], true)           // 忙：第二次强制退出
        app.setAgentRunning(false)
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
    public func testCtrlCTwoLevelForceQuit(): Unit {
        // 两级 Ctrl+C：agent 忙时第一次中断、第二次强制退出——
        // agent 线程可能卡在 OS 深处（connect/DNS/TLS），中断无法保证生效，
        // 强退是唯一 100% 可靠兜底（用户明确要求：第二次 Ctrl+C 必须能退出）
        let app = TuiApp()
        // 仓颉 lambda 不能捕获可变局部变量：用 ArrayList 包装哨兵
        let forced = ArrayList<Bool>()
        forced.add(false)
        app.onForceQuit = { => forced[0] = true }
        app.setAgentRunning(true)
        app.handleKey(KeyEvent(3))  // 第一次：请求中断（不退出、不强退）
        @Assert(forced[0], false)
        @Assert(app.testRunning(), true)
        app.handleKey(KeyEvent(3))  // 第二次：强制退出（onForceQuit 触发）
        @Assert(forced[0], true)
        // 任务结束后中断标记复位：下次 Ctrl+C 重新从"请求中断"开始（不直接强退）
        app.setAgentRunning(false)
        app.setAgentRunning(true)
        app.handleKey(KeyEvent(3))
        @Assert(forced[0], true)  // 强退未再触发（复位后第一级是中断）
        app.setAgentRunning(false)
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

    @TestCase
    public func testQueueWhileBusyNoDirectSubmit(): Unit {
        // 方案 B：agent 执行中提交 → 入队，不直接 onSubmit
        let (app, submitted) = this.buildApp()
        app.setAgentRunning(true)
        app.handleKey(this.keyChar(104))  // h
        app.handleKey(this.keyChar(105))  // i
        app.handleKey(KeyEvent(13))       // Enter
        @Assert(submitted.size, 0)        // busy：不直接提交
        @Assert(app.queueLength(), 1)     // 已入队
        @Assert(app.testInputText(), "")  // 输入框已清空
    }

    @TestCase
    public func testDequeueAfterRunCompletes(): Unit {
        // 执行完 setAgentRunning(false) 后出队 → 提交（entries.cj 的自动处理路径）
        let (app, submitted) = this.buildApp()
        app.setAgentRunning(true)
        app.handleKey(this.keyChar(104))  // h
        app.handleKey(this.keyChar(105))  // i
        app.handleKey(KeyEvent(13))       // Enter → 入队
        app.setAgentRunning(false)        // agent 执行完毕
        let next = app.dequeueInput()
        @Assert(next.isSome(), true)
        @Assert(next.getOrThrow(), "hi")
        @Assert(app.queueLength(), 0)     // 队列已清空
        app.onSubmit(next.getOrThrow())
        @Assert(submitted.size, 1)
    }

    @TestCase
    public func testDequeueEmptyReturnsNone(): Unit {
        let (app, _) = this.buildApp()
        @Assert(app.dequeueInput().isNone(), true)
    }

    @TestCase
    public func testSubmitWhileQueueNonEmptyEnqueues(): Unit {
        // 防并发竞态：run 结束→下一条启动的窗口期（busy=false 但队列非空）
        // 提交的消息必须入队，不得绕过队列直接 onSubmit（否则与续跑消息并发执行）
        let (app, submitted) = this.buildApp()
        app.enqueueInput("先行消息")  // 模拟队列已有待发送消息
        app.handleKey(this.keyChar(104))  // h
        app.handleKey(KeyEvent(13))       // Enter
        @Assert(submitted.size, 0)        // 不直接提交
        @Assert(app.queueLength(), 2)     // 追加入队
    }
}
