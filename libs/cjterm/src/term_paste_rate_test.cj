package cjterm

import std.collection.*
import std.time.*

/**
 * 虚拟时钟（v1.3.24）：与 DribbleMockBackend 共享同一时间源，Term 的时间窗口
 * 判定（粘贴守护 / 到达速率）在单测内确定性可复现——真机投递节奏与机器速度
 * 无关，也不会因 CI 负载抖动而偶发失败（v1.3.21/23 用真实 sleep 模拟节奏，
 * 与 Windows Terminal 实测节奏不一致，两次修复均漏判）。
 */
public class FakeClock <: Clock {
    private let base: DateTime
    private var ms: Int64 = 0

    public init() {
        this.base = DateTime.now()
    }

    /** 推进虚拟时间（毫秒） */
    public func advance(_ms: Int64): Unit {
        this.ms += _ms
    }

    public func now(): DateTime {
        return this.base + Duration.millisecond * this.ms
    }
}

/**
 * 分帧投递 mock（v1.3.24 根因模型）：模拟 Windows Terminal 把粘贴内容按帧分块
 * 写入控制台输入缓冲——每帧只有 1~3 个事件、帧间数十毫秒。
 *
 * 与 ChunkedMockBackend 的区别：
 *  - 等待输入不推进时钟（时间完全由测试 frame(ms) 驱动）
 *  - 与 Term 共享 FakeClock，速率判据可确定性验证
 */
public class DribbleMockBackend <: TerminalBackend {
    var pending: ArrayList<KeyEvent>
    var visible: ArrayList<KeyEvent>
    let clock: FakeClock
    let perFrame: Int64

    public init(q: ArrayList<KeyEvent>, clock: FakeClock, perFrame: Int64) {
        this.pending = q
        this.visible = ArrayList<KeyEvent>(0)
        this.clock = clock
        this.perFrame = perFrame
    }

    /** 测试驱动：一帧过去 _ms 毫秒，投递本帧事件（WT 按帧写控制台缓冲） */
    public func frame(_ms: Int64): Unit {
        this.clock.advance(_ms)
        var delivered: Int64 = 0
        while (delivered < this.perFrame && this.pending.size > 0) {
            this.visible.add(this.pending[0])
            this.pending.remove(at: 0)
            delivered += 1
        }
    }

    public func enableRaw(): Bool {
        return true
    }

    public func disableRaw(): Unit {}

    public func hasInput(): Bool {
        return this.visible.size > 0
    }

    public func readPendingBytes(): Int64 {
        return this.visible.size
    }

    public func supportsBracketedPaste(): Bool {
        return false
    }

    public func waitInput(_timeoutMs: Int64): Bool {
        return this.visible.size > 0
    }

    public func readKey(): Option<KeyEvent> {
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
public class TermPasteRateTest {

    // 单字符键（可打印，对齐 Windows ch != 0 路径）
    static func ch(_s: String): KeyEvent {
        var first: Int32 = 0
        if (_s.size > 0) {
            first = Int32(_s.toArray()[0])
        }
        return KeyEvent(first, _s)
    }

    /**
     * 根因复现（v1.3.24）：分帧投递的粘贴（每帧 1 字符、帧间 16ms）读不出
     * "密集"签名，尾部补发的换行被当作真实 Enter → 用户没按回车却提交。
     * 速率判据命中后，该换行必须被吞掉。
     */
    @TestCase
    public func testDribblePasteTrailingEnterDropped(): Unit {
        var q = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < 20) {
            q.add(ch("文"))
            i += 1
        }
        q.add(KeyEvent(13))  // 剪贴板末尾换行（终端补发）
        let clock = FakeClock()
        let mock = DribbleMockBackend(q, clock, 1)
        let term = Term(mock, clock)

        i = 0
        while (i < 20) {
            mock.frame(16)
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, false)  // 正文逐字符入框
                @Assert(k.isPaste, false)
            } else {
                @Assert(false)             // 正文不得被吞
            }
            i += 1
        }
        mock.frame(16)
        // 关键：尾部换行必须被吞掉（None），否则 InputBox 立即提交
        @Assert(term.readKey().isNone(), true)
    }

    /** 正文含空行（行间换行单独成帧）：已判粘贴流后同样不得提交 */
    @TestCase
    public func testDribblePasteInteriorNewlineDropped(): Unit {
        var q = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < 14) {
            q.add(ch("文"))
            i += 1
        }
        q.add(KeyEvent(13))  // 空行：正文内部换行
        i = 0
        while (i < 6) {
            q.add(ch("字"))
            i += 1
        }
        q.add(KeyEvent(13))  // 尾部换行
        let clock = FakeClock()
        let mock = DribbleMockBackend(q, clock, 1)
        let term = Term(mock, clock)

        i = 0
        while (i < 14) {
            mock.frame(16)
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, false)
            }
            i += 1
        }
        mock.frame(16)
        @Assert(term.readKey().isNone(), true)  // 行间换行被吞
        i = 0
        while (i < 6) {
            mock.frame(16)
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, false)
            }
            i += 1
        }
        mock.frame(16)
        @Assert(term.readKey().isNone(), true)  // 尾部换行被吞
    }

    /** 反例锁：人类打字节奏（400ms/字符）后的回车必须照常提交 */
    @TestCase
    public func testSlowTypingEnterStillSubmits(): Unit {
        var q = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < 10) {
            q.add(ch("a"))
            i += 1
        }
        q.add(KeyEvent(13))
        let clock = FakeClock()
        let mock = DribbleMockBackend(q, clock, 1)
        let term = Term(mock, clock)

        i = 0
        while (i < 10) {
            mock.frame(400)
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, false)
            }
            i += 1
        }
        mock.frame(400)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isEnter, true)   // 真实回车 → 提交
            @Assert(k.isPaste, false)
        } else {
            @Assert(false)
        }
    }

    /**
     * 反例锁（输入法逐字提交，与 §3.25 同类）：高频"字 + 回车"风暴的换行占比
     * ≈1:1，速率判据的换行占比要求必须拒绝；每次上屏回车都要照常提交，
     * 否则中文输入会被吞掉回车（严重回归）。
     */
    @TestCase
    public func testDenseImeStormEnterStillSubmits(): Unit {
        var q = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < 14) {
            q.add(ch("字"))
            q.add(KeyEvent(13))
            i += 1
        }
        let clock = FakeClock()
        let mock = DribbleMockBackend(q, clock, 1)
        let term = Term(mock, clock)

        i = 0
        while (i < 14) {
            mock.frame(10)  // 上屏字符
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, false)
            } else {
                @Assert(false)
            }
            mock.frame(10)  // 上屏确认回车
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isEnter, true)  // 必须提交
            } else {
                @Assert(false)
            }
            i += 1
        }
    }
}
