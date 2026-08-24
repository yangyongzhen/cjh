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
 * 设计原则（对齐六大原则）：
 * - 单一职责：只管日志输出，不管业务逻辑
 * - 开闭：通过 level 控制输出，不改代码
 * - 依赖倒置：依赖 Logger 抽象，不依赖具体实现
 *
 * 级别策略：
 * - FATAL/ERROR：永久写文件（/tmp/cjh_error.log 或 CJH_ERROR_LOG 覆盖）
 * - WARN/INFO/DEBUG：CJH_DEBUG=1 时写文件
 *
 * 用法（简短，易替换）：
 *   Log.error("UTF-8 解码失败: ${e}")   // 永久记录
 *   Log.fatal("启动失败: ${e}")         // 永久记录
 *   Log.info("会话已保存: ${id}")       // 可控
 */
public class Log {
    private static var initialized: Bool = false
    private static var errorLogger: Logger = NoopLogger()
    private static var debugLogger: Logger = NoopLogger()
    private static let lock: ReentrantMutex = ReentrantMutex()

    /**
     * 初始化日志文件（线程安全，幂等）
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
        // error/fatal 永久写文件
        let errorPath = getVariable("CJH_ERROR_LOG") ?? "/tmp/cjh_error.log"
        try {
            let f = File(errorPath, OpenMode.Append)
            let el = TextLogger(f)
            el.level = LogLevel.ERROR
            errorLogger = el
        } catch (e: Exception) {
            errorLogger = NoopLogger()
        }
        // debug/info 可控（CJH_DEBUG=1 开启）
        if ((getVariable("CJH_DEBUG") ?? "") == "1") {
            let debugPath = getVariable("CJH_DEBUG_LOG") ?? "/tmp/cjh_debug.log"
            try {
                let f = File(debugPath, OpenMode.Append)
                let dl = TextLogger(f)
                dl.level = LogLevel.DEBUG
                debugLogger = dl
            } catch (e: Exception) {
                debugLogger = NoopLogger()
            }
        }
        initialized = true
        lock.unlock()
    }

    /**
     * FATAL 级别日志（永久写文件）
     */
    public static func fatal(msg: String): Unit {
        ensureInit()
        errorLogger.fatal(format("FATAL", msg))
    }

    /**
     * FATAL 级别日志，附带异常堆栈（永久写文件）
     * 堆栈含 fileName:lineNumber @ functionName，便于定位异常源头
     */
    public static func fatal(msg: String, e: Exception): Unit {
        ensureInit()
        errorLogger.fatal(format("FATAL", msg + "\n" + stackTraceOf(e)))
    }

    /**
     * ERROR 级别日志（永久写文件）
     */
    public static func error(msg: String): Unit {
        ensureInit()
        errorLogger.error(format("ERROR", msg))
    }

    /**
     * ERROR 级别日志，附带异常堆栈（永久写文件）
     */
    public static func error(msg: String, e: Exception): Unit {
        ensureInit()
        errorLogger.error(format("ERROR", msg + "\n" + stackTraceOf(e)))
    }

    /**
     * WARN 级别日志（CJH_DEBUG=1 时写文件）
     */
    public static func warn(msg: String): Unit {
        ensureInit()
        debugLogger.warn(format("WARN", msg))
    }

    /**
     * INFO 级别日志（CJH_DEBUG=1 时写文件）
     */
    public static func info(msg: String): Unit {
        ensureInit()
        debugLogger.info(format("INFO", msg))
    }

    /**
     * DEBUG 级别日志（CJH_DEBUG=1 时写文件）
     */
    public static func debug(msg: String): Unit {
        ensureInit()
        debugLogger.debug(format("DEBUG", msg))
    }

    /**
     * 格式化日志：时间戳 + 级别 + 消息
     */
    private static func format(level: String, msg: String): String {
        let now = DateTime.now()
        return "[${now}] [${level}] ${msg}"
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
