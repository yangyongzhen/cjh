package cjh

import std.collection.*
import std.console.*
import std.env.*
import std.fs.*
import std.convert.Parsable
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjh.agent.*
import cjh.tools.*
import cjllm.*
import cjh.tui.*
import cjh.web.*
import cjterm.*
import cjcfg.*
import cjutil.*
import stdx.log.*


/**
 * 由配置生成 LLM provider（业务装配，不属于 cjcfg 通用库）
 * 提供商选择：
 *   - CJH_PROVIDER=ollama 或 base_url 含 localhost/127.0.0.1 → OllamaProvider（本地模型，apiKey 可空）
 *   - CJH_PROVIDER=anthropic → AnthropicProvider
 *   - 默认 → OpenAiProvider（OpenAI/DeepSeek/通义 等兼容协议）
 */
func makeProvider(cfg: CjhConfig): LlmProvider {
    // provider 选择：显式 CJH_PROVIDER=anthropic 才用 Anthropic
    // （auth.json 的 key 优先；env 变量可覆盖。绝不自动劫持到 Anthropic）
    let providerName = readEnv("CJH_PROVIDER") ?? ""
    // Ollama 本地模型：CJH_PROVIDER=ollama 或 base_url 指向 localhost/127.0.0.1
    let isOllama = (providerName == "ollama") ||
        cfg.baseUrl.contains("localhost") || cfg.baseUrl.contains("127.0.0.1")
    // Ollama 本地服务无需认证，apiKey 可空；其他 provider 无 key 时
    // 不阻断启动（TUI/Web 可进入，发消息时请求自然失败提示），仅告警
    if (!isOllama && cfg.apiKey.size == 0) {
        eprintln("[cjh] 警告：未配置 API Key（${cfg.authPath} 的 api_key 或 OPENAI_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY 环境变量）。")
        eprintln("[cjh] 界面可正常进入，但发送消息会失败。离线演示请用 --mock 或 CJH_MOCK=1。")
    }
    // 协议选择（优先级）：CJH_PROVIDER 环境变量 > settings.json provider_protocol > 默认 OpenAI
    // provider_protocol 支持聚合/自定义端点（custom provider）指定接入协议：
    //   "anthropic"=Anthropic Messages；"openai"/"" = OpenAI 兼容；"gemini" 预留（未实现）
    let protocol = if (providerName.size > 0) { providerName } else { cfg.providerProtocol }
    var p: LlmProvider
    if (isOllama) {
        // Ollama 端点：base_url 已指向 localhost/127.0.0.1 时优先用配置；
        // 否则（CJH_PROVIDER=ollama 但 base_url 是云端默认）强制 localhost
        let ollamaBase = if (cfg.baseUrl.contains("localhost") ||
            cfg.baseUrl.contains("127.0.0.1")) {
            cfg.baseUrl
        } else {
            "http://localhost:11434/v1"
        }
        p = OllamaProvider(ollamaBase, cfg.apiKey, cfg.model)
    } else if (protocol == "anthropic") {
        let anthropicKey = readEnv("ANTHROPIC_API_KEY") ?? readEnv("ANTHROPIC_AUTH_TOKEN") ?? cfg.apiKey
        let anthropicBase = readEnv("ANTHROPIC_BASE_URL") ?? "https://api.anthropic.com/v1/messages"
        p = AnthropicProvider(anthropicBase, anthropicKey, cfg.model)
    } else if (protocol == "gemini") {
        throw LlmException("Gemini 原生协议暂未支持。请改用 OpenAI 兼容端点（Google 提供 generativelanguage.googleapis.com/v1beta/openai），或选择 openai/anthropic 协议")
    } else {
        let oa = OpenAiProvider(cfg.baseUrl, cfg.apiKey, cfg.model)
        applyFallbackKeys(oa, cfg)
        p = oa
    }
    // 应用采样参数（/settings 调整后重建 provider 时生效）
    match (p) {
        case oa: OpenAiProvider => oa.setSampling(cfg.temperature, cfg.maxTokens)
        case ap: AnthropicProvider => ap.setSampling(cfg.temperature, cfg.maxTokens)
        case op: OllamaProvider => op.setSampling(cfg.temperature, cfg.maxTokens)
        case _ => ()
    }
    return p
}

main(args: Array<String>): Int64 {
    // 禁掉 stdx 库内部日志（如 stdx.net.http 的 read response timeout WARN）
    // 这些日志走 stdx.log 全局 logger 直接到 stderr，污染 TUI 输入框
    // 必须在任何 stdx 库调用之前设置，否则早期日志仍会漏出
    setGlobalLogger(NoopLogger())
    if (args.size > 0 && args[0] == "--mock") {
        return runMockVerify()
    }
    if (args.size > 0 && args[0] == "--mode" && args.size > 1 && args[1] == "json") {
        // --mode json [--resume <id>] <prompt...>：无头模式，输出 JSON 结果（脚本可解析）
        var sessionId = ""
        var prompt = ""
        var i: Int64 = 2
        while (i < args.size) {
            if (args[i] == "--resume" && i + 1 < args.size) {
                sessionId = args[i + 1]
                i += 2
            } else {
                prompt = args[i]
                i += 1
            }
        }
        return runJson(prompt, sessionId)
    }
    if (args.size > 0 && args[0] == "--cli") {
        if (args.size > 2 && args[1] == "--resume") {
            return runCli(args[2])
        }
        return runCli("")
    }
    if (args.size > 1 && args[0] == "--resume") {
        return runTui(args[1])
    }
    if (args.size > 0 && args[0] == "--list") {
        return listSessions()
    }
    // cjh web [--port <n>] [--bind <addr>] [--token <t>]
    if (args.size > 0 && (args[0] == "web" || args[0] == "--web")) {
        return runWeb(args)
    }
    return runTui("")
}

class SessionState {
    static var current: String = ""
}

class StreamState {
    static var active: Bool = false
    static var md: MarkdownRender = MarkdownRender()
}

/**
 * 摘要专用快模型 provider（P1-5 模型路由）：
 * settings.json 配了 summary_model 时返回独立 provider（compaction 摘要走快模型）；
 * 未配置返回 None（复用主 provider）。
 */
func makeSummaryProvider(cfg: CjhConfig): Option<LlmProvider> {
    if (cfg.summaryModel.size == 0) {
        return None
    }
    let base = if (cfg.summaryBaseUrl.size > 0) { cfg.summaryBaseUrl } else { cfg.baseUrl }
    let key = if (cfg.summaryApiKey.size > 0) { cfg.summaryApiKey } else { cfg.apiKey }
    let oa = OpenAiProvider(base, key, cfg.summaryModel)
    applyFallbackKeys(oa, cfg)
    return Some(oa)
}

/**
 * 应用备用 key（P1-5 429 fallback）：
 * settings.json fallback_api_keys 数组 + env CJH_FALLBACK_KEYS（逗号分隔）合并。
 */
func applyFallbackKeys(oa: OpenAiProvider, cfg: CjhConfig): Unit {
    // 配置数组
    for (k in cfg.fallbackApiKeys) {
        if (k.size > 0) {
            oa.fallbackKeys.add(k)
        }
    }
    // env 逗号分隔追加
    let envKeys = readEnv("CJH_FALLBACK_KEYS")
    if (envKeys.isSome()) {
        for (k in envKeys.getOrThrow().split(",", -1)) {
            let t = k.trimAscii()
            if (t.size > 0) {
                oa.fallbackKeys.add(t)
            }
        }
    }
}

/**
 * TUI 跨线程桥：agent 在 spawn 线程运行，经静态引用访问 TUI（避免闭包捕获跨线程问题）
 */
class TuiBridge {
    static var app: Option<TuiApp> = None

    public static func output(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.appendOutput(text)
        }
    }

    /**
     * 确保输出以换行结尾（工具调用提示前调用，避免拼到流式文字后面）
     */
    public static func ensureNewline(): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.ensureNewline()
        }
    }

    public static func delta(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.appendDelta(text)
        }
    }

    /**
     * 流式结束：用最终完整文本替换流式段（整体修复 mojibake 后重绘）
     */
    public static func endStream(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.endStream(text)
        }
    }

    public static func status(text: String): Unit {
        if (let Some(a) <- TuiBridge.app) {
            a.setStatus(text)
        }
    }

    /**
     * 请求人工审批（agent 线程调用；阻塞直到用户在 TUI 按 y/n）
     */
    public static func requestApproval(prompt: String): Bool {
        if (let Some(a) <- TuiBridge.app) {
            return a.requestApproval(prompt)
        }
        return false
    }
}
