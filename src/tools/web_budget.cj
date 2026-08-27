package cjh.tools

/**
 * 会话级 web 工具预算（防 prompt injection 烧流量）
 *
 * Agent 可能被恶意网页内容诱导，疯狂抓站烧流量/烧 API key。
 * 本计数器在会话级别追踪：
 *   - web_fetch 调用次数 + 下载字节总数
 *   - web_search 调用次数
 * 超出预设上限时拒绝后续调用。
 *
 * 线程安全：用 ReentrantMutex 保护，因为 V2d 并发引擎可能
 * 并发调用 web_fetch / web_search。
 */

import std.sync.*
import std.collection.*

public class WebBudget {
    // 预算上限（0 = 不限制）
    public let maxFetches: Int64       // 默认 20
    public let maxSearches: Int64     // 默认 30
    public let maxFetchBytes: Int64   // 默认 1MB = 1048576

    // 当前计数
    private var fetchCount: Int64 = 0
    private var searchCount: Int64 = 0
    private var fetchBytes: Int64 = 0

    private let lock: ReentrantMutex = ReentrantMutex()

    public init(maxFetches: Int64, maxSearches: Int64, maxFetchBytes: Int64) {
        this.maxFetches = maxFetches
        this.maxSearches = maxSearches
        this.maxFetchBytes = maxFetchBytes
    }

    /**
     * 尝试记录一次 fetch 调用
     * @param bytes  本次下载的字节数（预估）
     * @return Some(true) 允许；None 超出预算（含拒绝原因）
     */
    public func tryFetch(bytes: Int64): ?String {
        lock.lock()
        try {
            if (maxFetches > 0 && fetchCount >= maxFetches) {
                return Some("web_fetch budget exceeded: ${fetchCount}/${maxFetches} fetches used")
            }
            if (maxFetchBytes > 0 && fetchBytes + bytes > maxFetchBytes) {
                return Some("web_fetch byte budget exceeded: ${fetchBytes}/${maxFetchBytes} bytes used")
            }
            fetchCount += 1
            fetchBytes += bytes
            return None
        } finally {
            lock.unlock()
        }
    }

    /**
     * 尝试记录一次 search 调用
     * @return None 允许；Some(reason) 超出预算
     */
    public func trySearch(): ?String {
        lock.lock()
        try {
            if (maxSearches > 0 && searchCount >= maxSearches) {
                return Some("web_search budget exceeded: ${searchCount}/${maxSearches} searches used")
            }
            searchCount += 1
            return None
        } finally {
            lock.unlock()
        }
    }

    /**
     * 获取当前预算使用情况（用于诊断/日志）
     */
    public func stats(): String {
        lock.lock()
        try {
            return "fetches=${fetchCount}/${maxFetches}, bytes=${fetchBytes}/${maxFetchBytes}, searches=${searchCount}/${maxSearches}"
        } finally {
            lock.unlock()
        }
    }
}
