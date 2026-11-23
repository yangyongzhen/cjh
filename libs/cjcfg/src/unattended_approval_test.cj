package cjcfg

import std.fs.*

/**
 * unattended_approval 配置解析测试（安全语义，必须与实现同批）。
 *
 * 契约：
 * - 缺省 deny：headless 改测试断言必须停下等审批；
 * - 显式 "tests" 才启用；
 * - 未知值/非字符串一律回落 deny（fail-closed，不能因拼错就静默放开）。
 */
@Test
public class UnattendedApprovalConfigTest {

    private static func cleanDir(dir: String): Unit {
        if (!exists(dir)) {
            return
        }
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            ()
        }
    }

    @TestCase
    public func testDefaultIsDeny(): Unit {
        let dir = testTmpPath("cjh_ut_unattended_default")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json", "{\"model\": \"m\", \"base_url\": \"https://x/v1\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.unattendedApproval, "deny")
        cleanDir(dir)
    }

    @TestCase
    public func testTestsValueEnables(): Unit {
        let dir = testTmpPath("cjh_ut_unattended_tests")
        cleanDir(dir)
        Directory.create(dir)
        File.writeTo("${dir}/settings.json",
            "{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"unattended_approval\": \"TESTS\"}".toArray())
        let cfg = CjhConfig(dir)
        @Assert(cfg.unattendedApproval, "tests")
        cleanDir(dir)
    }

    @TestCase
    public func testUnknownOrNonStringFallsBackToDeny(): Unit {
        for (raw in ["\"allow-all\"", "1", "true"]) {
            let dir = testTmpPath("cjh_ut_unattended_bad")
            cleanDir(dir)
            Directory.create(dir)
            File.writeTo("${dir}/settings.json",
                "{\"model\": \"m\", \"base_url\": \"https://x/v1\", \"unattended_approval\": ${raw}}".toArray())
            let cfg = CjhConfig(dir)
            @Assert(cfg.unattendedApproval, "deny")
            cleanDir(dir)
        }
    }
}
