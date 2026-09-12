package cjterm

/**
 * token 计数 k 格式（`fmtTokenCount`）单测。
 *
 * 契约：< 1000 原样十进制；1000 ~ 99999 一位小数 k；≥ 100000 取整 k；负值兜底。
 *
 * 动机：token 数此前有的地方直接打原始数字（123456 → 挤爆状态行）、有的地方
 * 各写一份 k 换算（1.5K/一位小数），格式随调用点漂移。统一入口后在此单点锁定。
 */

@Test
public class TokenFmtTest {
    /** 主路径：千以下原样十进制（不出现 0.8k 这种反直觉写法） */
    @TestCase
    public func testUnderThousandPlain(): Unit {
        @Assert(fmtTokenCount(0), "0")
        @Assert(fmtTokenCount(1), "1")
        @Assert(fmtTokenCount(842), "842")
    }

    /** 主路径：千级一位小数（1.2k） */
    @TestCase
    public func testThousandsOneDecimal(): Unit {
        @Assert(fmtTokenCount(1000), "1.0k")
        @Assert(fmtTokenCount(1234), "1.2k")
        @Assert(fmtTokenCount(4855), "4.8k")
        @Assert(fmtTokenCount(99250), "99.2k")
    }

    /** 边界：999→1000 换形态；99999→100000 小数位收成整数 k（省状态行宽度） */
    @TestCase
    public func testFormSwitchBoundaries(): Unit {
        @Assert(fmtTokenCount(999), "999")
        @Assert(fmtTokenCount(1000), "1.0k")
        @Assert(fmtTokenCount(99999), "99.9k")
        @Assert(fmtTokenCount(100000), "100k")
        @Assert(fmtTokenCount(128456), "128k")
    }

    /** 边界：负值（不应出现）原样返回不抛异常 */
    @TestCase
    public func testNegativeFallback(): Unit {
        @Assert(fmtTokenCount(-5), "-5")
    }
}
