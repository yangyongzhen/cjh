package cjterm

import std.time.*
import std.fs.*

/**
 * 按键追踪（诊断专用，v1.3.25）
 *
 * 动机：Windows Terminal 粘贴"补发换行"是否被当作真实 Enter 提交，取决于真机
 * 投递节奏与 INPUT_RECORD 字段（wVirtualKeyCode / wVirtualScanCode / uChar /
 * bKeyDown）——mock backend 无法复现，只有真机轨迹能定性。
 *
 * 默认关闭（opt-in）：真机粘贴投递问题已定性（v1.3.26 复打后 `TERM bulk`
 * 由 422 次降到 8 次、每次一次吃干约 890 条记录），无需常驻记录——恢复
 * "需要时才开"，正式使用零副作用。仅显式真值（`CJH_TRACE_KEYS=1`/`on`/
 * `true`/`yes`/`y`/`enable`，大小写不敏感、容忍引号与空白）才开启。
 * 产物在 `${USERPROFILE|HOME}/.cjh/cjh_keys.log`（与 cjh.log/tui.log 同目录，
 * 便于事后查找；无家目录则回退进程当前目录），路径可用 `CJH_TRACE_FILE` 改。
 * **无法识别的值按"不开启"处理**（安全默认），但 `describe()` 会回显写法——
 * 既不误开，也不会"设了却不生效"地静默失败。
 *
 * 每次运行重置：进程启动时以 `w` 打开写头行（版本 + 启动时刻 + 实际落点），
 * 之后逐行追加——文件只保留最近一次运行的轨迹，永不无界增长；头行同时让
 * "文件存在"成为"追踪确实在写"的自证。
 *
 * 轨迹含键入键码（RAW 行的 `uChar` 为十六进制码点），仅用于终端投递诊断，
 * 只在排查时临时开启。
 *
 * 落点不可写时（目录不存在/权限）回退进程当前目录并在文件内留痕，不再静默丢弃。
 *
 * 零依赖：libc FFI（fopen/fputs/fclose），不引入 cjlog/cjutil——cjterm 保持
 * 底层包职责单一（见 AGENTS.md 工程规范 3）。
 *
 * 行格式：`t=<微秒> #<序号> <标签> k=v ...`（按序阅读即可还原投递节奏）
 */
public class KeyTrace {
    private static var initialized: Bool = false
    private static var enabled: Bool = false
    /** `CJH_TRACE_KEYS` 是否出现在环境中（与"值为真值"区分，用于诊断提示） */
    private static var configured: Bool = false
    /** 原始值（规范化后），配置有误时回显给用户 */
    private static var flagRaw: String = ""
    /** 空 = 尚未解析落点（ensureInit 解析；测试可注入） */
    private static var filePath: String = ""
    private static var fallback: Bool = false
    private static var start: ?DateTime = None
    private static var seq: Int64 = 0

    private static func ensureInit(): Unit {
        if (KeyTrace.initialized) {
            return
        }
        KeyTrace.initialized = true
        // 默认关闭：诊断按需开启，不打扰正式使用（仅显式真值才开）
        KeyTrace.enabled = false
        if (let Some(v) <- TermEnv.getenv("CJH_TRACE_KEYS")) {
            KeyTrace.configured = true
            KeyTrace.flagRaw = KeyTrace.normalizeValue(v)
            if (KeyTrace.isTruthy(KeyTrace.flagRaw)) {
                KeyTrace.enabled = true
            }
        }
        if (let Some(p) <- TermEnv.getenv("CJH_TRACE_FILE")) {
            let v = KeyTrace.normalizeValue(p)
            if (v.size > 0) {
                KeyTrace.filePath = v
            }
        }
        if (KeyTrace.filePath.size == 0) {
            KeyTrace.filePath = KeyTrace.defaultPathFor(KeyTrace.homeDir())
        }
        if (KeyTrace.enabled) {
            KeyTrace.ensureParentDir(KeyTrace.filePath)
            KeyTrace.startRun("=== cjh key trace ${Logo.VERSION} started=${DateTime.now()} path=${KeyTrace.filePath}")
        }
    }

    /** 追踪是否开启（调用点用它守卫字符串拼接，关闭时零开销） */
    public static func isEnabled(): Bool {
        KeyTrace.ensureInit()
        return KeyTrace.enabled
    }

    /** 实际落点（供上层打面包屑；未开启时为空串） */
    public static func outputPath(): String {
        KeyTrace.ensureInit()
        if (!KeyTrace.enabled) {
            return ""
        }
        return KeyTrace.filePath
    }

    /**
     * 供上层（TUI 启动）写一行诊断面包屑：
     * 开启 → 落点（用户不必猜文件在哪）；正常关闭 → ""（静默，无噪音）；
     * 关闭但值无法识别 → 提示正确写法（既不误开，也不静默失败）
     */
    public static func describe(): String {
        KeyTrace.ensureInit()
        if (KeyTrace.enabled) {
            return "按键追踪已开启 → ${KeyTrace.filePath}"
        }
        if (KeyTrace.configured && !KeyTrace.isRecognized(KeyTrace.flagRaw)) {
            return "按键追踪未开启：CJH_TRACE_KEYS='${KeyTrace.flagRaw}' 无法识别（真值：1/on/true/yes/y/enable）"
        }
        return ""
    }

    /** 追加一行轨迹（加前缀 t=<微秒自首事件> #<序号>） */
    public static func mark(msg: String): Unit {
        if (!KeyTrace.isEnabled()) {
            return
        }
        KeyTrace.seq += 1
        KeyTrace.appendLine("t=${KeyTrace.stampUs()} #${KeyTrace.seq} ${msg}")
    }

    /** 十六进制字面量（测试可断言；无符号十进制入参） */
    public static func hex(v: Int64): String {
        let digits = "0123456789ABCDEF"
        var x: Int64 = v
        if (x < 0) {
            x = 0
        }
        if (x == 0) {
            return "0x0"
        }
        var out: String = ""
        while (x > 0) {
            let d = x % 16
            out = digits[d..d + 1] + out
            x = x / 16
        }
        return "0x" + out
    }

    // ===== 环境变量值解析（纯函数，便于确定性单测） =====

    /**
     * 去首尾空白 + 去成对引号。必要性：
     *  - cmd 的 `set CJH_TRACE_KEYS="1"` 会把引号**写进值里**（值为 `"1"`），
     *    直接比较必然不等 → 静默失效，是最典型的"设了却没生效"
     *  - 从示例粘贴时常见尾随空格
     */
    public static func normalizeValue(s: String): String {
        var v = KeyTrace.trimAscii(s)
        if (v.size >= 2) {
            let first = v[0]
            let last = v[v.size - 1]
            let dq = 34u8      // "
            let sq = 39u8      // '
            if ((first == dq && last == dq) || (first == sq && last == sq)) {
                v = v[1..v.size - 1]
            }
        }
        return KeyTrace.trimAscii(v)
    }

    /** 真值判定（大小写不敏感）：1/on/true/yes/y/enable */
    public static func isTruthy(v: String): Bool {
        let low = v.toAsciiLower()
        return low == "1" || low == "on" || low == "true" || low == "yes" ||
            low == "y" || low == "enable"
    }

    /** 显式关闭值（大小写不敏感）：0/off/false/no/n/disable —— 与"未设置"同为不开启（保留以便回显与测试） */
    public static func isFalsy(v: String): Bool {
        let low = v.toAsciiLower()
        return low == "0" || low == "off" || low == "false" || low == "no" ||
            low == "n" || low == "disable"
    }

    /** 是否能被识别（真值 或 显式关闭值 或 空串）；其余视为配置有误 */
    public static func isRecognized(v: String): Bool {
        return KeyTrace.isTruthy(v) || KeyTrace.isFalsy(v) || v.size == 0
    }

    /** 家目录（Windows 优先 USERPROFILE，POSIX 用 HOME）；无则空串 */
    public static func homeDir(): String {
        if (let Some(up) <- TermEnv.getenv("USERPROFILE")) {
            let v = KeyTrace.normalizeValue(up)
            if (v.size > 0) {
                return v
            }
        }
        if (let Some(h) <- TermEnv.getenv("HOME")) {
            let v = KeyTrace.normalizeValue(h)
            if (v.size > 0) {
                return v
            }
        }
        return ""
    }

    /** 默认落点：有家目录 → 与 cjh.log/tui.log 同目录；否则回退进程当前目录 */
    public static func defaultPathFor(home: String): String {
        if (home.size > 0) {
            return "${home}/.cjh/cjh_keys.log"
        }
        return "cjh_keys.log"
    }

    // ===== 测试注入 =====

    /** 测试注入：直接开启并指定输出文件（绕过环境变量） */
    public static func enableForTest(path: String): Unit {
        KeyTrace.initialized = true
        KeyTrace.enabled = true
        KeyTrace.configured = true
        KeyTrace.flagRaw = "1"
        KeyTrace.filePath = path
        KeyTrace.fallback = false
        KeyTrace.start = None
        KeyTrace.seq = 0
    }

    /** 测试注入：关闭 */
    public static func disableForTest(): Unit {
        KeyTrace.initialized = true
        KeyTrace.enabled = false
        KeyTrace.configured = true
        KeyTrace.flagRaw = "0"
    }

    /** 测试注入：清空解析状态，令下次 ensureInit 重新读环境变量（配合 setenv 用例） */
    public static func resetForTest(): Unit {
        KeyTrace.initialized = false
        KeyTrace.enabled = false
        KeyTrace.configured = false
        KeyTrace.flagRaw = ""
        KeyTrace.filePath = ""
        KeyTrace.fallback = false
        KeyTrace.start = None
        KeyTrace.seq = 0
    }

    // ===== 内部实现 =====

    private static func trimAscii(s: String): String {
        var a: Int64 = 0
        var b: Int64 = s.size
        while (a < b && KeyTrace.isAsciiSpace(s[a])) {
            a += 1
        }
        while (b > a && KeyTrace.isAsciiSpace(s[b - 1])) {
            b -= 1
        }
        return s[a..b]
    }

    private static func isAsciiSpace(c: Byte): Bool {
        let sp = 32u8      // 空格
        let tab = 9u8
        let cr = 13u8
        let lf = 10u8
        return c == sp || c == tab || c == cr || c == lf
    }

    /** 最后一个路径分隔符下标（兼容 `\` 的 Windows 路径）；无则 -1 */
    private static func lastSep(path: String): Int64 {
        var i = path.size - 1
        while (i >= 0) {
            let c = path[i]
            let slash = 47u8       // /
            let backslash = 92u8   // \
            if (c == slash || c == backslash) {
                return i
            }
            i -= 1
        }
        return -1
    }

    /** 落点父目录不存在则创建（失败忽略——appendLine 还有 CWD 回退兜底） */
    private static func ensureParentDir(path: String): Unit {
        let idx = KeyTrace.lastSep(path)
        if (idx <= 0) {
            return
        }
        let dir = path[0..idx]
        try {
            if (!exists(dir)) {
                Directory.create(dir, recursive: true)
            }
        } catch (e: Exception) {
            ()
        }
    }

    private static func stampUs(): Int64 {
        let now = DateTime.now()
        if (let Some(s) <- KeyTrace.start) {
            return (now - s).toMicroseconds()
        }
        KeyTrace.start = Some(now)
        return 0
    }

    /**
     * 开始本次运行的轨迹：以 `w` 打开（重置上次运行内容）写头行 —— 文件只保留
     * 最近一次运行，永不无界增长；落点不可写时回退进程当前目录并留痕。
     */
    private static func startRun(header: String): Unit {
        if (KeyTrace.writeLine(KeyTrace.filePath, header, true)) {
            return
        }
        if (KeyTrace.fallback) {
            return
        }
        KeyTrace.fallback = true
        let fallbackPath = "cjh_keys.log"
        if (KeyTrace.writeLine(fallbackPath, header, true)) {
            KeyTrace.writeLine(fallbackPath, "note: 无法写入 '${KeyTrace.filePath}'，已回退当前目录（可用 CJH_TRACE_FILE 指定绝对路径）", false)
            KeyTrace.filePath = fallbackPath
        }
    }

    /**
     * 追加写一行。每次事件独立 open/append/close：进程被强杀也不丢已写内容
     * （粘贴诊断需要完整尾部——丢尾就丢掉关键的那个 Enter）。落点不可写时
     * 回退进程当前目录并在文件内留痕，避免"什么都没记下"这种无法自证的失败。
     * 注：libc 字符串缓冲由 libc 管理，此处不显式 free（诊断路径，事件量级
     * 千条、单次运行即结束；换来的是无指针类型转换的简洁安全）。
     */
    private static func appendLine(line: String): Unit {
        if (KeyTrace.writeLine(KeyTrace.filePath, line, false)) {
            return
        }
        if (KeyTrace.fallback) {
            return
        }
        KeyTrace.fallback = true
        let fallbackPath = "cjh_keys.log"
        if (KeyTrace.writeLine(fallbackPath, line, false)) {
            KeyTrace.writeLine(fallbackPath, "note: 无法写入 '${KeyTrace.filePath}'，已回退当前目录（可用 CJH_TRACE_FILE 指定绝对路径）", false)
            KeyTrace.filePath = fallbackPath
        }
    }

    private static func writeLine(path: String, line: String, truncate: Bool): Bool {
        let mode = if (truncate) { "w" } else { "a" }
        unsafe {
            let fp = fopen(LibC.mallocCString(path), LibC.mallocCString(mode))
            if (fp.isNull()) {
                return false
            }
            fputs(LibC.mallocCString(line + "\n"), fp)
            fclose(fp)
            return true
        }
    }
}

@C
foreign func fopen(path: CString, mode: CString): CPointer<UInt8>

@C
foreign func fputs(s: CString, fp: CPointer<UInt8>): Int32

@C
foreign func fclose(fp: CPointer<UInt8>): Int32
