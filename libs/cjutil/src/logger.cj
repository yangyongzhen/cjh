package cjutil

import std.fs.*
import std.time.*
import std.sync.*
import std.env.*
import stdx.log.*
import stdx.logger.*

/**
 * cjh 全局日志模块
 *
 * 双文件设计：
 * - ~/.cjh/logs/error.log — 只记 ERROR/FATAL（聚焦排查问题）
 * - ~/.cjh/logs/cjh.log   — 应用级日志，记录所有级别（WARN/INFO/DEBUG + ERROR/FATAL 冗余记录）
 *
 * 级别策略（可配置，CJH_LOG_LEVEL 环境变量）：
 * - FATAL > ERROR > WARN > INFO > DEBUG
 * - 默认 WARN：WARN 及以上写入 cjh.log，ERROR/FATAL 另写入 error.log
 * - 设 CJH_LOG_LEVEL=DEBUG 记录所有级别
 * - 设 CJH_LOG_LEVEL=ERROR 只记 ERROR/FATAL
 *
 * 用法（简短，易替换）：
 *   Log.error("UTF-8 解码失败: ${e}")   // → error.log + cjh.log
 *   Log.fatal("启动失败: ${e}")         // → error.log + cjh.log
 *   Log.warn("SSE 空闲超时")            // → cjh.log
 *   Log.info("会话已保存: ${id}")       // → cjh.log (CJH_LOG_LEVEL ≤ INFO)
 *   Log.debug("进入 Agent.run")         // → cjh.log (CJH_LOG_LEVEL=DEBUG)
 */
public class Log {
    private static var initialized: Bool = false
    // errorLogger: 只记 ERROR/FATAL → ~/.cjh/logs/error.log
    private static var errorLogger: Logger = NoopLogger()
    // appLogger: 记录所有级别（由 level 过滤）→ ~/.cjh/logs/cjh.log
    private static var appLogger: Logger = NoopLogger()
    private static let lock: ReentrantMutex = ReentrantMutex()

    /**
     * 默认日志目录：~/.cjh/logs/
     * /tmp 重启会清空，不满足"永久记录"需求；~/.cjh/logs/ 持久化
     */
    private static func defaultLogDir(): String {
        let home = getVariable("HOME") ?? "."
        return "${home}/.cjh/logs"
    }

    /**
     * 解析 CJH_LOG_LEVEL 环境变量为 LogLevel
     * 默认 WARN（WARN 及以上写入 cjh.log，ERROR/FATAL 另写入 error.log）
     */
    private static func resolveLogLevel(): LogLevel {
        match ((getVariable("CJH_LOG_LEVEL") ?? "WARN").toAsciiLower()) {
            case "fatal" => LogLevel.FATAL
            case "error" => LogLevel.ERROR
            case "warn" => LogLevel.WARN
            case "info" => LogLevel.INFO
            case "debug" => LogLevel.DEBUG
            case _ => LogLevel.WARN  // 未知值降级到 WARN
        }
    }

    /**
     * 初始化日志文件（线程安全，幂等）
     * - errorLogger: level=ERROR，只记 ERROR/FATAL → error.log
     * - appLogger: level=resolveLogLevel()，记所有通过过滤的级别 → cjh.log
     */
    public static func ensureInit(): Unit {
        if (initialized) {
            return
        }
        lock.lock()
        if (initialized) {
            lock.unlock()
            return
        }
        let logDir = getVariable("CJH_LOG_DIR") ?? defaultLogDir()
        let level = resolveLogLevel()
        // 确保日志目录存在（~/.cjh/logs/）
        try {
            if (!exists(logDir)) {
                Directory.create(logDir, recursive: true)
            }
        } catch (e: Exception) {
            // 目录创建失败，降级到 /tmp
            let errFallback = "/tmp/cjh_error.log"
            let appFallback = "/tmp/cjh.log"
            try {
                let ef = File(errFallback, OpenMode.Append)
                let el = TextLogger(ef)
                el.level = LogLevel.ERROR
                errorLogger = el
            } catch (e2: Exception) {
                errorLogger = NoopLogger()
            }
            try {
                let af = File(appFallback, OpenMode.Append)
                let al = TextLogger(af)
                al.level = level
                appLogger = al
            } catch (e2: Exception) {
                appLogger = NoopLogger()
            }
            initialized = true
            lock.unlock()
            return
        }
        // errorLogger: 只记 ERROR/FATAL → error.log
        let errorPath = getVariable("CJH_ERROR_LOG") ?? "${logDir}/error.log"
        try {
            let f = File(errorPath, OpenMode.Append)
            let el = TextLogger(f)
            el.level = LogLevel.ERROR
            errorLogger = el
        } catch (e: Exception) {
            errorLogger = NoopLogger()
        }
        // appLogger: 记录所有级别（由 level 过滤）→ cjh.log
        let appPath = getVariable("CJH_APP_LOG") ?? "${logDir}/cjh.log"
        try {
            let f = File(appPath, OpenMode.Append)
            let al = TextLogger(f)
            al.level = level
            appLogger = al
        } catch (e: Exception) {
            appLogger = NoopLogger()
        }
        initialized = true
        lock.unlock()
    }

    /**
     * FATAL 级别日志
     * → error.log + cjh.log
     */
    public static func fatal(msg: String): Unit {
        ensureInit()
        let formatted = format("FATAL", msg)
        errorLogger.fatal(formatted)
        appLogger.fatal(formatted)
    }

    /**
     * FATAL 级别日志，附带异常堆栈
     * 堆栈含 fileName:lineNumber @ functionName，便于定位异常源头
     * → error.log + cjh.log
     */
    public static func fatal(msg: String, e: Exception): Unit {
        ensureInit()
        let formatted = format("FATAL", msg + "\n" + stackTraceOf(e))
        errorLogger.fatal(formatted)
        appLogger.fatal(formatted)
    }

    /**
     * ERROR 级别日志
     * → error.log + cjh.log
     */
    public static func error(msg: String): Unit {
        ensureInit()
        let formatted = format("ERROR", msg)
        errorLogger.error(formatted)
        appLogger.error(formatted)
    }

    /**
     * ERROR 级别日志，附带异常堆栈
     * → error.log + cjh.log
     */
    public static func error(msg: String, e: Exception): Unit {
        ensureInit()
        let formatted = format("ERROR", msg + "\n" + stackTraceOf(e))
        errorLogger.error(formatted)
        appLogger.error(formatted)
    }

    /**
     * WARN 级别日志
     * → cjh.log（CJH_LOG_LEVEL ≤ WARN 时写入）
     */
    public static func warn(msg: String): Unit {
        ensureInit()
        appLogger.warn(format("WARN", msg))
    }

    /**
     * INFO 级别日志
     * → cjh.log（CJH_LOG_LEVEL ≤ INFO 时写入）
     */
    public static func info(msg: String): Unit {
        ensureInit()
        appLogger.info(format("INFO", msg))
    }

    /**
     * DEBUG 级别日志
     * → cjh.log（CJH_LOG_LEVEL=DEBUG 时写入）
     */
    public static func debug(msg: String): Unit {
        ensureInit()
        appLogger.debug(format("DEBUG", msg))
    }

    /**
     * 格式化日志：时间戳 + 级别 + 消息
     */
    private static func format(level: String, msg: String): String {
        let now = DateTime.now()
        return "[${now}] [${level}] ${msg}"
    }

    /**
     * 从路径提取父目录（最后一个 / 之前的部分）
     * 例："/root/.cjh/logs/error.log" → "/root/.cjh/logs"
     */
    private static func parentDir(path: String): String {
        var i = path.size - 1
        while (i >= 0) {
            if (path[i] == UInt8(47)) {  // '/'
                return path[0..i]
            }
            i -= 1
        }
        return ""
    }

    /**
     * 提取异常堆栈：fileName:lineNumber @ functionName 逐行拼接
     * 仓颉 Exception.getStackTrace() 返回 Array<StackTraceElement>，
     * 每个元素含 declaringClass/fileName/lineNumber/functionName 字段
     */
    private static func stackTraceOf(e: Exception): String {
        var sb = StringBuilder()
        sb.append("Exception: ${e}\n")
        let frames = e.getStackTrace()
        if (frames.size == 0) {
            sb.append("(no stack trace)")
            return sb.toString()
        }
        var i = 0
        while (i < frames.size && i < 20) {  // 最多 20 帧，避免日志过长
            let f = frames[i]
            sb.append("  at ${f.fileName}:${f.lineNumber} @ ${f.declaringClass}\n")
            i += 1
        }
        if (frames.size > 20) {
            sb.append("  ... ${frames.size - 20} more frames\n")
        }
        return sb.toString()
    }
}
