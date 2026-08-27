package cjutil

/**
 * SSRF 防护（web_fetch 安全层）
 *
 * 多层独立拦截：
 *   1. 协议白名单：只收 http:// https://，拒绝 ftp/file/gopher/data 等
 *   2. 凭证拒绝：URL 带 user:pass@ 直接拒（防凭证透传内网）
 *   3. IP 段拦截：loopback / link-local / RFC1918 私有段 / unique-local / multicast 全拒
 *   4. DNS 解析校验：仓颉原生 std.net.IPAddress.resolve 解析主机名后判段
 *   5. 重定向重校：每跳都重过 SSRF 校验（由 web_fetch 调用方保证）
 *
 * 已知局限：DNS Rebinding TOCTOU——先解析校验 IP、再交连接时重解析，
 * 理论上存在攻击窗口。cjh 默认行为已挡住绝大多数注入。
 */

import std.net.*
import std.convert.Parsable
import std.collection.*

/**
 * SSRF 防护工具
 */
public class SsrfGuard {

    /**
     * 判断 IP 地址是否属于私有/保留段
     * @param ip IP 地址字符串（IPv4 或 IPv6）
     * @return true=私有/保留（应拒绝），false=公网（可放行）
     */
    public static func isPrivateIp(ip: String): Bool {
        // IPv4 判断
        if (ip.contains(".") && !ip.contains(":")) {
            return isPrivateIpv4(ip)
        }
        // IPv6 判断
        return isPrivateIpv6(ip)
    }

    /**
     * IPv4 私有/保留段判断
     */
    private static func isPrivateIpv4(ip: String): Bool {
        let parts = ip.split(".")
        if (parts.size != 4) { return true }  // 格式异常，保守拒绝

        let aOpt = parseIntSafe(parts[0])
        let bOpt = parseIntSafe(parts[1])
        if (aOpt == None || bOpt == None) { return true }
        let a = aOpt.getOrThrow()
        let b = bOpt.getOrThrow()

        // 0.0.0.0/8（本网络）
        if (a == 0) { return true }
        // 10.0.0.0/8（RFC1918 私有段）
        if (a == 10) { return true }
        // 127.0.0.0/8（loopback）
        if (a == 127) { return true }
        // 169.254.0.0/16（link-local + 云元数据 169.254.169.254）
        if (a == 169 && b == 254) { return true }
        // 172.16.0.0/12（RFC1918 私有段）
        if (a == 172 && b >= 16 && b <= 31) { return true }
        // 192.0.0.0/24（IETF 协议分配）
        if (a == 192 && b == 0) { return true }
        // 192.168.0.0/16（RFC1918 私有段）
        if (a == 192 && b == 168) { return true }
        // 198.18.0.0/15（基准测试）
        if (a == 198 && (b == 18 || b == 19)) { return true }
        // 198.51.100.0/24（TEST-NET-2）
        if (a == 198 && b == 51) { return true }
        // 203.0.113.0/24（TEST-NET-3）
        if (a == 203 && b == 0) { return true }
        // 224.0.0.0/4（multicast）
        if (a >= 224 && a <= 239) { return true }
        // 240.0.0.0/4（保留）
        if (a >= 240) { return true }

        return false
    }

    /**
     * IPv6 私有/保留段判断
     */
    private static func isPrivateIpv6(ip: String): Bool {
        let lower = ip.toAsciiLower()

        // ::1（loopback）
        if (lower == "::1") { return true }
        // ::（未指定地址）
        if (lower == "::") { return true }
        // fc00::/7（unique-local）
        if (lower.startsWith("fc") || lower.startsWith("fd")) { return true }
        // fe80::/10（link-local）
        if (lower.startsWith("fe8") || lower.startsWith("fe9") ||
            lower.startsWith("fea") || lower.startsWith("feb")) { return true }
        // ff00::/8（multicast）
        if (lower.startsWith("ff")) { return true }
        // ::ffff:0:0/96（IPv4-mapped IPv6，需检查内嵌的 IPv4）
        if (lower.contains("::ffff:")) {
            let idxOpt = lower.indexOf("::ffff:")
            if (let Some(idx) <- idxOpt) {
                if (idx + 7 < lower.size) {
                    let v4part = lower[idx + 7..]
                    if (v4part.contains(".")) {
                        return isPrivateIpv4(v4part)
                    }
                }
            }
        }

        return false
    }

    /**
     * 解析主机名获取所有 IP 地址字符串
     * 用仓颉原生 std.net.IPAddress.resolve
     * @param host 主机名（如 example.com 或 192.168.1.1）
     * @return IP 地址字符串列表（解析失败返回空列表）
     */
    public static func resolveHost(host: String): ArrayList<String> {
        let result = ArrayList<String>()

        // 如果 host 本身就是 IP，直接返回
        if (isIpAddress(host)) {
            result.add(host)
            return result
        }

        // 特殊主机名直接处理
        if (host == "localhost") {
            result.add("127.0.0.1")
            return result
        }

        // 仓颉原生 DNS 解析
        try {
            let addrs = IPAddress.resolve(host)
            for (i in 0..addrs.size) {
                result.add(addrs[i].toString())
            }
        } catch (e: Exception) {
            // 解析失败，返回空列表
        }

        return result
    }

    /**
     * 检查主机名解析出的所有 IP 是否都不属于私有/保留段
     * @param host 主机名
     * @return true=主机允许（所有 IP 都是公网），false=主机拒绝（有私有 IP 或解析失败）
     */
    public static func isHostAllowed(host: String): Bool {
        let addrs = resolveHost(host)
        if (addrs.size == 0) { return false }  // 解析失败，保守拒绝
        for (i in 0..addrs.size) {
            if (isPrivateIp(addrs[i])) { return false }
        }
        return true
    }

    /**
     * URL 校验入口（默认禁止内网）
     * @param url 待校验的 URL
     * @return true=URL 允许，false=URL 拒绝
     */
    public static func validateUrl(url: String): Bool {
        return validateUrlInternal(url, false)
    }

    /**
     * URL 校验入口（可配置是否允许内网）
     * @param url 待校验的 URL
     * @param allowInternal 是否允许内网地址（开发场景抓 localhost）
     * @return true=URL 允许，false=URL 拒绝
     */
    public static func validateUrl(url: String, allowInternal: Bool): Bool {
        return validateUrlInternal(url, allowInternal)
    }

    /**
     * URL 校验内部实现
     */
    private static func validateUrlInternal(url: String, allowInternal: Bool): Bool {
        // 1. URL 长度上限（防数据外泄通道）
        if (url.size > 8192) { return false }

        // 2. 协议白名单
        if (!url.startsWith("http://") && !url.startsWith("https://")) { return false }

        // 3. 凭证拒绝：URL 带 user:pass@ 直接拒
        //    格式：scheme://user:pass@host/path
        let schemeIdxOpt = url.indexOf("://")
        if (let Some(schemeIdx) <- schemeIdxOpt) {
            let afterScheme = url[schemeIdx + 3..]
            let atIdxOpt = afterScheme.indexOf("@")
            let slashIdxOpt = afterScheme.indexOf("/")
            if (let Some(atIdx) <- atIdxOpt) {
                let slashBeforeAt = match (slashIdxOpt) {
                    case Some(s) => atIdx < s
                    case None => true
                }
                if (slashBeforeAt) {
                    return false  // user:pass@ 在 authority 部分
                }
            }
        } else {
            return false
        }
        let schemeIdx = schemeIdxOpt.getOrThrow()

        // 4. 提取主机名
        let host = extractHost(url)
        if (host.size == 0) { return false }

        // 5. 如果是 IP 字面量，直接判段
        if (isIpAddress(host)) {
            if (isPrivateIp(host)) {
                if (allowInternal && isLoopback(host)) { return true }
                return false
            }
            return true
        }

        // 6. localhost 特殊处理
        if (host == "localhost") {
            return allowInternal
        }

        // 7. DNS 解析校验
        let addrs = resolveHost(host)
        if (addrs.size == 0) { return false }  // 解析失败，拒绝
        for (i in 0..addrs.size) {
            if (isPrivateIp(addrs[i])) {
                if (allowInternal && isLoopback(addrs[i])) { continue }
                return false
            }
        }

        return true
    }

    /**
     * 从 URL 提取主机名
     * 支持格式：http://host:port/path、https://host/path、http://host
     */
    public static func extractHost(url: String): String {
        // 找到 scheme://
        let schemeEndOpt = url.indexOf("://")
        let schemeEnd = match (schemeEndOpt) {
            case Some(e) => e
            case None => return ""
        }

        var rest = url[schemeEnd + 3..]

        // 去掉 user:pass@ 部分
        let atIdxOpt = rest.indexOf("@")
        if (let Some(atIdx) <- atIdxOpt) {
            let slashIdxOpt = rest.indexOf("/")
            let slashBeforeAt = match (slashIdxOpt) {
                case Some(s) => atIdx < s
                case None => true
            }
            if (slashBeforeAt) {
                rest = rest[atIdx + 1..]
            }
        }

        // 去掉 path 部分
        let slashIdxOpt = rest.indexOf("/")
        if (let Some(slashIdx) <- slashIdxOpt) {
            rest = rest[0..slashIdx]
        }

        // 去掉 port 部分
        let colonIdxOpt = rest.indexOf(":")
        if (let Some(colonIdx) <- colonIdxOpt) {
            rest = rest[0..colonIdx]
        }

        return rest
    }

    /**
     * 判断字符串是否是 IP 地址格式
     */
    public static func isIpAddress(s: String): Bool {
        // IPv4: x.x.x.x
        if (s.contains(".") && !s.contains(":")) {
            let parts = s.split(".")
            if (parts.size != 4) { return false }
            for (i in 0..parts.size) {
                let nOpt = parseIntSafe(parts[i])
                if (nOpt == None) { return false }
                let n = nOpt.getOrThrow()
                if (n < 0 || n > 255) { return false }
            }
            return true
        }
        // IPv6: 包含 :
        if (s.contains(":")) { return true }
        return false
    }

    /**
     * 判断 IP 是否是 loopback
     */
    public static func isLoopback(ip: String): Bool {
        if (ip.startsWith("127.")) { return true }
        if (ip == "::1") { return true }
        if (ip == "localhost") { return true }
        return false
    }

    /**
     * 安全解析整数，失败返回 None
     */
    private static func parseIntSafe(s: String): ?Int64 {
        try {
            return Int64.parse(s)
        } catch (e: Exception) {
            return None
        }
    }
}
