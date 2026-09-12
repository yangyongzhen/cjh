package cjterm

import std.fs.*
import std.process.*

/** 测试用：清除环境变量（`setenv` 由运行时提供，`unsetenv` 需自行声明） */
@C
foreign func unsetenv(name: CString): Int32

/**
 * KeyTrace（诊断追踪）测试：
 * - 默认关闭（opt-in）：不设变量或设关闭值均不落盘、无面包屑（正式使用零副作用）
 * - 显式真值才开启：`1`/`on`/`true`/`yes`/`y`/`enable`（容忍引号与空白）
 * - 垃圾值不开启但可诊断（`describe()` 回显写法，绝不静默失败）
 * - hex 字段格式化（真机轨迹要能区分 0x0D 裸 Enter / 0x0A LF / scan 0x1C）
 * - 开启时逐行追加（含序号与 t= 前缀）
 * - 关闭时绝不落盘（正常路径零副作用）
 *
 * 临时目录：/tmp/cjh_ut_trace_*（用例内自建自清；仓颉无递归删除 API → bash rm -rf）
 */
@Test
public class KeyTraceTest {

    private func freshDir(name: String): String {
        let dir = "/tmp/cjh_ut_trace_" + name
        try {
            var args = Array<String>(2, repeat: "")
            args[0] = "-c"
            args[1] = "rm -rf '" + dir + "'"
            let _ = executeWithOutput("/bin/bash", args)
        } catch (e: Exception) {
            // 清理失败不影响用例
        }
        Directory.create(dir, recursive: true)
        return dir
    }

    @TestCase
    public func testHexFormat(): Unit {
        @Assert(KeyTrace.hex(0), "0x0")
        @Assert(KeyTrace.hex(13), "0xD")
        @Assert(KeyTrace.hex(28), "0x1C")
        @Assert(KeyTrace.hex(255), "0xFF")
        @Assert(KeyTrace.hex(65535), "0xFFFF")
    }

    @TestCase
    public func testEnabledAppendsLines(): Unit {
        let dir = this.freshDir("enabled")
        let path = dir + "/keys.log"
        KeyTrace.enableForTest(path)
        KeyTrace.mark("RAW down=1 vk=0xD scan=0x1C")
        KeyTrace.mark("TERM GUARD-DROP enter")
        KeyTrace.disableForTest()
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("RAW down=1 vk=0xD scan=0x1C"), true)
        @Assert(content.contains("TERM GUARD-DROP enter"), true)
        @Assert(content.contains("t="), true)
        @Assert(content.contains("#1"), true)
        @Assert(content.contains("#2"), true)
    }

    @TestCase
    public func testDisabledWritesNothing(): Unit {
        let dir = this.freshDir("disabled")
        let path = dir + "/off.log"
        KeyTrace.disableForTest()
        KeyTrace.mark("should-not-write")
        var created = true
        try {
            let _ = File.readFrom(path)
        } catch (e: Exception) {
            created = false
        }
        @Assert(created, false)
    }

    // ===== 环境变量值解析（v1.3.25 加固：此前"设了变量却静默失效"） =====

    /**
     * 引号必须剥掉：cmd 的 `set CJH_TRACE_KEYS="1"` 把引号写进值里，
     * 不剥则与 "1" 比较必然不等 → 追踪永不开启且无任何提示
     */
    @TestCase
    public func testNormalizeStripsQuotes(): Unit {
        @Assert(KeyTrace.normalizeValue("\"1\""), "1")
        @Assert(KeyTrace.normalizeValue("'1'"), "1")
        @Assert(KeyTrace.normalizeValue("\"on\""), "on")
        // 剥完引号仍要trim（set X=" 1 " 这种手写值）
        @Assert(KeyTrace.normalizeValue("\" 1 \""), "1")
    }

    @TestCase
    public func testNormalizeTrimsWhitespace(): Unit {
        @Assert(KeyTrace.normalizeValue("1 "), "1")
        @Assert(KeyTrace.normalizeValue(" 1"), "1")
        @Assert(KeyTrace.normalizeValue("\t1\r\n"), "1")
        @Assert(KeyTrace.normalizeValue("   "), "")
    }

    /** 边界：单字符、引号不配对、纯空白——不得越界切片或误剥 */
    @TestCase
    public func testNormalizeBoundary(): Unit {
        @Assert(KeyTrace.normalizeValue(""), "")
        @Assert(KeyTrace.normalizeValue("\""), "\"")
        @Assert(KeyTrace.normalizeValue("\"1"), "\"1")
        @Assert(KeyTrace.normalizeValue("1\""), "1\"")
        @Assert(KeyTrace.normalizeValue("'1\""), "'1\"")
        @Assert(KeyTrace.normalizeValue("abc"), "abc")
    }

    /** 真值判定：大小写不敏感，多种写法；非真值一律 false */
    @TestCase
    public func testTruthyValues(): Unit {
        @Assert(KeyTrace.isTruthy("1"), true)
        @Assert(KeyTrace.isTruthy("on"), true)
        @Assert(KeyTrace.isTruthy("ON"), true)
        @Assert(KeyTrace.isTruthy("True"), true)
        @Assert(KeyTrace.isTruthy("yes"), true)
        @Assert(KeyTrace.isTruthy("Y"), true)
        @Assert(KeyTrace.isTruthy("enable"), true)
        @Assert(KeyTrace.isTruthy("0"), false)
        @Assert(KeyTrace.isTruthy("off"), false)
        @Assert(KeyTrace.isTruthy(""), false)
        // 组合：normalize 之后再判定（生产路径即此顺序）
        @Assert(KeyTrace.isTruthy(KeyTrace.normalizeValue("\"YES\"")), true)
        @Assert(KeyTrace.isTruthy(KeyTrace.normalizeValue(" 1 ")), true)
    }

    /** 识别边界：垃圾值必须被标为"配置有误"（否则只会静默不生效） */
    @TestCase
    public func testRecognizedValues(): Unit {
        @Assert(KeyTrace.isRecognized("1"), true)
        @Assert(KeyTrace.isRecognized("on"), true)
        @Assert(KeyTrace.isRecognized("0"), true)
        @Assert(KeyTrace.isRecognized("off"), true)
        @Assert(KeyTrace.isRecognized("false"), true)
        @Assert(KeyTrace.isRecognized(""), true)
        @Assert(KeyTrace.isRecognized("2"), false)
        @Assert(KeyTrace.isRecognized("yes please"), false)
        @Assert(KeyTrace.isRecognized("tru"), false)
        @Assert(KeyTrace.isRecognized("\"1\""), false)
    }

    /** 关闭值判定：显式关闭值（大小写不敏感）；真值与垃圾值都不算 */
    @TestCase
    public func testFalsyValues(): Unit {
        @Assert(KeyTrace.isFalsy("0"), true)
        @Assert(KeyTrace.isFalsy("OFF"), true)
        @Assert(KeyTrace.isFalsy("false"), true)
        @Assert(KeyTrace.isFalsy("no"), true)
        @Assert(KeyTrace.isFalsy("n"), true)
        @Assert(KeyTrace.isFalsy("disable"), true)
        @Assert(KeyTrace.isFalsy("1"), false)
        @Assert(KeyTrace.isFalsy(""), false)
        @Assert(KeyTrace.isFalsy("yes please"), false)
    }

    /** 默认落点：与 cjh.log/tui.log 同目录（~/.cjh），无家目录才回退当前目录 */
    @TestCase
    public func testDefaultPathFor(): Unit {
        @Assert(KeyTrace.defaultPathFor("/root"), "/root/.cjh/cjh_keys.log")
        @Assert(KeyTrace.defaultPathFor("C:\\Users\\x"), "C:\\Users\\x/.cjh/cjh_keys.log")
        @Assert(KeyTrace.defaultPathFor(""), "cjh_keys.log")
    }

    // ===== 环境变量端到端（复现 v1.3.24"设了却无文件"） =====

    private func setEnv(name: String, value: String): Unit {
        unsafe {
            setenv(LibC.mallocCString(name), LibC.mallocCString(value), 1)
        }
    }

    private func clearEnv(name: String): Unit {
        unsafe {
            unsetenv(LibC.mallocCString(name))
        }
    }

    /**
     * opt-in 主路径 + 复现用例：cmd 的 `set CJH_TRACE_KEYS="1"` 让值带上引号。
     * 值解析若不去引号 → 与 "1" 比较必然不等 → 显式开启却静默不生效、无文件无提示；
     * 现行为 → 去引号后判为真值并开启，启动即落头行（"文件存在"即证明变量已生效）
     */
    @TestCase
    public func testQuotedEnvStillEnables(): Unit {
        let dir = this.freshDir("envquoted")
        let path = dir + "/keys.log"
        this.setEnv("CJH_TRACE_KEYS", "\"1\"")
        this.setEnv("CJH_TRACE_FILE", path)
        KeyTrace.resetForTest()
        let on = KeyTrace.isEnabled()
        let resolved = KeyTrace.outputPath()
        this.clearEnv("CJH_TRACE_KEYS")
        this.clearEnv("CJH_TRACE_FILE")
        KeyTrace.disableForTest()
        @Assert(on, true)
        @Assert(resolved, path)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("=== cjh key trace"), true)
        @Assert(content.contains(path), true)
    }

    /**
     * 配置有误必须能自证：垃圾值 → 不开启（安全默认），但 `describe()` 提示正确写法，
     * 且不落任何文件——既不误开，也不"设了却静默失败"
     */
    @TestCase
    public func testGarbageEnvIsDiagnosable(): Unit {
        let dir = this.freshDir("envgarbage")
        let path = dir + "/keys.log"
        this.setEnv("CJH_TRACE_KEYS", "\"yes please\"")
        this.setEnv("CJH_TRACE_FILE", path)
        KeyTrace.resetForTest()
        let on = KeyTrace.isEnabled()
        let note = KeyTrace.describe()
        let resolved = KeyTrace.outputPath()
        KeyTrace.mark("should-not-write")
        this.clearEnv("CJH_TRACE_KEYS")
        this.clearEnv("CJH_TRACE_FILE")
        KeyTrace.disableForTest()
        @Assert(on, false)
        @Assert(resolved, "")
        @Assert(note.contains("无法识别"), true)
        @Assert(note.contains("yes please"), true)
        var created = true
        try {
            let _ = File.readFrom(path)
        } catch (e: Exception) {
            created = false
        }
        @Assert(created, false)
    }

    /** 不设任何环境变量 → 默认关闭（正式使用零副作用：不落盘、面包屑静默） */
    @TestCase
    public func testUnsetEnvDefaultsOff(): Unit {
        let dir = this.freshDir("envunset")
        let path = dir + "/keys.log"
        this.clearEnv("CJH_TRACE_KEYS")
        this.setEnv("CJH_TRACE_FILE", path)
        KeyTrace.resetForTest()
        let on = KeyTrace.isEnabled()
        let note = KeyTrace.describe()
        let resolved = KeyTrace.outputPath()
        KeyTrace.mark("RAW down=1 vk=0xD scan=0x1C uChar=0xD")
        this.clearEnv("CJH_TRACE_FILE")
        KeyTrace.disableForTest()
        @Assert(on, false)
        @Assert(note, "")
        @Assert(resolved, "")
        var created = true
        try {
            let _ = File.readFrom(path)
        } catch (e: Exception) {
            created = false
        }
        @Assert(created, false)
    }

    /** 显式关闭值（0/off/…）与"未设置"同为不开启：mark 不落盘、面包屑静默 */
    @TestCase
    public func testExplicitOffDisables(): Unit {
        let dir = this.freshDir("envoff")
        let path = dir + "/keys.log"
        this.setEnv("CJH_TRACE_KEYS", "0")
        this.setEnv("CJH_TRACE_FILE", path)
        KeyTrace.resetForTest()
        let on = KeyTrace.isEnabled()
        let note = KeyTrace.describe()
        KeyTrace.mark("should-not-write")
        this.clearEnv("CJH_TRACE_KEYS")
        this.clearEnv("CJH_TRACE_FILE")
        KeyTrace.disableForTest()
        @Assert(on, false)
        @Assert(note, "")
        var created = true
        try {
            let _ = File.readFrom(path)
        } catch (e: Exception) {
            created = false
        }
        @Assert(created, false)
    }
}
