package cjutil

import std.net.*
import std.convert.*

/** 探活默认预算（毫秒）：覆盖远程 RTT + DNS，仍远小于系统级 connect 挂死时长 */
public const TCP_PROBE_TIMEOUT_MS: Int64 = 1500

/**
 * TCP 快速探活：探测 host:port 是否可建连（issue #14 的统一收口方案）
 *
 * 背景：stdx 的 ClientBuilder 没有 connectTimeout，TCP 建连阶段目标不可达时
 * 卡满系统级超时（Linux ~2s/次，丢包环境更久），应用层读超时管不到它。
 * 受影响路径：健康检查探活、MCP http 传输、web_search 远程 provider。
 *
 * 做法：用裸 TcpSocket 在预算内竞速建连（runWithBudget，模式同 cjllm http_transport），
 *   - true  → 端口可连（继续走正常 HTTP 请求）
 *   - false → 预算内未建连（不可达/拒绝/超时/DNS 失败），调用方快速判死或降级
 */
public func tcpFastProbe(host: String, port: UInt16, timeoutMs: Int64): Bool {
    try {
        return runWithBudget("TCP 探活", timeoutMs, 50, { => false }, { =>
            let sock = TcpSocket(host, port)
            sock.connect()
            try { sock.close() } catch (e: Exception) {}
            true
        })
    } catch (e: Exception) {
        return false  // 超预算 / 拒绝 / DNS 失败：统一快速判死
    }
}

/**
 * 从 URL 提取探活所需的 (host, port)；解析失败给 None（调用方跳过探活走原路径）
 * 例："https://example.com:8443/api" → ("example.com", 8443)
 *     "http://example.com/x"        → ("example.com", 80)
 */
public func parseHostPortFromUrl(url: String): ?(String, UInt16) {
    let lower = url.toAsciiLower()
    var start = 0
    var defaultPort: UInt16 = 80
    if (lower.startsWith("https://")) {
        start = 8
        defaultPort = 443
    } else if (lower.startsWith("http://")) {
        start = 7
    } else {
        return None
    }
    // authority = host[:port]，到 / ? # 或串尾
    let n = url.size
    var end = start
    while (end < n) {
        let c = Int64(UInt32(url.toRuneArray()[end]))
        if (c == 47 || c == 63 || c == 35) {  // / ? #
            break
        }
        end += 1
    }
    if (start >= end) {
        return None
    }
    let authority = url[start..end]

    // 端口段 = 最后一个冒号之后全为数字（兼容 IPv6 字面量的多个冒号）
    var hostPart = authority
    var port = defaultPort
    let idx = authority.lastIndexOf(":")
    if (idx.isSome()) {
        let i = idx.getOrThrow()
        let portStr = authority[(i + 1)..authority.size]
        var isDigits = portStr.size > 0
        for (r in portStr.toRuneArray()) {
            let c = Int64(UInt32(r))
            if (c < 48 || c > 57) {
                isDigits = false
                break
            }
        }
        if (isDigits) {
            let p = Int64.parse(portStr)
            if (p > 0 && p <= 65535) {
                port = UInt16(p)
                hostPart = authority[0..i]
            }
        }
    }
    // IPv6 字面量的 [] 包装去掉
    if (hostPart.size > 2 && hostPart.startsWith("[") && hostPart.endsWith("]")) {
        hostPart = hostPart[1..(hostPart.size - 1)]
    }
    if (hostPart == "") {
        return None
    }
    return Some((hostPart, port))
}

/**
 * 对 URL 目标做 TCP 快速探活（httpClientFetch / httpClientSseStream 统一入口）
 *   - URL 无法解析时返回 true（跳过探活，维持原行为）
 *   - loopback 目标跳过：本地拒绝（ECONNREFUSED）本就毫秒级即刻失败，
 *     探活只对"不可达挂死"的远程目标才有价值，还能省一次本地连接
 */
func fastProbeUrl(url: String): Bool {
    match (parseHostPortFromUrl(url)) {
        case Some((host, port)) =>
            if (host == "localhost" || host == "127.0.0.1" || host == "::1") {
                return true
            }
            return tcpFastProbe(host, port, TCP_PROBE_TIMEOUT_MS)
        case None => return true
    }
}
