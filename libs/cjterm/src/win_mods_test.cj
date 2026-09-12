package cjterm

/**
 * WinMods（Win32 dwControlKeyState 判定）测试。
 *
 * 复现的 bug（v1.3.25 真机日志定性，见 docs/开发文档与踩坑记录.md §3.29）：
 * 原实现把 RIGHT_CTRL_PRESSED 写成 0x10（真实是 RIGHT_ALt=0x1/右 Ctrl=0x4，
 * 0x10 是 SHIFT_PRESSED），于是 ctrl 掩码 = 0x8|0x10 把 **Shift 当成了 Ctrl**。
 * Windows Terminal 粘贴大写字母时带 SHIFT 位 → 走 `if (ctrl) { vk-64 }` 分支 →
 * 大写字母被解码为控制码：M(0x4D)→13=CR、J(0x4A)→10=LF（凭空造出回车/换行），
 * B→2、R→18、T→20…… 粘贴文本因此既乱码又可能被提交。
 *
 * 这里把判定做成平台无关纯函数，让 Linux 门禁也能钉住这个回归；
 * 记录→KeyEvent 的完整映射在 @When[os == "Windows"] 内，只能由真机轨迹覆盖。
 */
@Test
public class WinModsTest {

    /** ABI 钉桩：位掩码必须与 Win32 规范一致（写错就是本 bug 的根源） */
    @TestCase
    public func testBitMasksMatchWin32Abi(): Unit {
        @Assert(WIN_RIGHT_ALT_PRESSED, 0x1)
        @Assert(WIN_LEFT_ALT_PRESSED, 0x2)
        @Assert(WIN_RIGHT_CTRL_PRESSED, 0x4)
        @Assert(WIN_LEFT_CTRL_PRESSED, 0x8)
        @Assert(WIN_SHIFT_PRESSED, 0x10)
    }

    /** 复现核心：Shift 绝不能判成 Ctrl（否则大写字母 → 控制码） */
    @TestCase
    public func testShiftIsNotCtrl(): Unit {
        @Assert(winCtrlPressed(WIN_SHIFT_PRESSED), false)
        @Assert(winShiftPressed(WIN_SHIFT_PRESSED), true)
        @Assert(winAltPressed(WIN_SHIFT_PRESSED), false)
    }

    /** 左右 Ctrl 都算 Ctrl */
    @TestCase
    public func testCtrlDetected(): Unit {
        @Assert(winCtrlPressed(WIN_LEFT_CTRL_PRESSED), true)
        @Assert(winCtrlPressed(WIN_RIGHT_CTRL_PRESSED), true)
        @Assert(winCtrlPressed(WIN_LEFT_CTRL_PRESSED | WIN_RIGHT_CTRL_PRESSED), true)
        @Assert(winCtrlPressed(0), false)
    }

    /** 左右 Alt 都算 Alt；右 Ctrl 不得被判成 Alt（此前的 0x4 误配） */
    @TestCase
    public func testAltDetected(): Unit {
        @Assert(winAltPressed(WIN_LEFT_ALT_PRESSED), true)
        @Assert(winAltPressed(WIN_RIGHT_ALT_PRESSED), true)
        @Assert(winAltPressed(WIN_RIGHT_CTRL_PRESSED), false)
        @Assert(winAltPressed(0), false)
    }

    /** Ctrl+Shift 同时按下：两者都成立（Ctrl+C 复制等仍要能用） */
    @TestCase
    public func testCtrlShiftCombined(): Unit {
        let state = WIN_LEFT_CTRL_PRESSED | WIN_SHIFT_PRESSED
        @Assert(winCtrlPressed(state), true)
        @Assert(winShiftPressed(state), true)
    }

    /** Lock 键与 ENHANCED 位不得干扰判定 */
    @TestCase
    public func testLockKeysAndEnhancedNotCtrl(): Unit {
        @Assert(winCtrlPressed(0x20), false)  // NUMLOCK_ON
        @Assert(winCtrlPressed(0x40), false)  // SCROLLLOCK_ON
        @Assert(winCtrlPressed(0x80), false)  // CAPSLOCK_ON
        @Assert(winCtrlPressed(0x100), false) // ENHANCED_KEY
        // 大小写锁定 + Shift（真实大写字母输入的组合）仍不是 Ctrl
        @Assert(winCtrlPressed(WIN_SHIFT_PRESSED | 0x80), false)
    }
}
