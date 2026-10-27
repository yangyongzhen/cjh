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
}
