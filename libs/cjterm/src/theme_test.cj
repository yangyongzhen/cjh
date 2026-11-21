package cjterm

import std.collection.*

/**
 * 主题表契约：omp-dark 为默认，空/未知名回退 omp-dark。
 *
 * 背景：默认主题从 starfrost 切到 omp-dark（对齐 oh-my-pi dark），
 * 主题名由 settings.json 持久化；空值必须落到新默认，不能静默回到旧主题。
 * 同时锁定关键色码，防止后续调色误改 omp 对齐值。
 */
@Test
public class ThemeOmpDarkTest {

    @TestCase
    public func testEmptyThemeAppliesOmpDark(): Unit {
        let prev = Theme.current()
        try {
            @Assert(Theme.apply(""), "omp-dark")
            @Assert(Theme.current(), "omp-dark")
            @Assert(Ansi.THEME_ACCENT, 214)   // #febc38
            @Assert(Ansi.THEME_OK, 114)       // #89d281
            @Assert(Ansi.THEME_ERR, 203)      // #fc3a4b
            @Assert(Ansi.THEME_MUTED, 243)    // #777d88
            @Assert(Ansi.COLOR_TEXT, 254)     // #e5e5e7
            @Assert(Ansi.THEME_USER_BG, 235)  // 近背景用户卡片
            @Assert(Ansi.THEME_STATUS_BG, 233)
            @Assert(Ansi.THEME_BORDER, 31)    // #178fb9
        } finally {
            let _ = Theme.apply(prev)
        }
    }

    @TestCase
    public func testUnknownThemeFallsBackToOmpDark(): Unit {
        let prev = Theme.current()
        try {
            @Assert(Theme.apply("no-such-theme"), "omp-dark")
        } finally {
            let _ = Theme.apply(prev)
        }
    }

    @TestCase
    public func testOmpDarkIsListed(): Unit {
        @Assert(Theme.list().contains("omp-dark"), true)
        @Assert(Theme.list().contains("starfrost"), true)
    }
}
