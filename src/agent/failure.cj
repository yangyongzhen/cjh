package cjh.agent

import cjutil.*

/**
 * 上游失败分类（让"回合失败"有结构化出口）
 *
 * 背景：请求阶段的异常原本只被吞成 `summary.reply`，渠道看到的是"正常返回"，
 * 于是只发一个 done(stop)——客户端既拿不到 code，也分不清"没输出"和"说完了"。
 *
 * 分类原则是**面向客户端决策**，不是复刻上游错误码：
 * - 重试有意义（网络抖动 / 限流 / 5xx）→ retryable=true
 * - 重试没用（鉴权失败 / 4xx 参数错）→ retryable=false
 * 鉴权类刻意不回显上游原文：错误体常回显 api_key，进了帧就等于泄漏到客户端与日志里。
 */
public class FailureInfo {
    public let code: String        // 客户端据此选提示文案与"重试"按钮
    public let message: String     // 人能读的说明（不含密钥）
    public let retryable: Bool     // 原样重试是否有意义

    public init(code: String, message: String, retryable: Bool) {
        this.code = code
        this.message = message
        this.retryable = retryable
    }
}

/**
 * 上游原文摘要：一行化 + UTF-8 安全截断
 *
 * 够定位问题（URL、状态码），又不至于把整段响应体塞进帧里。
 */
func failureSnippet(raw: String): String {
    let oneLine = raw.replace("\n", " ").replace("\r", " ")
    return truncateUtf8(oneLine, 200)
}

/**
 * 网络 / 传输类失败关键词
 *
 * 含中文文案：cjllm 传输层会抛「连接关闭（读响应头 EOF）」这类中文消息，
 * 只匹配英文关键词会漏判到 provider_error。
 */
func isUnreachableText(text: String): Bool {
    let keys = ["connect", "connection", "refused", "reset", "unreachable", "no route",
        "timed out", "timeout", "超时", "连接", "拒绝", "eof", "broken pipe",
        "dns", "resolve", "handshake", "tls", "socket", "证书"]
    for (k in keys) {
        if (text.contains(k)) {
            return true
        }
    }
    return false
}

/**
 * 把上游异常文案分类成客户端可用的错误码
 *
 * 错误码：
 * - provider_auth_error   鉴权被拒（密钥无效 / 无权限）→ 重试无用
 * - provider_rate_limited 限流 / 配额用尽 → 稍后重试
 * - provider_unreachable  连不上或连接中断（base_url 写错、服务没起、网络不通）→ 可重试
 * - provider_error        其余上游错误（HTTP 状态、响应解析失败等）→ 按 4xx/5xx 判可重试性
 *
 * 注意：状态码只认 "http 4xx/5xx" 这种带前缀的形式——裸数字会把
 * "无法连接到 127.0.0.1:9401" 里的 "401" 误判成鉴权失败。
 */
public func classifyProviderFailure(raw: String): FailureInfo {
    let text = raw.toAsciiLower()

    // 鉴权优先于其它分支：401/403 同样匹配 "http 4"，不先判会被吞成 provider_error
    if (text.contains("http 401") || text.contains("http 403") ||
        text.contains("unauthorized") || text.contains("forbidden") ||
        text.contains("invalid api key") || text.contains("invalid_api_key")) {
        return FailureInfo("provider_auth_error",
            "服务商拒绝鉴权：API 密钥无效或无权限，请检查模型配置", false)
    }
    if (text.contains("http 429") || text.contains("rate limit") ||
        text.contains("too many requests") || text.contains("quota")) {
        return FailureInfo("provider_rate_limited",
            "服务商限流或配额用尽，请稍后重试（${failureSnippet(raw)}）", true)
    }
    if (isUnreachableText(text)) {
        return FailureInfo("provider_unreachable",
            "无法连接服务商端点，请检查 base_url 与网络（${failureSnippet(raw)}）", true)
    }
    if (text.contains("http 4")) {
        return FailureInfo("provider_error",
            "服务商拒绝了本次请求（${failureSnippet(raw)}）", false)
    }
    if (text.contains("http 5")) {
        return FailureInfo("provider_error",
            "服务商内部错误，可重试（${failureSnippet(raw)}）", true)
    }
    return FailureInfo("provider_error", "服务商调用失败（${failureSnippet(raw)}）", true)
}
