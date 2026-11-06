package cjh.tests

import std.collection.*
import std.sync.*
import std.time.*
import cjterm.*
import cjh.tui.*
import cjh.agent.*

/**
 * TuiApp 事件循环按键分发单元测试（此前零覆盖）
 *
 * 前提（已核实）：Term() 构造不碰终端 FFI（FFI 在 enableRaw/readKey），
 * isUtf8() 只读环境变量——TuiApp 可在无 TTY 测试环境实例化。
 * handleKey 不依赖终端渲染，仅改内部状态 + 组件分发，可直接驱动。
 *
 * 覆盖：Ctrl+C 退出、普通输入、Enter 提交回调、/命令补全、Esc 关闭、
 * 视图切换、多行编辑进出/Alt+Enter 提交、Tab 补全、
 * 审批队列化（S1：并发请求排队、y 只批队首、Ctrl+C 整体拒绝）。
 *
 * 不测：render 渲染（TermSize.ioctl 需终端）。
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

    /** 轮询等待条件成立（最多 ~1s），供 agent 线程排队/弹窗就绪 */
    private func waitFor(cond: () -> Bool): Bool {
        var i: Int64 = 0
        while (i < 200) {
            if (cond()) { return true }
            sleep(Duration.millisecond * 5)
            i += 1
        }
        return false
    }

    @TestCase
    public func testApprovalQueueConcurrentYApprovesHeadOnly(): Unit {
        // S1：两路并发审批排队；y 只批队首，第二路仍阻塞且标题推进 审批(2/2)
        let app = TuiApp()
        // 仓颉 lambda 不能捕获可变局部变量：用 ArrayList 包装结果哨兵
        let results = ArrayList<Bool>()
        results.add(false)
        results.add(false)
        let t1 = spawn {
            results[0] = app.requestApproval("第一个危险操作")
        }
        @Assert(this.waitFor({ => app.testApprovalVisible() }), true)
        let t2 = spawn {
            results[1] = app.requestApproval("第二个危险操作")
        }
        @Assert(this.waitFor({ => app.testApprovalQueueSize() == 2 }), true)
        // 入队与弹窗标题刷新跨锁两步：轮询等标题推进，避免 add 与 show 之间的窗口
        @Assert(this.waitFor({ => app.testApprovalTitle() == "审批 (1/2)" }), true)
        app.handleKey(this.keyChar(121))  // y：只批队首
        let _ = t1.get()  // lambda 为 Unit（赋值表达式），直接断言结果哨兵
        @Assert(results[0], true)
        @Assert(app.testApprovalQueueSize(), 1)   // 第二路仍在排队
        @Assert(app.testApprovalVisible(), true)
        @Assert(app.testApprovalTitle(), "审批 (2/2)")
        app.handleKey(this.keyChar(110))  // n：拒绝第二路
        let _ = t2.get()
        @Assert(results[1], false)
        @Assert(app.testApprovalVisible(), false)
    }

    @TestCase
    public func testApprovalQueueCtrlCDeniesAll(): Unit {
        // S1：审批等待中 Ctrl+C → 整体拒绝（两路都解除阻塞且为 false），不退出不中断
        let app = TuiApp()
        let results = ArrayList<Bool>()
        results.add(false)
        results.add(false)
        let t1 = spawn {
            results[0] = app.requestApproval("第一个危险操作")
        }
        @Assert(this.waitFor({ => app.testApprovalVisible() }), true)
        let t2 = spawn {
            results[1] = app.requestApproval("第二个危险操作")
        }
        @Assert(this.waitFor({ => app.testApprovalQueueSize() == 2 }), true)
        app.handleKey(KeyEvent(3))  // Ctrl+C：整体拒绝
        let _ = t1.get()
        let _ = t2.get()
        @Assert(results[0], false)  // 复核 D：两路都必须拿到 false（解除阻塞且未越权放行）
        @Assert(results[1], false)
        @Assert(app.testRunning(), true)          // 不退出
        @Assert(app.testApprovalQueueSize(), 0)   // 队列清空
        @Assert(app.testApprovalVisible(), false)
    }

    @TestCase
    public func testFocusCycleRefreshAgents(): Unit {
        // S3d：Ctrl+G 焦点循环 父(0) → 子1 → 子2 → 父；无子代理时循环回父
        let app = TuiApp()
        @Assert(app.currentFocusAgentId(), 0)
        app.cycleFocus()  // 无子代理：仍回父
        @Assert(app.currentFocusAgentId(), 0)
        var nodes = ArrayList<AgentNode>()
        nodes.add(AgentNode(101, 1, "任务A", "explore"))
        nodes.add(AgentNode(102, 1, "任务B", "worker"))
        app.refreshAgents(nodes)
        app.cycleFocus()  // 0 → 101
        @Assert(app.currentFocusAgentId(), 101)
        app.cycleFocus()  // 101 → 102
        @Assert(app.currentFocusAgentId(), 102)
        app.cycleFocus()  // 102 → 0
        @Assert(app.currentFocusAgentId(), 0)
    }

    @TestCase
    public func testApprovalQueueCarriesLabels(): Unit {
        // S3e G-B：审批队列项带 agent 身份（label 与队列平行；父自身审批为空串）
        let app = TuiApp()
        let results = ArrayList<Bool>()
        results.add(false)
        let t1 = spawn {
            results[0] = app.requestApproval("子代理危险操作", "并发审批一号")
        }
        @Assert(this.waitFor({ => app.testApprovalVisible() }), true)
        let labels = app.testApprovalLabels()
        @Assert(labels.size, 1)
        @Assert(labels[0], "并发审批一号")
        app.handleKey(KeyEvent(3))  // Ctrl+C：整体拒绝，解除阻塞
        let _ = t1.get()
        @Assert(results[0], false)
        @Assert(app.testApprovalLabels().size, 0)  // 清队同步清 labels
    }

    @TestCase
    public func testApprovalTimeoutDenies(): Unit {
        // G-A：审批超时=拒绝 + 自愈摘队（用户离开终端时父回合不永久卡死）
        let app = TuiApp()
        app.approvalTimeoutMs = 60
        let results = ArrayList<Bool>()
        results.add(false)
        let t1 = spawn {
            results[0] = app.requestApproval("超时审批")
        }
        @Assert(this.waitFor({ => app.testApprovalVisible() }), true)
        // 到点自愈摘队（60ms 上限，waitFor 最长 1s 足够）
        @Assert(this.waitFor({ => app.testApprovalQueueSize() == 0 }), true)
        let _ = t1.get()
        @Assert(results[0], false)                 // 超时=拒绝
        @Assert(app.testApprovalVisible(), false)  // 弹窗收起
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
        // agent 执行中提交 → 入队，不直接 onSubmit、不打断当前回合，也不在
        // 回合内注入（v1.6.9：旧 steer 注入会打乱当前回合任务语义，
        // 连发两条时先发的任务被吞；现改为回合结束后作新回合发送）
        let app = TuiApp()
        let submitted = ArrayList<String>()
        let interrupts = ArrayList<String>()
        app.onSubmit = { line => submitted.add(line) }
        app.onInterrupt = { => interrupts.add("yes") }
        app.setAgentRunning(true)
        app.handleKey(this.keyChar(104))  // h
        app.handleKey(this.keyChar(105))  // i
        app.handleKey(KeyEvent(13))       // Enter
        @Assert(submitted.size, 0)        // busy：不直接提交
        @Assert(interrupts.size, 0)       // 不打断当前回合
        @Assert(app.queueLength(), 1)     // 已入队
        @Assert(app.testInputText(), "")  // 输入框已清空
        app.setAgentRunning(false)
    }

    @TestCase
    public func testQueuedMessagesDequeueInFifoOrder(): Unit {
        // 忙时连发两条（用户实测场景）→ 都留在队列里，回合结束后按 FIFO
        // 逐条出队，各自作新回合发送（不合并、不乱序）
        let (app, submitted) = this.buildApp()
        app.setAgentRunning(true)
        app.handleKey(this.keyChar(97))   // a
        app.handleKey(KeyEvent(13))       // Enter → 入队 "a"
        app.handleKey(this.keyChar(98))   // b
        app.handleKey(KeyEvent(13))       // Enter → 入队 "b"
        @Assert(submitted.size, 0)        // 忙时均不直接提交
        @Assert(app.queueLength(), 2)
        app.setAgentRunning(false)        // 回合结束
        let first = app.dequeueInput()
        @Assert(first.isSome(), true)
        @Assert(first.getOrThrow(), "a")  // FIFO：先入先出
        let second = app.dequeueInput()
        @Assert(second.isSome(), true)
        @Assert(second.getOrThrow(), "b")
        @Assert(app.queueLength(), 0)
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

    // ==================== 忙时入队 + Esc = 中断并立即发送 ====================
    // 忙时 Enter 只入队：不打断当前回合、也不在回合内注入（见
    // testQueueWhileBusyNoDirectSubmit）；当前回合作答完毕后由 entries.cj 出队
    // 作新回合发送。想夺回输入权：Esc（中断当前回合，剩余队列等 run 结束后
    // 作为新 turn 自动发送）或 Ctrl+C 两级中断。

    @TestCase
    public func testEscWhileBusyInterruptsAndKeepsQueue(): Unit {
        // 忙时裸 Esc = 中断当前回合（onInterrupt 触发），不退出 TUI，
        // 已入队消息保留（run 结束后由 entries.cj 作为新 turn 发送）
        let app = TuiApp()
        let interrupts = ArrayList<String>()
        app.onInterrupt = { => interrupts.add("yes") }
        app.setAgentRunning(true)
        app.enqueueInput("排队消息")  // 模拟之前 Enter 已入队
        app.handleKey(KeyEvent(27, TermEsc.ESC))  // 干净对话视图（无 picker/帮助/编辑）
        @Assert(interrupts.size, 1)    // 中断已触发
        @Assert(app.testRunning(), true)  // 不退出 TUI
        @Assert(app.queueLength(), 1)  // 队列保留（中断后作为新 turn 发送）
        app.setAgentRunning(false)
    }

    @TestCase
    public func testEscIdleDoesNotInterrupt(): Unit {
        // 空闲时裸 Esc 不触发中断（仅关闭下拉框/帮助视图/编辑模式——
        // 无可见组件时直接返回）：避免空闲误按 Esc 误触中断回调
        let app = TuiApp()
        let interrupts = ArrayList<String>()
        app.onInterrupt = { => interrupts.add("yes") }
        app.handleKey(KeyEvent(27, TermEsc.ESC))  // 空闲 + 干净对话视图
        @Assert(interrupts.size, 0)
        @Assert(app.testRunning(), true)
    }

    // ==================== 空闲看门狗误杀回归（"连续几轮会话总被打断"） ====================
    // 根因：agentLastActivity 只被 onDelta/onReasoning 更新、跨 run 不重置。
    // 上一 run 结束后锚点停在旧帧，新 run 启动后"建连+前思考期"（推理模型大
    // prompt 数十秒~分钟无首帧）从陈旧锚点累计超 idleTimeoutSecs → 看门狗把
    // 正在思考的模型当停滞杀掉（实测提交后 6s 即报"idle 61s"并打断）。

    @TestCase
    public func testSetAgentRunningTrueResetsIdleAnchor(): Unit {
        // 模拟：上一 run 已结束，锚点已陈旧（制造 300ms 的"空闲"）
        let (app, _) = this.buildApp()
        sleep(Duration.millisecond * 300)
        let staleIdle = app.testAgentIdleMs()
        @Assert(staleIdle >= 200)  // 前置：锚点应已陈旧（≥200ms）
        // 新 run 启动：setAgentRunning(true) 必须重置锚点，空闲回到 ~0
        app.setAgentRunning(true)
        let freshIdle = app.testAgentIdleMs()
        @Assert(freshIdle < 50)  // 启动新 run 后空闲应≈0（锚点已重置）
        app.setAgentRunning(false)
    }

    @TestCase
    public func testMarkAgentActivityResetsIdleAnchor(): Unit {
        // onDelta/onReasoning 回调路径（entries.cj 每帧调用）应刷新锚点
        let (app, _) = this.buildApp()
        sleep(Duration.millisecond * 300)
        @Assert(app.testAgentIdleMs() >= 200)  // 前置：锚点应已陈旧
        app.markAgentActivity()
        @Assert(app.testAgentIdleMs() < 50)  // 标记活动后空闲应≈0
    }

    @TestCase
    public func testResetAgentTokensClearsStaleEstimate(): Unit {
        // 跨轮 token 残留回归：上一轮估算（setAgentTokenEstimate 只增不减）
        // 应被新一轮 onThinking→resetAgentTokens 清零，而非残留到状态条
        let (app, _) = this.buildApp()
        app.setAgentTokenEstimate(500)      // 模拟上一轮残留估算
        @Assert(app.testAgentPromptTokens(), 500)
        app.resetAgentTokens()              // 新一轮 onThinking 触发
        @Assert(app.testAgentPromptTokens(), 0)  // 新一轮应清零残留估算
        // 清零后本轮估算正常增长（只增不减语义在本轮内仍成立）
        app.setAgentTokenEstimate(120)
        @Assert(app.testAgentPromptTokens(), 120)
        app.setAgentTokenEstimate(80)       // 小于当前值：不回落
        @Assert(app.testAgentPromptTokens(), 120)
    }
}

/**
 * 思考历史（多轮保留）TuiApp 层回归测试
 *
 * 旧行为：appendReasoning 在"上一轮已结束"时清空上一轮缓冲，历史无从回看；
 * clearReasoning 只把当前轮标记结束。新行为：逐轮累积到 OutputView 的
 * 多轮思考历史，clearReasoning 仅结束当前轮。
 */
@Test
public class TuiAppReasoningHistoryTest {

    @TestCase
    public func testRoundsAccumulateAcrossContent(): Unit {
        let app = TuiApp()
        app.appendReasoning("第一轮思考")
        @Assert(app.testThinkingRounds(), 1)
        @Assert(app.testThinkingActive(), true)
        app.clearReasoning()                    // 正式 content 开始 → 本轮结束
        @Assert(app.testThinkingActive(), false)
        @Assert(app.testThinkingRounds(), 1)
        app.appendReasoning("第二轮思考")        // 旧实现会在此清空上一轮
        @Assert(app.testThinkingRounds(), 2)
        @Assert(app.testThinkingActive(), true)
        app.clearReasoning()
        @Assert(app.testThinkingRounds(), 2)
        @Assert(app.testThinkingActive(), false)
    }

    @TestCase
    public func testSameRoundAppendsKeepOneRound(): Unit {
        let app = TuiApp()
        app.appendReasoning("增量一")
        app.appendReasoning("增量二")
        @Assert(app.testThinkingRounds(), 1)
        app.clearReasoning()
        app.clearReasoning()                    // 幂等：重复结束不产生新轮
        @Assert(app.testThinkingRounds(), 1)
        @Assert(app.testThinkingActive(), false)
    }

    @TestCase
    public func testEmptyAppendIgnored(): Unit {
        let app = TuiApp()
        app.appendReasoning("")
        @Assert(app.testThinkingRounds(), 0)
        app.clearReasoning()                    // 无轮次时结束为无操作
        @Assert(app.testThinkingRounds(), 0)
        @Assert(app.testThinkingActive(), false)
    }
}

/**
 * 空闲看门狗判据（纯函数）：模型停滞 vs 工具在跑，必须分开。
 *
 * 回归 2026-11-06 15:52 事故：`▶ bash`/`▶ glob` 两个工具开始执行后 181s 无返回，
 * 界面打出"⚠ 模型 181s 无响应（可能停滞），已请求中断"，而请求的中断打不断正在
 * 执行的工具——日志在 15:55:09 之后空白，回合从未结束。等待工具不等于模型停滞。
 */
@Test
public class WatchdogDecisionTest {

    // 枚举不能 ==（仓颉约束），用 match 取名比较
    private func actionName(a: WatchdogAction): String {
        match (a) {
            case WatchdogAction.Cool => return "Cool"
            case WatchdogAction.InterruptModel => return "InterruptModel"
            case WatchdogAction.ToolBusy => return "ToolBusy"
        }
    }

    @TestCase
    public func testIdleUnderThresholdIsCool(): Unit {
        @Assert(this.actionName(watchdogAction(30, 180, 0)), "Cool")
    }

    @TestCase
    public func testModelStallInterrupts(): Unit {
        // 无工具在跑、锚点超阈值 ⇒ 模型确实没吐帧，请求中断（流式读可被 abort）
        @Assert(this.actionName(watchdogAction(181, 180, 0)), "InterruptModel")
    }

    @TestCase
    public func testToolInFlightIsNotModelStall(): Unit {
        // 工具在跑：不甩锅给模型，也不请求一个打不断工具的中断
        @Assert(this.actionName(watchdogAction(181, 180, 1)), "ToolBusy")
        // 多个工具并发同样成立
        @Assert(this.actionName(watchdogAction(400, 180, 3)), "ToolBusy")
    }

    @TestCase
    public func testToolInFlightUnderThresholdIsCool(): Unit {
        // 阈值内一律不动作（工具刚起跑属于正常）
        @Assert(this.actionName(watchdogAction(5, 180, 2)), "Cool")
    }

    @TestCase
    public func testToolFinishRedirectsBlameBack(): Unit {
        // 工具全部结束后回到模型语义：仍在静默 ⇒ 该中断模型
        @Assert(this.actionName(watchdogAction(200, 180, 0)), "InterruptModel")
    }
}

/**
 * 输出区底沿（outputAreaBottom）：底部几行是公共资源，谁在最下面谁可见。
 *
 * 布局从上到下：输出区 → 面板带（Tasks 左 / Agents 右 / bg 全宽，占
 * `statusRow-1-panelsH .. statusRow-2`）→ 状态栏(statusRow)。
 * `TuiApp.render` 先画输出区、**后**画面板，所以输出区一旦铺到面板带底下，
 * 最后 panelsH 行就被面板盖掉。而那正是最新输出：滚动 offset=0 时窗口底沿
 * 就是视口底沿，PageDown 也救不回来（offset 已为 0，再按被钳住）。
 *
 * 实测 2026-11-06 16:30：用户任务跑完只看到任务单，回合收尾那几行看不见，
 * 连按 94 次 PageDown 无反应（日志里 PG6×94 全在回合结束之后）。
 */
@Test
public class OutputAreaBottomTest {

    @TestCase
    public func testNoPanelsUsesRowAboveStatusBar(): Unit {
        // 无面板：输出区照旧铺到状态栏上一行
        @Assert(outputAreaBottom(40, false, -1, 0, 0), 39)
    }

    @TestCase
    public func testIdleWithPanelsStopsAbovePanelBand(): Unit {
        // panelsH=5 ⇒ 面板带 34..38，输出区底沿必须是 33（不得伸进面板带）
        @Assert(outputAreaBottom(40, false, -1, 5, 0), 33)
    }

    @TestCase
    public func testOutputBottomNeverInsidePanelBand(): Unit {
        // 不变式：任意面板高度（含 bg 面板）下，底沿都落在面板带上沿之上
        for (panelsH in 1..9) {
            for (bgH in 0..2) {
                let bottom = outputAreaBottom(40, false, -1, panelsH, bgH)
                let bandTop = 40 - 1 - panelsH - bgH
                @Assert(bottom < bandTop)
            }
        }
    }

    @TestCase
    public func testBusyLayoutUnchanged(): Unit {
        // 执行中：动态状态行上方（agentRow 已扣面板带），无 bg 面板时不变
        @Assert(outputAreaBottom(40, true, 33, 5, 0), 32)
    }

    @TestCase
    public func testBusyTooShallowFallsBackToIdleRule(): Unit {
        // 空间太浅（agentRow < 8）走空闲分支——同样不得伸进面板带
        @Assert(outputAreaBottom(40, true, 6, 3, 0), 40 - 2 - 3)
    }

    @TestCase
    public func testBusyStopsAboveBgPanel(): Unit {
        // 执行中 bg 面板画在状态行**上方**：输出区底沿还要再让出 bgH 行
        @Assert(outputAreaBottom(40, true, 33, 5, 2), 30)
    }

    @TestCase
    public func testBgHeightOnlyShiftsOutputNotStateRow(): Unit {
        // 状态行位置固定（agentRow 不再含 bgH），bgH 0→2 只让输出区底沿缩 2 行。
        // 旧布局把 bgH 计入 agentRow：面板一出现状态行上移 2 行、淡出又下移，
        // 用户实测"状态行时上时下"。
        @Assert(outputAreaBottom(40, true, 33, 5, 0), 32)
        @Assert(outputAreaBottom(40, true, 33, 5, 2), 30)
    }
}

/**
 * 每秒节拍判据（secondElapsed）：心跳计时与后台面板淡出必须共用**同一个**锚点、
 * 且**只判一次**秒。
 *
 * 回归背景（2026-11-06 用户实测）：TuiApp 主循环里心跳分支先 `lastTick = now`，
 * 紧接着后台面板分支又拿同一个 lastTick 判 `(nowBg - lastTick).toSeconds() >= 1`，
 * 恒得 0 秒 ⇒ `bgPanel.tick()` 一次都不执行 ⇒ 终态任务永不淡出、面板一直挂着
 * 已结束任务（现象："已结束的后台任务槽位没有自动释放"）。用户连发三次
 * bash_start（三次完整回合、agent 全程忙）时 100% 复现。
 */
@Test
public class SecondTickTest {

    @TestCase
    public func testSameSecondNotDue(): Unit {
        // 同一秒内不重复驱动（否则每帧都 tick，白重绘）
        @Assert(!secondElapsed(100, 100))
    }

    @TestCase
    public func testOneSecondDue(): Unit {
        @Assert(secondElapsed(101, 100))
        @Assert(secondElapsed(160, 100))
    }

    @TestCase
    public func testSharedAnchorDropsSecondDriver(): Unit {
        // 旧 bug 的形状：心跳先判秒并推进锚点，面板紧接着用同一锚点判 → 不到点。
        // 这正是"面板 tick 永不执行"的机制，锁住它防止再退回共享锚点。
        var anchor: Int64 = 100
        let nowSec: Int64 = 101
        @Assert(secondElapsed(nowSec, anchor))
        anchor = nowSec
        @Assert(!secondElapsed(nowSec, anchor))
        // 正确写法：一个分支里判一次秒，同时驱动心跳与面板；下一秒照常到点
        @Assert(secondElapsed(102, anchor))
    }
}

/**
 * 忙时入队提示（2026-11-06，第八十七轮）
 *
 * 回归背景：用户连发 9 条同一句话才意识到"发了没反应"——忙碌时提交只入队、
 * 不打断当前回合，排队消息要等回合边界才注入；一次卡住 115 秒的请求期间，
 * 屏幕上只有状态行一行小字，既看不出收下几条，也不知道能立即发送。
 * 文案须同时答两件事：**第几条**与**Esc 可立即发送**。
 */
@Test
public class QueueHintTest {

    @TestCase
    public func testNoticeReportsSequence(): Unit {
        let s = queueNoticeText(3)
        @Assert(s.contains("第 3 条"))
        @Assert(s.contains("Esc"))
    }

    @TestCase
    public func testNoticeReportsFirstItem(): Unit {
        @Assert(queueNoticeText(1).contains("第 1 条"))
    }

    @TestCase
    public func testStatusHiddenWhenQueueEmpty(): Unit {
        // 0 条（或异常负值）不显示：空闲时状态行不该常驻一个空排队片段
        @Assert(queueStatusText(0) == "")
        @Assert(queueStatusText(-1) == "")
    }

    @TestCase
    public func testStatusShowsCountAndEsc(): Unit {
        let s = queueStatusText(2)
        @Assert(s.contains("2 条"))
        @Assert(s.contains("Esc"))
    }
}
