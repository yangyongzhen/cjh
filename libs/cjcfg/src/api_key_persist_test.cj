package cjcfg

import std.fs.*
import cjutil.*

/**
 * API Key 落盘回归测试（issue #6）
 *
 * 现象：`POST /api/settings` 里的 apiKey 只写内存 `config.apiKey`，`saveAll()`
 * 只落 base_url/model 等字段、从不写 auth.json，重启后 Key 回空串——但响应仍回
 * `{"ok":true}`，调用方无从分辨。而 `/provider` 走 `saveApiKey()` 写 auth.json
 * 是持久的，同一个 Key 两条路径行为不一致。
 *
 * 契约（修复后）：
 *   1. 经 `setApiKeyPendingPersist` 设置的 Key，`saveAll()` 必须落到 auth.json；
 *   2. settings.json **不得**出现 Key（凭据只进 auth.json 的既有分工）；
 *   3. 重新构造 CjhConfig 能读回该 Key（=「重启不丢」）；
 *   4. 未经 setApiKeyPendingPersist 的 Key（如环境变量注入）不得被顺手写进磁盘。
 */
@Test
public class ApiKeyPersistTest {
    private static func testDir(tag: String): String {
        // 跨平台：POSIX /tmp/cjh_ut_apikey_*，Windows %TEMP%\cjh_ut_apikey_*
        return testTmpPath("cjh_ut_apikey_${tag}")
    }

    private static func readText(path: String): String {
        return String.fromUtf8(File.readFrom(path))
    }

    /**
     * 递归清理测试目录
     *
     * removeIfExists 默认非递归：目录里已有 settings.json 时直接删会抛
     * "Directory not empty"（本次踩过），必须显式传 recursive。
     */
    private static func cleanDir(dir: String): Unit {
        if (!exists(dir)) {
            return
        }
        try {
            removeIfExists(dir, recursive: true)
        } catch (e: Exception) {
            // 清理失败不影响断言结果
            ()
        }
    }

    @TestCase
    public func testSaveAllPersistsApiKeyToAuthJson(): Unit {
        let dir = testDir("persist")
        cleanDir(dir)
        let cfg = CjhConfig(dir)
        cfg.setApiKeyPendingPersist("sk-ut-persist-123456")
        cfg.saveAll()

        // 1. auth.json 里有 Key
        @Assert(exists(cfg.authPath), true)
        @Assert(readText(cfg.authPath).contains("sk-ut-persist-123456"), true)
        // 2. settings.json 里没有 Key（凭据不进 settings）
        @Assert(readText(cfg.settingsPath).contains("sk-ut-persist-123456"), false)
        cleanDir(dir)
    }

    @TestCase
    public func testReloadReadsPersistedApiKey(): Unit {
        let dir = testDir("reload")
        cleanDir(dir)
        let cfg = CjhConfig(dir)
        cfg.setApiKeyPendingPersist("sk-ut-reload-abcdef")
        cfg.saveAll()

        // 3. 重新构造 = 重启：Key 应读回（环境变量优先级更高，故有 env Key 时按 env 断言）
        let envKey = EnvFfi.getenv("OPENAI_API_KEY") ?? EnvFfi.getenv("CJH_API_KEY") ?? ""
        let expected = if (envKey.size > 0) { envKey } else { "sk-ut-reload-abcdef" }
        let cfg2 = CjhConfig(dir)
        @Assert(cfg2.apiKey, expected)
        cleanDir(dir)
    }

    @TestCase
    public func testSaveAllDoesNotLeakNonPendingApiKey(): Unit {
        // 4. 直接改字段（模拟环境变量/加载来的 Key）不应被 saveAll 顺手写进 auth.json
        let dir = testDir("noleak")
        cleanDir(dir)
        let cfg = CjhConfig(dir)
        cfg.apiKey = "sk-ut-env-only-999"
        cfg.saveAll()
        @Assert(exists(cfg.authPath), false)
        cleanDir(dir)
    }
}
