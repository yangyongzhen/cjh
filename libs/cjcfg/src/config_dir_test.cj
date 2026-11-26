package cjcfg

/**
 * 配置目录解析：空/空白 CJH_CONFIG_DIR 必须回落到 home，而不是生成空路径。
 *
 * 回归背景：`CJH_CONFIG_DIR= cjh ...` 时旧实现取到 Some("")，configDir 变成空串，
 * settingsPath 拼成 `/settings.json`，ensureDirs() 对空目录 create 抛异常直接崩。
 */
@Test
public class ConfigDirResolveTest {
    @TestCase
    public func testUnsetUsesHomeDefault(): Unit {
        @Assert(resolveConfigDir(None, "/home/u", "/"), "/home/u/.cjh")
    }

    @TestCase
    public func testEmptyOverrideFallsBackToHome(): Unit {
        @Assert(resolveConfigDir(Some(""), "/home/u", "/"), "/home/u/.cjh")
        @Assert(resolveConfigDir(Some("   "), "/home/u", "/"), "/home/u/.cjh")
        @Assert(resolveConfigDir(Some("\t\n"), "/home/u", "/"), "/home/u/.cjh")
    }

    @TestCase
    public func testExplicitOverrideWinsAndIsTrimmed(): Unit {
        @Assert(resolveConfigDir(Some("/tmp/cjh-cfg"), "/home/u", "/"), "/tmp/cjh-cfg")
        @Assert(resolveConfigDir(Some("  /tmp/cjh-cfg  "), "/home/u", "/"), "/tmp/cjh-cfg")
        @Assert(resolveConfigDir(Some("D:\\cjh"), "C:\\Users\\u", "\\"), "D:\\cjh")
    }
}
