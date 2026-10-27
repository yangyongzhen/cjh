package cjterm

/**
 * 输入框提示符图标能力测试（conhost 缺 ❯ 字形 → 降级 "> "）
 *
 * 背景：PowerShell/老控制台（conhost）在 cjh 切到代码页 65001 后 isUtf8()==true、
 * 框线也能画，但**字体**常没有 U+276F ❯ 的字形，渲染成方框；Windows Terminal 正常。
 * 因此图标（❯/🔍）与编码（框线 ╰─）必须分开判定：
 *  - `setUtf8(false)`     → 框线降级 `+-- `
 *  - `setFancyIcons(false)` → 图标降级 `> ` / `? `，框线不受影响
 */
@Test
public class InputPromptIconTest {

    @TestCase
    public func testDefaultPromptUsesFancyIcon(): Unit {
        let ib = InputBox()
        // 默认 utf8=true + fancy=true → omp 风格提示符
        @Assert(ib.currentPrompt(), "╰─ ❯ ")
        @Assert(ib.promptWidth(), 5)
    }

    @TestCase
    public func testAsciiIconKeepsBoxDrawing(): Unit {
        let ib = InputBox()
        ib.setFancyIcons(false)
        // 只降图标：框线仍是 ╰─（conhost 能画框线，只是缺 ❯ 字形）
        @Assert(ib.currentPrompt(), "╰─ > ")
        @Assert(ib.currentPrompt().contains("❯"), false)
        @Assert(ib.promptWidth(), 5)  // "╰─ > " 仍 5 个码点
    }

    @TestCase
    public func testAsciiTerminalDegradesBoth(): Unit {
        let ib = InputBox()
        ib.setUtf8(false)
        ib.setFancyIcons(false)
        @Assert(ib.currentPrompt(), "+-- > ")
        @Assert(ib.currentPrompt().contains("❯"), false)
        @Assert(ib.currentPrompt().contains("╰"), false)
    }

    @TestCase
    public func testGlyphPolicyForceAsciiWins(): Unit {
        // CJH_ASCII_ICONS 优先于其它判据（包括 CJH_FORCE_UTF8）
        @Assert(useFancyPromptGlyphsFrom(Some("1"), Some("1"), true, true), false)
        @Assert(useFancyPromptGlyphsFrom(Some("1"), None, false, false), false)
    }

    @TestCase
    public func testGlyphPolicyForceUtf8(): Unit {
        @Assert(useFancyPromptGlyphsFrom(None, Some("1"), false, true), true)
        @Assert(useFancyPromptGlyphsFrom(Some(""), Some("1"), false, true), true)
    }

    @TestCase
    public func testGlyphPolicyWindowsNeedsModernTerminal(): Unit {
        // Windows：只有现代终端（Windows Terminal/ConEmu）才用花体图标
        @Assert(useFancyPromptGlyphsFrom(None, None, false, true), false)
        @Assert(useFancyPromptGlyphsFrom(None, None, true, true), true)
        // POSIX：字体普遍覆盖 ❯，无需现代终端判据
        @Assert(useFancyPromptGlyphsFrom(None, None, false, false), true)
    }

    // ── 光标列（1-based）回归：中文光标曾落在汉字中间 ──

    /** 渲染输入框后取画布光标列（1-based；提示符 + 文本显示宽度 + 1） */
    private func cursorColOf(text: String): Int64 {
        let ib = InputBox()
        for (r in text.toRuneArray()) {
            ib.handleKey(KeyEvent(r.toString()))
        }
        let canvas = TuiCanvas()
        canvas.begin(4, 80, true)
        ib.render(canvas, 0, 80, 5)
        let (_, col) = canvas.cursorPosition()
        return col
    }

    @TestCase
    public func testCursorColumnAscii(): Unit {
        // 提示符 "╰─ ❯ " 占 1..5 列，ASCII 文本从第 6 列起：
        // "ab" 占 6、7 → 光标应在第 8 列（1-based）。此前少 1（7），光标压在 'b' 上。
        @Assert(this.cursorColOf("ab"), 8)
    }

    @TestCase
    public func testCursorColumnCjk(): Unit {
        // "你好" 各占 2 列（6-7、8-9）→ 光标应在第 10 列；
        // 此前是 9 ＝ 落在"好"的第二格，视觉上就是"光标在汉字中间"（用户实测）
        @Assert(this.cursorColOf("你好"), 10)
    }

    @TestCase
    public func testCursorColumnMixedWidth(): Unit {
        @Assert(this.cursorColOf("你a"), 9)
        @Assert(this.cursorColOf("a你"), 9)
    }
}
