package cjterm

/**
 * 原始控制键泄漏修复的单元测试（v1.4.0 回归防护）
 *
 * 根因：`KeyEvent(ch)` 旧实现无条件 `text = Rune(ch).toString()`，Ctrl+O(0x0F)、
 * Ctrl+Z(0x1A) 等控制字节因此带上 text，经 InputBox/Editor 可打印分支
 * （只判 `!isEsc && !isEnter && !isBackspace`）漏进输入框——真机 Windows
 * 按 Ctrl+O 即在输入框里插入一个不可见控制字符。
 *
 * 修复三层（本文件逐层锁定）：
 *   1. `KeyEvent(ch)`：仅可打印字符带 text（Enter/Tab/LF 例外，粘贴聚合依赖）
 *   2. `KeyEvent(ch, seq)`：裸控制字符 seq 不作 text（Windows Ctrl+数字路径）
 *   3. InputBox/Editor 可打印分支：isLoneControlText 兜底
 */

@Test
public class ControlKeyLeakTest {
    // ===== 层 1：单参构造 =====

    /** Ctrl+O(0x0F) 等控制字节不得带 text（真机 bug 主路径） */
    @TestCase
    public func testCtrlOhasNoText(): Unit {
        let k = KeyEvent(15)
        @Assert(k.ch, 15)
        @Assert(k.text.size, 0)
        @Assert(k.isEsc, false)
        @Assert(k.isEnter, false)
        @Assert(k.isBackspace, false)
    }

    /** 其余控制字节同样不得带 text */
    @TestCase
    public func testOtherControlBytesHaveNoText(): Unit {
        @Assert(KeyEvent(26).text.size, 0)   // Ctrl+Z
        @Assert(KeyEvent(1).text.size, 0)    // Ctrl+A
        @Assert(KeyEvent(3).text.size, 0)    // Ctrl+C
        @Assert(KeyEvent(4).text.size, 0)    // Ctrl+D
        @Assert(KeyEvent(18).text.size, 0)   // Ctrl+R
        @Assert(KeyEvent(21).text.size, 0)   // Ctrl+U
        @Assert(KeyEvent(31).text.size, 0)   // 0x1F
    }

    /** DEL(127) 是退格语义，不得带 text */
    @TestCase
    public func testDeleteHasNoText(): Unit {
        let k = KeyEvent(127)
        @Assert(k.text.size, 0)
        @Assert(k.isBackspace, true)
    }

    /** 可打印 ASCII 必须保留 text（不能误伤正常输入） */
    @TestCase
    public func testPrintableAsciiKeepsText(): Unit {
        @Assert(KeyEvent(72).text, "H")
        @Assert(KeyEvent(97).text, "a")
        @Assert(KeyEvent(48).text, "0")
        @Assert(KeyEvent(32).text, " ")   // 空格
        @Assert(KeyEvent(126).text, "~")
    }

    /** Enter/Tab/LF 保留 text：粘贴候选判定依赖 text.size == 1 */
    @TestCase
    public func testEnterTabLfKeepText(): Unit {
        @Assert(KeyEvent(13).text, "\r")
        @Assert(KeyEvent(10).text, "\n")
        @Assert(KeyEvent(9).text, "\t")
        @Assert(KeyEvent(13).isEnter, true)
        @Assert(KeyEvent(9).isTab, true)
    }

    // ===== 层 2：双参构造（seq 路径） =====

    /** Windows Ctrl+数字经 uChar 带出的裸控制字符不得作 text */
    @TestCase
    public func testTwoArgCtorBlanksLoneControl(): Unit {
        @Assert(KeyEvent(1, Rune(1).toString()).text.size, 0)
        @Assert(KeyEvent(15, Rune(15).toString()).text.size, 0)
    }

    /** 双参构造的正常文本/转义序列语义不变 */
    @TestCase
    public func testTwoArgCtorKeepsNormalText(): Unit {
        @Assert(KeyEvent(65, "A").text, "A")
        @Assert(KeyEvent(27, TermEsc.LEFT).text.size, 0)
        @Assert(KeyEvent(27, TermEsc.LEFT).isArrowLeft, true)
    }

    // ===== 层 3：输入组件兜底 =====

    /** isLoneControlText 纯函数：\t\n\r 与可打印字符不算控制键 */
    @TestCase
    public func testIsLoneControlText(): Unit {
        @Assert(isLoneControlText(Rune(15).toString()), true)
        @Assert(isLoneControlText(Rune(26).toString()), true)
        @Assert(isLoneControlText(Rune(127).toString()), true)
        @Assert(isLoneControlText("\t"), false)
        @Assert(isLoneControlText("\n"), false)
        @Assert(isLoneControlText("\r"), false)
        @Assert(isLoneControlText("a"), false)
        @Assert(isLoneControlText(""), false)
        @Assert(isLoneControlText("ab"), false)
        @Assert(isLoneControlText("中"), false)
    }

    /** InputBox：Ctrl+O 不被消费、不进输入内容 */
    @TestCase
    public func testInputBoxIgnoresCtrlO(): Unit {
        let box = InputBox()
        let handled = box.handleKey(KeyEvent(15))
        @Assert(handled, false)
        @Assert(box.text(), "")
    }

    /** InputBox：兜底守卫对"原生已带内容"零影响 */
    @TestCase
    public func testInputBoxKeepsExistingText(): Unit {
        let box = InputBox()
        box.setText("abc")
        box.handleKey(KeyEvent(15))
        @Assert(box.text(), "abc")
    }

    /** InputBox：可打印字符仍正常输入（回归不误伤） */
    @TestCase
    public func testInputBoxAcceptsPrintable(): Unit {
        let box = InputBox()
        let handled = box.handleKey(KeyEvent(72))
        @Assert(handled, true)
        @Assert(box.text(), "H")
    }

    /** MultiLineEditor：Ctrl+O 不被消费、不进编辑内容 */
    @TestCase
    public func testEditorIgnoresCtrlO(): Unit {
        let ed = MultiLineEditor()
        let handled = ed.handleKey(KeyEvent(15))
        @Assert(handled, false)
        @Assert(ed.text(), "")
    }

    /** MultiLineEditor：可打印字符仍正常输入 */
    @TestCase
    public func testEditorAcceptsPrintable(): Unit {
        let ed = MultiLineEditor()
        let handled = ed.handleKey(KeyEvent(72))
        @Assert(handled, true)
        @Assert(ed.text(), "H")
    }
}
