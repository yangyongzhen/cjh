package cjterm

/**
 * bracketed paste 读取循环的结束判据（回归防护）
 *
 * 根因（2026-11-06 实测）：用户终端发出 `ESC[200~` 开始标记而闭合标记
 * `ESC[201~` 没到（断包、IME/终端异常、或粘贴流被打断）时，旧逻辑只靠
 * "连续 3 次 waitInput(200) 无数据"（600ms 空闲）退出。而用户此时只要还在
 * 打字，waitInput 每次都能拿到数据 → idleStreak 永远归零 → **永不退出**，
 * 后续所有按键（含回车）全被当粘贴内容吞进 raw，输入框毫无反应。
 * pty 实测：发 ESC[200~ 后打 "HELLO"、"WORLD\r"，输入框全程空白、无任何
 * 按键进入 handleKey，最后攒成一条 "HELLOWORLD" 一起提交。
 *
 * 修复：给粘贴读取加"总时长兜底"——未闭合但已持续超过 PASTE_MAX_MS 时，
 * 无论是否仍有数据到达都结束本轮（已收内容按粘贴插入），用户打字立刻恢复。
 */
@Test
class PasteReadStopTest {
    /** 正常结束：读到 ESC[201~ 闭合标记立即停 */
    @TestCase
    func closedStops(): Unit {
        @Assert(pasteReadStop(50, 0, true))
    }

    /** 600ms 空闲（idleStreak 达 3）停：这是原有的唯一退出条件，须保留 */
    @TestCase
    func idleStops(): Unit {
        @Assert(pasteReadStop(700, 3, false))
    }

    /**
     * 关键回归：未闭合 + 数据持续到达（idleStreak 恒 0）也必须停。
     * 旧逻辑在此返回 false → 无限吞键（用户实测"打字没反应"的根因）。
     */
    @TestCase
    func unclosedButTooLongStops(): Unit {
        @Assert(pasteReadStop(PASTE_MAX_MS, 0, false))
    }

    /** 反例：刚开始的粘贴不得被提前截断（大粘贴分块投递依赖它） */
    @TestCase
    func freshPasteContinues(): Unit {
        @Assert(!pasteReadStop(200, 0, false))
    }
}
