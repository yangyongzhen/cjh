package cjlog

import std.fs.*
import std.time.*
import std.sync.*
import std.env.*
import std.collection.*

/**
 * cjlog：仓颉异步日志库（参考 g3log 设计）
 *
 * 核心设计：
 * - 内存队列：所有日志调用往队列推消息，立即返回（非阻塞）
 * - 后台刷盘：spawn 协程循环取队列 → 批量写文件
 * - 双文件：error.log（ERROR/FATAL）+ cjh.log（全级别）
 * - 可配置级别：CJH_LOG_LEVEL 控制（默认 WARN）
 *
 * 性能优势（对标 g3log）：
 * - 业务线程只做一次入队操作（无 I/O 阻塞）
 * - 后台协程批量写文件，减少 syscall 次数
 * - ReentrantMutex 保护队列，轮询 + sleep 唤醒
 *
 * 用法：
 *   Log.error("UTF-8 解码失败: ${e}")   // → error.log + cjh.log
 *   Log.fatal("启动失败: ${e}")         // → error.log + cjh.log
 *   Log.warn("SSE 空闲超时")            // → cjh.log
 *   Log.info("会话已保存: ${id}")       // → cjh.log (CJH_LOG_LEVEL ≤ INFO)
 *   Log.debug("进入 Agent.run")         // → cjh.log (CJH_LOG_LEVEL=DEBUG)
 */
public class Log {
    private static var initialized: Bool = false
    private static var sink: LogSinkImpl = NoopSink()
    private static let lock: ReentrantMutex = ReentrantMutex()

    /**
     * 初始化日志系统（线程安全，幂等）
     * 启动后台 sink 协程
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
        sink = LogSink()
        sink.start()
        initialized = true
        lock.unlock()
    }

    /**
     * 关闭日志系统：flush 剩余消息，停止 sink 协程
     * 应在程序退出前调用
     */
    public static func shutdown(): Unit {
        lock.lock()
        if (initialized) {
            sink.stop()
            initialized = false
        }
        lock.unlock()
    }

    /**
     * FATAL 级别日志
     * → error.log + cjh.log
     */
    public static func fatal(msg: String): Unit {
        ensureInit()
        sink.enqueue("FATAL", msg, true)
    }

    /**
     * FATAL 级别日志，附带异常堆栈
     * → error.log + cjh.log
     */
    public static func fatal(msg: String, e: Exception): Unit {
        ensureInit()
        sink.enqueue("FATAL", msg + "\n" + stackTraceOf(e), true)
    }

    /**
     * ERROR 级别日志
     * → error.log + cjh.log
     */
    public static func error(msg: String): Unit {
        ensureInit()
        sink.enqueue("ERROR", msg, true)
    }

    /**
     * ERROR 级别日志，附带异常堆栈
     * → error.log + cjh.log
     */
    public static func error(msg: String, e: Exception): Unit {
        ensureInit()
        sink.enqueue("ERROR", msg + "\n" + stackTraceOf(e), true)
    }

    /**
     * WARN 级别日志
     * → cjh.log（CJH_LOG_LEVEL ≤ WARN 时写入）
     */
    public static func warn(msg: String): Unit {
        ensureInit()
        sink.enqueue("WARN", msg, false)
    }

    /**
     * INFO 级别日志
     * → cjh.log（CJH_LOG_LEVEL ≤ INFO 时写入）
     */
    public static func info(msg: String): Unit {
        ensureInit()
        sink.enqueue("INFO", msg, false)
    }

    /**
     * DEBUG 级别日志
     * → cjh.log（CJH_LOG_LEVEL=DEBUG 时写入）
     */
    public static func debug(msg: String): Unit {
        ensureInit()
        sink.enqueue("DEBUG", msg, false)
    }

    /**
     * 提取异常堆栈：fileName:lineNumber @ functionName 逐行拼接
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
        while (i < frames.size && i < 20) {
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

/**
 * 日志条目（入队消息）
 */
internal struct LogEntry {
    let level: String       // "FATAL"/"ERROR"/"WARN"/"INFO"/"DEBUG"
    let formatted: String   // 已格式化的完整消息（含时间戳）
    let isError: Bool       // true=ERROR/FATAL，需写入 error.log
    public init(level: String, formatted: String, isError: Bool) {
        this.level = level
        this.formatted = formatted
        this.isError = isError
    }
}

/**
 * 日志接收器接口
 */
internal interface LogSinkImpl {
    func start(): Unit
    func stop(): Unit
    func enqueue(level: String, msg: String, isError: Bool): Unit
}

/**
 * NoopSink：空实现（初始化失败时降级）
 */
internal class NoopSink <: LogSinkImpl {
    public func start(): Unit {}
    public func stop(): Unit {}
    public func enqueue(level: String, msg: String, isError: Bool): Unit {}
}

/**
 * LogSink：异步日志接收器（参考 g3log sink 设计）
 *
 * 工作流程：
 * 1. 业务线程调用 enqueue()，往 queue 推 LogEntry，立即返回
 * 2. 后台 sink 协程循环：取 queue → 写文件
 * 3. stop() 时：设置 running=false，唤醒 sink 协程，等它处理完剩余消息
 *
 * 双文件路由：
 * - isError=true → 写 error.log + cjh.log
 * - isError=false → 只写 cjh.log（按 level 过滤）
 */
internal class LogSink <: LogSinkImpl {
    private let queue: ArrayList<LogEntry> = ArrayList<LogEntry>()
    private let queueLock: ReentrantMutex = ReentrantMutex()
    private var running: Bool = false

    // 日志级别过滤（appLogger 用）
    private let appLevel: Int64

    // 文件路径
    private let logDir: String
    private let errorPath: String
    private let appPath: String

    // 文件句柄（后台线程持有）
    private var errorFile: ?File = None
    private var appFile: ?File = None

    public init() {
        this.logDir = getVariable("CJH_LOG_DIR") ?? defaultLogDir()
        this.appLevel = resolveLogLevelNum()
        this.errorPath = getVariable("CJH_ERROR_LOG") ?? "${logDir}/error.log"
        this.appPath = getVariable("CJH_APP_LOG") ?? "${logDir}/cjh.log"
    }

    /**
     * 启动后台 sink 协程
     */
    public func start(): Unit {
        // 确保日志目录存在
        try {
            if (!exists(logDir)) {
                Directory.create(logDir, recursive: true)
            }
        } catch (e: Exception) {
            // 目录创建失败，降级到 NoopSink
            return
        }
        // 打开文件句柄
        try {
            errorFile = File(errorPath, OpenMode.Append)
        } catch (e: Exception) {
            errorFile = None
        }
        try {
            appFile = File(appPath, OpenMode.Append)
        } catch (e: Exception) {
            appFile = None
        }
        // 启动 sink 协程
        running = true
        spawn {
            this.sinkLoop()
        }
    }

    /**
     * 停止 sink 协程：flush 剩余消息
     */
    public func stop(): Unit {
        running = false
        // flush 剩余消息
        this.flushAll()
        // 关闭文件句柄
        match (errorFile) {
            case Some(f) => try { f.close() } catch (e: Exception) {}
            case None => ()
        }
        match (appFile) {
            case Some(f) => try { f.close() } catch (e: Exception) {}
            case None => ()
        }
    }

    /**
     * 入队日志消息（业务线程调用，非阻塞）
     */
    public func enqueue(level: String, msg: String, isError: Bool): Unit {
        let formatted = formatEntry(level, msg)
        let entry = LogEntry(level, formatted, isError)
        queueLock.lock()
        queue.add(entry)
        queueLock.unlock()
    }

    /**
     * 后台 sink 协程主循环
     */
    private func sinkLoop(): Unit {
        while (running) {
            // 取出所有待处理消息
            var batch = ArrayList<LogEntry>()
            queueLock.lock()
            if (queue.size > 0) {
                for (entry in queue) {
                    batch.add(entry)
                }
                queue.clear()
            }
            queueLock.unlock()
            // 批量写文件
            if (batch.size > 0) {
                this.flushBatch(batch)
            } else {
                // 队列空，sleep 50ms 减少轮询
                sleepMs(50)
            }
        }
    }

    /**
     * flush 所有剩余消息（stop 时调用）
     */
    private func flushAll(): Unit {
        var batch = ArrayList<LogEntry>()
        queueLock.lock()
        if (queue.size > 0) {
            for (entry in queue) {
                batch.add(entry)
            }
            queue.clear()
        }
        queueLock.unlock()
        if (batch.size > 0) {
            this.flushBatch(batch)
        }
    }

    /**
     * 批量刷盘
     */
    private func flushBatch(batch: ArrayList<LogEntry>): Unit {
        var errorBuf = StringBuilder()
        var appBuf = StringBuilder()
        for (entry in batch) {
            let line = entry.formatted + "\n"
            if (entry.isError) {
                errorBuf.append(line)
                appBuf.append(line)
            } else {
                // 按 level 过滤
                if (shouldLog(entry.level)) {
                    appBuf.append(line)
                }
            }
        }
        // 写 error.log
        if (errorBuf.size > 0) {
            match (errorFile) {
                case Some(f) => try { f.write(errorBuf.toString().toArray()) } catch (e: Exception) {}
                case None => ()
            }
        }
        // 写 cjh.log
        if (appBuf.size > 0) {
            match (appFile) {
                case Some(f) => try { f.write(appBuf.toString().toArray()) } catch (e: Exception) {}
                case None => ()
            }
        }
    }

    /**
     * 按 appLevel 过滤：level 数值 <= appLevel 才记录
     * FATAL=0, ERROR=1, WARN=2, INFO=3, DEBUG=4
     */
    private func shouldLog(level: String): Bool {
        let entryLevel = parseLevelNum(level)
        return entryLevel <= appLevel
    }

    /**
     * 格式化日志条目
     */
    private func formatEntry(level: String, msg: String): String {
        let now = DateTime.now()
        return "[${now}] [${level}] ${msg}"
    }

    /**
     * sleep 毫秒（轮询节流）
     */
    private func sleepMs(ms: Int64): Unit {
        var i: Int64 = 0
        while (i < ms * 1000) {
            i += 1000
        }
    }

    /**
     * 解析级别字符串为数值
     * FATAL=0, ERROR=1, WARN=2, INFO=3, DEBUG=4
     */
    private func parseLevelNum(level: String): Int64 {
        match (level) {
            case "FATAL" => 0
            case "ERROR" => 1
            case "WARN" => 2
            case "INFO" => 3
            case "DEBUG" => 4
            case _ => 4
        }
    }

    /**
     * 默认日志目录：~/.cjh/logs/
     */
    private static func defaultLogDir(): String {
        // 跨平台主目录：Windows USERPROFILE（无 HOME）→ POSIX HOME → 当前目录
        let up = getVariable("USERPROFILE")
        var home = "."
        if (up.isSome() && up.getOrThrow().size > 0) {
            home = up.getOrThrow()
        } else {
            home = getVariable("HOME") ?? "."
        }
        return "${home}/.cjh/logs"
    }

    /**
     * 解析 CJH_LOG_LEVEL 环境变量为数值
     * 默认 WARN（2）
     */
    private static func resolveLogLevelNum(): Int64 {
        match ((getVariable("CJH_LOG_LEVEL") ?? "WARN").toAsciiLower()) {
            case "fatal" => 0
            case "error" => 1
            case "warn" => 2
            case "info" => 3
            case "debug" => 4
            case _ => 2  // 未知值降级到 WARN
        }
    }
}
