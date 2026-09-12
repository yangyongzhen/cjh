package cjterm

import std.collection.*

/**
 * 抬键（key-up）后端 —— v1.3.25 真机 bug 回归专用替身。
 *
 * 动机：真机 term_windows.cj 的 readKey()（第 318-320 行）读到
 * `bKeyDown == false` 的 INPUT_RECORD 时会**消费该记录但返回 None**
 * （只处理按下事件）；而 readPendingBytes()/hasInput() 都取自
 * GetNumberOfConsoleInputEvents 的**记录总数**——于是「缓冲区仍有记录」
 * 与「readKey() 返回 None」可以同时成立。这正是 readRawStreamPaste()
 * 的 drain 循环「遇到 key-up 就 break 且 count==0」的成因。
 *
 * DribbleMockBackend 的 readKey() 对任何事件都返回 Some，无法表达这一
 * 差异（trace.cj 也注明 bKeyDown 语义「mock backend 无法复现」）。
 * 故此处**复用 DribbleMockBackend**（frame 投递节奏、FakeClock 注入、
 * pending/visible 缓冲全部照用），仅以组合方式把「抬键哨兵」翻译成 None。
 */
class PasteFallbackKeyUpBackend <: TerminalBackend {
    let inner: DribbleMockBackend

    public init(inner: DribbleMockBackend) {
        this.inner = inner
    }

    /** 抬键记录哨兵：真机 bKeyDown=false 记录的替身（ch=1） */
    public static func keyUp(): KeyEvent {
        return KeyEvent(1)
    }

    /** 测试驱动透传：推进注入时钟并投递一帧事件（同 DribbleMockBackend.frame） */
    public func frame(_ms: Int64): Unit {
        this.inner.frame(_ms)
    }

    public func enableRaw(): Bool { return this.inner.enableRaw() }
    public func disableRaw(): Unit { this.inner.disableRaw() }
    // 记录总数照常计数（含抬键记录）——对齐真机 GetNumberOfConsoleInputEvents
    public func hasInput(): Bool { return this.inner.hasInput() }
    public func readPendingBytes(): Int64 { return this.inner.readPendingBytes() }
    public func supportsBracketedPaste(): Bool { return this.inner.supportsBracketedPaste() }
    public func waitInput(_timeoutMs: Int64): Bool { return this.inner.waitInput(_timeoutMs) }
    // 关键差异：抬键记录被消费了，但不上报按键（对齐真机 readKey 只认 bKeyDown）
    public func readKey(): Option<KeyEvent> {
        if (let Some(k) <- this.inner.readKey()) {
            if (k.ch == 1) {
                return None
            }
            return Some(k)
        }
        return None
    }
    public func size(): (Int64, Int64) { return this.inner.size() }
    public func isUtf8(): Bool { return this.inner.isUtf8() }
    public func suppressStderr(): Bool { return this.inner.suppressStderr() }
    public func restoreStderr(): Unit { this.inner.restoreStderr() }
}

/**
 * v1.3.25 真机 bug 回归：裸流粘贴批量合并（readRawStreamPaste）的末尾早退分支
 * `return this.backend.readKey()` 绕过 readGuardedRawKey() 的粘贴守护。
 *
 * 真机定性：Windows 裸流粘贴按帧投递（每帧 1~3 条）。当 drain 循环一上来就
 * 撞到「抬键记录」（readKey 返回 None）时循环 break、count==0，落入该早退
 * 分支——它不经过 readGuardedRawKey()，于是粘贴文本里的 CR（KeyEvent(13)）
 * 被原样当成真实回车直达应用 → TUI 在粘贴过程中多次自动提交。
 * 修复：该分支改为 `return this.readGuardedRawKey()`，让 CR 落回守护判定。
 */
@Test
public class TermPasteFallbackTest {

    // 测试辅助：单字符键（可打印，对齐 Windows ch != 0 路径）
    static func ch(_s: String): KeyEvent {
        var first: Int32 = 0
        if (_s.size > 0) {
            first = Int32(_s.toArray()[0])
        }
        return KeyEvent(first, _s)
    }

    /**
     * 复现：粘贴守护已置位时，批量合并路径在「抬键记录」处 break（count==0），
     * 紧随其后的粘贴文本 CR 绝不能被无守卫地当成真实 Enter 返回。
     */
    @TestCase
    public func testBulkFallbackKeyUpDoesNotLeakPasteCr(): Unit {
        let clock = FakeClock()
        // ---- 阶段一：一帧投入 ≥48 个可打印字符，触发 bulk 合并并置位粘贴守护 ----
        var arm = ArrayList<KeyEvent>(0)
        var i: Int64 = 0
        while (i < 48) {
            arm.add(ch("a"))
            i += 1
        }
        let mock = PasteFallbackKeyUpBackend(DribbleMockBackend(arm, clock, 48))
        let term = Term(mock, clock)
        mock.frame(16)
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isPaste, true)  // bulk 合并命中 → readRawStreamPaste 内 markPasteStream()
        } else {
            @Assert(false)
        }

        // ---- 阶段二：同一帧内先到抬键记录，再到粘贴文本里的 CR ----
        // （真机 conhost 把一次粘贴拆帧写入，抬键与随后补发的换行同批到达。）
        var wave = ArrayList<KeyEvent>(0)
        wave.add(PasteFallbackKeyUpBackend.keyUp())  // 抬键：readKey() 消费后返回 None
        wave.add(KeyEvent(13))                       // 粘贴文本里的 CR
        i = 0
        while (i < 46) {
            wave.add(ch("x"))  // 仅用于把记录总数顶到 bulk 阈值（≥48），不被 drain 读到
            i += 1
        }
        for (k in wave) {
            mock.inner.pending.add(k)
        }
        mock.frame(16)

        // 关键断言：drain 循环撞上抬键后，CR 不得无守卫直达应用。
        // （不返回 Enter 即通过：守护丢弃 → None，或折叠进粘贴文本 → isPaste。）
        if (let Some(k) <- term.readKey()) {
            @Assert(k.isEnter, false)
        }
    }
}
