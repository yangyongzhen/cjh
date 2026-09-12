package cjterm

import std.collection.*

/**
 * v1.3.26 真机性能 bug 回归：裸流粘贴 drain 循环在「抬键记录」（readKey 返
 * None）处 break，且此时 count==0 → 每次 readKey() 只吃 1~3 条记录。
 * 真机实测：414 字符粘贴花 6.6 秒（≈63 字符/秒）、`TERM pending` 标记 2939
 * 条——粘贴文本在 TUI 里逐字爬行。
 *
 * 复现模型：复用 term_paste_fallback_test.cj 的 PasteFallbackKeyUpBackend
 * （把抬键哨兵 ch==1 翻译成 readKey() 返 None，复刻真机 term_windows.cj
 * bKeyDown=false 记录「被消费但不上报」的语义）+ DribbleMockBackend
 * （一帧投递若干事件、共享 FakeClock 注入）。
 *
 * 修复目标：一次 readKey() 把缓冲里已到达的粘贴字符基本吃干（N=200 字符
 * 所需 readKey() 调用 ≤ 4），同时粘贴文本里的 CR 仍折叠进粘贴文本、
 * 绝不变成真实回车。
 */
@Test
public class TermPasteDrainTest {

    // 测试辅助：单字符键（可打印，对齐 Windows ch != 0 路径）
    static func ch(_s: String): KeyEvent {
        var first: Int32 = 0
        if (_s.size > 0) {
            first = Int32(_s.toArray()[0])
        }
        return KeyEvent(first, _s)
    }

    /**
     * 真机根因复现：一帧投递 200 个字符，其间混入抬键记录（→readKey 返 None）。
     * 修复前 drain 循环首遇抬键即 break、count 复位 → 每次 readKey 只吞几字符，
     * 需几十次调用；修复后应 ≤4 次调用吃完（近乎瞬时贴完）。
     */
    @TestCase
    public func testSingleFramePasteDrainedInFewReads(): Unit {
        let clock = FakeClock()
        var q = ArrayList<KeyEvent>(0)
        var expected = StringBuilder()
        var i: Int64 = 0
        while (i < 200) {
            q.add(ch("a"))
            expected.append("a")
            if (i % 5 == 4) {
                q.add(PasteFallbackKeyUpBackend.keyUp())  // 抬键：readKey 消费后返 None
            }
            i += 1
        }
        // perFrame 足够大：整段粘贴一帧投递（对齐 conhost 大批量写入缓冲）
        let mock = PasteFallbackKeyUpBackend(DribbleMockBackend(q, clock, 4096))
        let term = Term(mock, clock)
        mock.frame(16)

        var got = StringBuilder()
        var calls: Int64 = 0
        while (got.size < 200 && calls < 50) {
            calls += 1
            if (let Some(k) <- term.readKey()) {
                @Assert(k.isPaste, true)
                got.append(k.text)
            } else {
                @Assert(false)  // 粘贴正文不得被吞
            }
        }
        @Assert(got.toString(), expected.toString())  // 内容完整到位
        @Assert(calls <= 4, true)                     // 一次 readKey 基本吃干
    }

    /**
     * 粘贴文本里的 CR 必须折叠进粘贴文本（多行粘贴入输入框），不得变成真实
     * 回车；抬键记录混入时同样不得打断折叠。
     */
    @TestCase
    public func testSingleFramePasteFoldsCrWithKeyUps(): Unit {
        let clock = FakeClock()
        var q = ArrayList<KeyEvent>(0)
        var expected = StringBuilder()
        var i: Int64 = 0
        while (i < 48) {
            q.add(ch("a"))
            expected.append("a")
            i += 1
        }
        q.add(PasteFallbackKeyUpBackend.keyUp())  // 抬键穿插
        q.add(KeyEvent(13))                       // 粘贴内容里的换行
        expected.append("\r")
        q.add(PasteFallbackKeyUpBackend.keyUp())
        i = 0
        while (i < 48) {
            q.add(ch("b"))
            expected.append("b")
            i += 1
        }
        let mock = PasteFallbackKeyUpBackend(DribbleMockBackend(q, clock, 4096))
        let term = Term(mock, clock)
        mock.frame(16)

        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)
            @Assert(k.isEnter, false)             // CR 不是真实提交回车
            @Assert(k.text, expected.toString())  // CR 折叠进粘贴文本
        } else {
            @Assert(false)
        }
    }
}
