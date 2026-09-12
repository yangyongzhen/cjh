package cjterm

import std.collection.*

/**
 * v1.3.21 Windows 裸流粘贴修复的单元测试（回归防护）
 *
 * 根因：Windows 控制台不支持 bracketed paste，粘贴以离散按键事件涌入。
 * 旧实现只在"积压 ≥48 事件"时合并，且合并循环遇第一个 \r（isEnter）即
 * 停合并、丢弃该 \r → 长粘贴剩余部分留缓冲区，主循环逐帧读键时尾部 \r
 * 被当真实 Enter 触发提交（"粘贴带换行长文本直接发送"）；短粘贴（<48
 * 事件）带换行则全程走单键路径，每个 \r 直接 = 一次提交。
 *
 * 修复（对齐 atomcode input/reader.rs）：
 *   1. 长粘贴合并：Enter 视为粘贴内容里的换行并入文本（不再丢弃/停合并）
 *   2. burst 两级窗口聚合（PENDING 4ms / ACTIVE 15ms）：候选字符（可打印/
 *      裸 Enter/裸 Tab）连续到达即聚合；满足粘贴签名（≥2 字符 + 含换行 +
 *      含非空白 + 防 IME 逐字风暴）→ 单个 isPaste 事件；否则按序重放
 *   3. 重放队（replay）：非粘贴 burst 与合并打断的命令键不丢事件，
 *      下次 readKey 按序还回
 *
 * 用 MockBackend 模拟 conhost 离散按键流（CI 无真实 Windows 控制台）：
 * 队列即"输入缓冲"，readPendingBytes 返回队列长度（对齐 Windows 语义：
 * 待读 KEY_EVENT 数）。
 */

/**
 * mock 后端：预置按键队列模拟 Windows 控制台的离散 KEY_EVENT 流
 */
public class MockBackend <: TerminalBackend {
    var queue: ArrayList<KeyEvent>
    var bracketed: Bool

    public init(_q: ArrayList<KeyEvent>, _b: Bool) {
        this.queue = _q
        this.bracketed = _b
    }

    // ===== TerminalBackend 接口 =====

    public func enableRaw(): Bool {
        return true
    }

    public func disableRaw(): Unit {}

    public func hasInput(): Bool {
        return this.queue.size > 0
    }

    // Windows 语义：待读输入事件数（粘贴 N 字符 = N 个 KEY_EVENT）
    public func readPendingBytes(): Int64 {
        return this.queue.size
    }

    public func supportsBracketedPaste(): Bool {
        return this.bracketed
    }

    // burst 窗口等待：mock 队列非空即"有输入"（模拟分块到达的后续块）
    public func waitInput(_timeoutMs: Int64): Bool {
        return this.queue.size > 0
    }

    public func readKey(): Option<KeyEvent> {
        if (this.queue.size == 0) {
            return None
        }
        let k = this.queue[0]
        this.queue.remove(at: 0)
        return Some(k)
    }

    public func size(): (Int64, Int64) {
        return (24, 80)
    }

    public func isUtf8(): Bool {
        return true
    }

    public func suppressStderr(): Bool {
        return true
    }

    public func restoreStderr(): Unit {}
}

/**
 * 分块投递 mock 后端（v1.3.23）：模拟 conhost 把一次粘贴拆成多"波" KEY_EVENT
 * 写入输入缓冲、波与波之间存在毫秒级间隙的真实行为。
 *
 * 上一版 MockBackend 把队列一次性全部可见，于是合并循环必然把尾部 \r 一起
 * 吞进粘贴文本——测不出"尾部 Enter 单独成波"这一实测故障场景。
 *
 * 虚拟时钟语义（确定性，不依赖真实计时）：
 *  - 当前可见波非空：waitInput 立即 true，不阻塞、时钟不前进
 *  - 当前波耗尽：waitInput(ms) 推进虚拟时钟 ms，到期才把延迟波转可见
 *  - 测试用 advance(ms) 模拟帧间流逝（TUI 主循环每帧 16ms+）——
 *    延迟波因此在"下一个 readKey 的入口探测"时可见，与实测一致
 */
public class ChunkedMockBackend <: TerminalBackend {
    var visible: ArrayList<KeyEvent>
    var deferred: ArrayList<KeyEvent>
    var delayMs: Int64
    var clockMs: Int64 = 0
    var bracketed: Bool

    public init(_visible: ArrayList<KeyEvent>, _deferred: ArrayList<KeyEvent>,
        _delayMs: Int64, _b: Bool) {
        this.visible = _visible
        this.deferred = _deferred
        this.delayMs = _delayMs
        this.bracketed = _b
    }

    /** 测试驱动：模拟经过 ms 毫秒（延迟波到期即转可见） */
    public func advance(_ms: Int64): Unit {
        this.clockMs += _ms
        this.promote()
    }

    private func promote(): Unit {
        if (this.deferred.size > 0 && this.clockMs >= this.delayMs) {
            for (k in this.deferred) {
                this.visible.add(k)
            }
            this.deferred = ArrayList<KeyEvent>(0)
        }
    }

    public func enableRaw(): Bool {
        return true
    }

    public func disableRaw(): Unit {}

    public func hasInput(): Bool {
        this.promote()
        return this.visible.size > 0
    }

    public func readPendingBytes(): Int64 {
        this.promote()
        return this.visible.size
    }

    public func supportsBracketedPaste(): Bool {
        return this.bracketed
    }

    public func waitInput(_timeoutMs: Int64): Bool {
        if (this.visible.size > 0) {
            return true  // 有立即可读输入：不阻塞、时钟不前进
        }
        this.clockMs += _timeoutMs
        this.promote()
        return this.visible.size > 0
    }

    public func readKey(): Option<KeyEvent> {
        this.promote()
        if (this.visible.size == 0) {
            return None
        }
        let k = this.visible[0]
        this.visible.remove(at: 0)
        return Some(k)
    }

    public func size(): (Int64, Int64) {
        return (24, 80)
    }

    public func isUtf8(): Bool {
        return true
    }

    public func suppressStderr(): Bool {
        return true
    }

    public func restoreStderr(): Unit {}
}

@Test
public class TermPasteBurstTest {

    // 测试辅助：单字符键（可打印，对齐 Windows ch != 0 路径）
    static func ch(_s: String): KeyEvent {
        var first: Int32 = 0
        if (_s.size > 0) {
            first = Int32(_s.toArray()[0])
        }
        return KeyEvent(first, _s)
    }

    /**
     * 用户实测粘贴文本 → 逐字符 KEY_EVENT 波（对齐 conhost 一个 UTF-16
     * 单元一个 KEY_EVENT 的投递粒度；行间换行 = 裸 Enter 事件）
     */
    static func pasteWave(_lines: ArrayList<String>): ArrayList<KeyEvent> {
        var out = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < _lines.size) {
            for (r in _lines[i].toRuneArray()) {
                let s = r.toString()
                var first: Int32 = 0
                if (s.size > 0) {
                    first = Int32(s.toArray()[0])
                }
                out.add(KeyEvent(first, s))
            }
            if (i < _lines.size - 1) {
                out.add(KeyEvent(13))
            }
            i += 1
        }
        return out
    }

    /** 读键直到无输入（排空粘贴前半段逐键余项），返回读到的键数 */
    static func drain(_term: Term): Int64 {
        var n: Int64 = 0
        while (n < 500) {
            if (_term.readKey().isNone()) {
                break
            }
            n += 1
        }
        return n
    }

    /** 主路径：短多行粘贴（<48 事件）合并为单个 isPaste，\r 并入文本不触发提交 */
    @TestCase
    public func testShortMultilinePasteCoalesced(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("h"))
        q.add(ch("i"))
        q.add(KeyEvent(13))  // 裸 Enter（conhost VK_RETURN，text="\r"）
        q.add(ch("!"))
        let term = Term(MockBackend(q, false))
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.isEnter, false)
            @Assert(k.text, "hi\r!")
        } else {
            @Assert(false)
        }
        // 缓冲已耗尽
        @Assert(term.readKey().isNone(), true)
    }

    /** 回归根因：长粘贴（>48 事件）尾部 \r 并入粘贴文本，不残留触发提交 */
    @TestCase
    public func testLongPasteTailEnterAbsorbed(): Unit {
        var q = ArrayList<KeyEvent>(0)
        for (i in 0..50) {
            q.add(ch("a"))
        }
        q.add(KeyEvent(13))  // 尾部换行：旧实现在此停合并丢弃 → 后续帧当 Enter 提交
        let term = Term(MockBackend(q, false))
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.text.size, 51)
            @Assert(k.text[50] == 13u8, true)  // 末字节 = \r
        } else {
            @Assert(false)
        }
        // 全部吞读完：无残留键（旧实现此处残留尾部内容 → 逐帧读到 \r → 提交）
        @Assert(term.readKey().isNone(), true)
    }

    /** 非粘贴 burst（无换行）+ 后续命令键：按序重放不丢事件 */
    @TestCase
    public func testControlKeyReplayedInOrder(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("x"))
        q.add(ch("y"))
        q.add(KeyEvent(27, TermEsc.LEFT))  // 方向键 = 命令，打断 burst
        q.add(ch("z"))
        let term = Term(MockBackend(q, false))
        // 'x' 触发 burst，聚合 'xy' 遇方向键停止；无换行 → 非粘贴签名
        // 按序还回：'x'、'y'、方向键、'z'
        if (let Some(k1) <- term.readKey()) {
            @Assert(k1.isPaste, false)
            @Assert(k1.text, "x")
        } else {
            @Assert(false)
        }
        if (let Some(k2) <- term.readKey()) {
            @Assert(k2.text, "y")
        } else {
            @Assert(false)
        }
        if (let Some(k3) <- term.readKey()) {
            @Assert(k3.isArrowLeft, true)
        } else {
            @Assert(false)
        }
        if (let Some(k4) <- term.readKey()) {
            @Assert(k4.text, "z")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** IME 逐字提交风暴（字↵字↵字）不得误判为粘贴：按序重放 */
    @TestCase
    public func testImeStormNotCoalesced(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("首"))
        q.add(KeyEvent(13))
        q.add(ch("页"))
        q.add(KeyEvent(13))
        q.add(ch("中"))
        q.add(KeyEvent(13))
        let term = Term(MockBackend(q, false))
        // 3 行、每行 1 字符（平均 ≤1）→ is_paste_burst 条件 4 拒绝
        if (let Some(k1) <- term.readKey()) {
            @Assert(k1.isPaste, false)
            @Assert(k1.text, "首")
        } else {
            @Assert(false)
        }
        if (let Some(k2) <- term.readKey()) {
            @Assert(k2.isEnter, true)
        } else {
            @Assert(false)
        }
        if (let Some(k3) <- term.readKey()) {
            @Assert(k3.text, "页")
        } else {
            @Assert(false)
        }
        if (let Some(k4) <- term.readKey()) {
            @Assert(k4.isEnter, true)
        } else {
            @Assert(false)
        }
        if (let Some(k5) <- term.readKey()) {
            @Assert(k5.text, "中")
        } else {
            @Assert(false)
        }
        if (let Some(k6) <- term.readKey()) {
            @Assert(k6.isEnter, true)
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 单键打字不受 burst 窗口影响：单字符 + 无后续输入 → 原样返回 */
    @TestCase
    public func testLoneCharNotCoalesced(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("a"))
        let term = Term(MockBackend(q, false))
        if (let Some(k1) <- term.readKey()) {
            @Assert(k1.isPaste, false)
            @Assert(k1.text, "a")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 快速单行打字（无换行 burst）：按序重放，不合并不丢 */
    @TestCase
    public func testFastTypingReplayedPerKey(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("a"))
        q.add(ch("b"))
        q.add(ch("c"))
        let term = Term(MockBackend(q, false))
        if (let Some(k1) <- term.readKey()) {
            @Assert(k1.isPaste, false)
            @Assert(k1.text, "a")
        } else {
            @Assert(false)
        }
        if (let Some(k2) <- term.readKey()) {
            @Assert(k2.text, "b")
        } else {
            @Assert(false)
        }
        if (let Some(k3) <- term.readKey()) {
            @Assert(k3.text, "c")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 2 行粘贴且每行 >1 字符 → 判为粘贴（IME 防御仅 ≥3 行生效） */
    @TestCase
    public func testTwoLinePasteCoalesced(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("a"))
        q.add(ch("b"))
        q.add(KeyEvent(13))
        q.add(ch("c"))
        q.add(ch("d"))
        let term = Term(MockBackend(q, false))
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.text, "ab\rcd")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 多行粘贴（4 行）每行 2 字符：IME 防御不误伤 → 判为粘贴 */
    @TestCase
    public func testMultilinePasteEachLineTwoChars(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("a"))
        q.add(ch("b"))
        q.add(KeyEvent(13))
        q.add(ch("c"))
        q.add(ch("d"))
        q.add(KeyEvent(13))
        q.add(ch("e"))
        q.add(ch("f"))
        q.add(KeyEvent(13))
        q.add(ch("g"))
        q.add(ch("h"))
        let term = Term(MockBackend(q, false))
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.text, "ab\r" + "cd\r" + "ef\r" + "gh")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 全空白 + 换行的 burst（tty 队列残留 Enter）不得判为粘贴 */
    @TestCase
    public func testWhitespaceOnlyBurstNotCoalesced(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch(" "))
        q.add(KeyEvent(13))
        q.add(ch(" "))
        let term = Term(MockBackend(q, false))
        if (let Some(k1) <- term.readKey()) {
            @Assert(k1.isPaste, false)
            @Assert(k1.text, " ")
        } else {
            @Assert(false)
        }
        if (let Some(k2) <- term.readKey()) {
            @Assert(k2.isEnter, true)
        } else {
            @Assert(false)
        }
        if (let Some(k3) <- term.readKey()) {
            @Assert(k3.text, " ")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    /** 中文多行粘贴：多字节字符 + 换行合并，文本完整不乱码 */
    @TestCase
    public func testChineseMultilinePaste(): Unit {
        var q = ArrayList<KeyEvent>(0)
        q.add(ch("你好"))
        q.add(KeyEvent(13))
        q.add(ch("世界"))
        let term = Term(MockBackend(q, false))
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.text, "你好\r世界")
        } else {
            @Assert(false)
        }
        @Assert(term.readKey().isNone(), true)
    }

    // ===== v1.3.23：分块投递下的"粘贴补发 Enter"回归锁 =====
    // 实测故障：conhost 把一次粘贴拆成多波写入输入缓冲，剪贴板末尾换行
    // 单独成一波（波间 >15ms）。旧实现把该波当作单键 burst（chars 仅 1）
    // → 判非粘贴签名 → 原样返回裸 Enter → InputBox 立即提交（用户没按回车）。

    /** 用户实测文本（短版，走 burst 合并路径）+ 尾部补发 Enter 不得提交 */
    @TestCase
    public func testChunkedMultilinePasteTrailingEnterNotSubmitted(): Unit {
        var lines = ArrayList<String>(0)
        lines.add("内存安全：杜绝野指针；")
        lines.add("零外部依赖部署：编译期嵌入。")
        var first = pasteWave(lines)
        @Assert(first.size < 48, true)  // 锁：本用例走 burst 路径（非 bulk）
        var tail = ArrayList<KeyEvent>(0)
        tail.add(KeyEvent(13))
        let mock = ChunkedMockBackend(first, tail, 40, false)
        let term = Term(mock)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)  // 前半段已识别为粘贴（含换行）
        } else {
            @Assert(false)
        }
        mock.advance(50)  // 下一帧：尾部补发 Enter 波到达
        // 关键：尾部补发 Enter 必须被吞掉（None），绝不能当真实提交键
        @Assert(term.readKey().isNone(), true)
    }

    /** 用户实测长文本（≥48 事件，走 bulk 粘贴流合并路径）尾部 Enter 不得提交 */
    @TestCase
    public func testChunkedBulkPasteTrailingEnterNotSubmitted(): Unit {
        var lines = ArrayList<String>(0)
        lines.add("AtomMQTT Broker 是一个面向生产环境的轻量级 MQTT Broker。与 Mosquitto 等成熟 Broker 相比，它用现代 Rust + Tokio 异步运行时重新实现了 MQTT 核心链路，带来以下直接收益：")
        lines.add("内存安全：Rust 所有权系统从语言层面杜绝了野指针、数据竞争与缓冲区溢出；")
        var first = pasteWave(lines)
        @Assert(first.size >= 48, true)  // 锁：本用例走 bulk 路径
        var tail = ArrayList<KeyEvent>(0)
        tail.add(KeyEvent(13))
        let mock = ChunkedMockBackend(first, tail, 40, false)
        let term = Term(mock)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
        } else {
            @Assert(false)
        }
        mock.advance(50)
        @Assert(term.readKey().isNone(), true)
    }

    /** 波界恰好落在换行前：前半段无换行成波，换行单独成波 —— 亦不得提交 */
    @TestCase
    public func testChunkBoundaryBeforeNewlineNotSubmitted(): Unit {
        var lines = ArrayList<String>(0)
        lines.add("AtomMQTT Broker 是一个面向生产环境的轻量级 MQTT Broker")
        var first = pasteWave(lines)
        var tail = ArrayList<KeyEvent>(0)
        tail.add(KeyEvent(13))
        let mock = ChunkedMockBackend(first, tail, 40, false)
        let term = Term(mock)
        let typed = drain(term)  // 无换行 burst 不做粘贴合并，逐键重放
        @Assert(typed > 0, true)
        mock.advance(50)
        @Assert(term.readKey().isNone(), true)
    }

    /** 反例锁：手敲少量字符（无换行、密度不足）后的 Enter 必须照常提交 */
    @TestCase
    public func testTrailingEnterAfterTypedCharsStillSubmits(): Unit {
        var first = ArrayList<KeyEvent>(0)
        first.add(ch("a"))
        first.add(ch("b"))
        first.add(ch("c"))
        var tail = ArrayList<KeyEvent>(0)
        tail.add(KeyEvent(13))
        let mock = ChunkedMockBackend(first, tail, 40, false)
        let term = Term(mock)
        @Assert(drain(term), 3)
        mock.advance(50)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isEnter, true)
            @Assert(k.isPaste, false)
        } else {
            @Assert(false)
        }
    }

    /** 反例锁：守护窗口过期后，用户 Enter 照常提交（不长期吞键） */
    @TestCase
    public func testPasteEnterGuardExpires(): Unit {
        var lines = ArrayList<String>(0)
        lines.add("内存安全：Rust 所有权系统从语言层面杜绝了野指针；")
        lines.add("零外部依赖部署：前端静态文件在编译期嵌入二进制。")
        var first = pasteWave(lines)
        var tail = ArrayList<KeyEvent>(0)
        tail.add(KeyEvent(13))
        let mock = ChunkedMockBackend(first, tail, 40, false)
        let term = Term(mock)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
        } else {
            @Assert(false)
        }
        sleep(Duration.millisecond * 300)  // 越过 PASTE_ENTER_GUARD_MS
        mock.advance(50)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isEnter, true)
            @Assert(k.isPaste, false)
        } else {
            @Assert(false)
        }
    }
}
