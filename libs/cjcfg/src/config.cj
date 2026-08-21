package cjcfg

import std.fs.*
import stdx.encoding.json.*
import std.collection.*

/**
 * 配置系统（对标成熟 agent 的配置目录设计）
 *
 * 目录结构（~/.cjh/，可用 CJH_CONFIG_DIR 覆盖）：
 *   settings.json    # 主配置：模型/端点/行为
 *   auth.json        # 凭据：API keys（文件权限 600）
 *   sessions/        # 会话历史（JSON）
 *   tools/           # 自定义工具（预留）
 *
 * 优先级（高→低）：环境变量 > auth.json/settings.json > 内置默认
 */
public class CjhConfig {
    // 配置目录
    public let configDir: String
    public let settingsPath: String
    public let authPath: String
    public let sessionsDir: String

    // 配置值
    public var baseUrl: String = "https://api.openai.com/v1/chat/completions"
    public var model: String = "gpt-4o-mini"
    public var apiKey: String = ""
    public var maxIterations: Int64 = 10
    public var systemPrompt: String = ""

    public init() {
        // 配置目录：环境变量覆盖，默认 ~/.cjh
        let home = readEnv("HOME") ?? "/root"
        this.configDir = readEnv("CJH_CONFIG_DIR") ?? (home + "/.cjh")
        this.settingsPath = this.configDir + "/settings.json"
        this.authPath = this.configDir + "/auth.json"
        this.sessionsDir = this.configDir + "/sessions"
        this.load()
    }

    /**
     * 确保配置目录存在（含 sessions/）
     */
    public func ensureDirs(): Unit {
        if (!exists(this.configDir)) {
            Directory.create(this.configDir, recursive: true)
        }
        if (!exists(this.sessionsDir)) {
            Directory.create(this.sessionsDir, recursive: true)
        }
        // 首次运行：自动生成配置文件模板
        this.ensureTemplate(this.settingsPath, this.settingsTemplate())
        this.ensureTemplate(this.authPath, this.authTemplate())
    }

    /**
     * 文件不存在时写入模板
     */
    private func ensureTemplate(path: String, content: String): Unit {
        if (!exists(path)) {
            try {
                File.writeTo(path, content.toArray())
                eprintln("[cjh] 已生成配置文件: ${path}")
            } catch (e: Exception) {
                eprintln("[cjh] 生成配置文件失败 ${path}: ${e}")
            }
        }
    }

    /**
     * settings.json 模板（未知字段被忽略，_说明 仅为提示）
     */
    private func settingsTemplate(): String {
        return "{\n" +
            "  \"_说明\": \"可选配置，默认即可运行。支持 base_url / model / max_iterations / system_prompt\",\n" +
            "  \"base_url\": \"https://api.openai.com/v1/chat/completions\",\n" +
            "  \"model\": \"gpt-4o-mini\",\n" +
            "  \"max_iterations\": 10\n" +
            "}\n"
    }

    /**
     * auth.json 模板（api_key 任一字段填写即可）
     */
    private func authTemplate(): String {
        return "{\n" +
            "  \"_说明\": \"在此填写 API Key：api_key 或 openai_api_key / deepseek_api_key / dashscope_api_key 任一即可。如：sk-xxxx\",\n" +
            "  \"api_key\": \"\",\n" +
            "  \"openai_api_key\": \"\",\n" +
            "  \"deepseek_api_key\": \"\",\n" +
            "  \"dashscope_api_key\": \"\"\n" +
            "}\n"
    }

    /**
     * 加载配置：settings.json + auth.json，然后环境变量覆盖
     */
    private func load(): Unit {
        this.loadSettings()
        this.loadAuth()
        this.applyEnvOverrides()
        // 默认系统提示词
        if (this.systemPrompt.size == 0) {
            this.systemPrompt = "你是一个运行在终端里的编码代理（cjh）。你可以使用工具完成任务：bash 执行命令、read_file 读文件、write_file 写文件。" +
                "任务通常需要多步：先读代码理解现状，再修改，再用 bash 验证。保持简洁，用中文回答。"
        }
    }

    private func loadSettings(): Unit {
        if (!exists(this.settingsPath)) {
            return
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.settingsPath)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    if (let Some(v) <- obj.get("base_url")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.baseUrl = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("model")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.model = v.asString().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("max_iterations")) {
                        match (v.kind()) {
                            case JsonKind.JsInt => this.maxIterations = v.asInt().getValue()
                            case _ => ()
                        }
                    }
                    if (let Some(v) <- obj.get("system_prompt")) {
                        match (v.kind()) {
                            case JsonKind.JsString => this.systemPrompt = v.asString().getValue()
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            eprintln("[cjh] settings.json 解析失败: ${e}")
        }
    }

    private func loadAuth(): Unit {
        if (!exists(this.authPath)) {
            return
        }
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.authPath)))
            match (json.kind()) {
                case JsonKind.JsObject =>
                    let obj = json.asObject()
                    // 兼容多种字段名
                    for (key in ["api_key", "openai_api_key", "deepseek_api_key", "dashscope_api_key"]) {
                        if (let Some(v) <- obj.get(key)) {
                            match (v.kind()) {
                                case JsonKind.JsString =>
                                    let k = v.asString().getValue()
                                    if (k.size > 0 && this.apiKey.size == 0) {
                                        this.apiKey = k
                                    }
                                case _ => ()
                            }
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            eprintln("[cjh] auth.json 解析失败: ${e}")
        }
    }

    /**
     * 环境变量覆盖（最高优先级）
     */
    private func applyEnvOverrides(): Unit {
        let key = readEnv("OPENAI_API_KEY") ?? readEnv("DEEPSEEK_API_KEY") ??
            readEnv("DASHSCOPE_API_KEY") ?? readEnv("CJH_API_KEY") ?? ""
        if (key.size > 0) {
            this.apiKey = key
        }
        let baseUrl = readEnv("CJH_BASE_URL") ?? readEnv("OPENAI_BASE_URL") ?? ""
        if (baseUrl.size > 0) {
            this.baseUrl = baseUrl
        }
        let model = readEnv("CJH_MODEL") ?? readEnv("OPENAI_MODEL") ?? ""
        if (model.size > 0) {
            this.model = model
        }
    }

    /**
     * 读取环境变量（经 EnvFfi 封装）
     */
    private static func readEnv(name: String): Option<String> {
        return EnvFfi.getenv(name)
    }
}
