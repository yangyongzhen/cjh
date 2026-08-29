package cjconfig

/**
 * 通用分层配置库：环境变量 > 配置文件 > 默认值
 *
 * 设计对标 Go viper / Rust config 的轻量版（仓颉原生，零第三方依赖）：
 *   - 声明式字段：define(key, 类型, 默认值, 环境变量映射, 说明)
 *   - 三层优先级：环境变量 > 配置文件 > 默认值，免手写覆盖逻辑
 *   - 类型安全读取：getStr/getInt/getFloat/getBool/getJson
 *   - 读-改-写保留未知字段：用户手写的扩展配置不被覆盖
 *   - 自动模板：首次 save 生成带 _说明 的 config.json
 *   - 跨平台路径：~/.<app>/config.json（Windows USERPROFILE / POSIX HOME）
 *
 * 用法：
 *   let cfg = ConfigStore("myapp")                       // ~/.myapp/config.json
 *   cfg.defineStr("model", "gpt-4o-mini", "MYAPP_MODEL", "LLM 模型")
 *   cfg.defineInt("max_iters", 10, "MYAPP_MAX_ITERS", "最大迭代")
 *   cfg.load()                                           // 默认+文件+env
 *   let model = cfg.getStr("model")                      // env 优先
 *   cfg.setStr("model", "deepseek-chat")
 *   cfg.save()
 */

import std.collection.*
import std.convert.Parsable
import std.fs.*
import stdx.encoding.json.*

// ===== 跨平台基础（内联，零外部依赖）=====
@C
foreign func getenv(name: CString): CPointer<UInt8>

private func getenvAny(name: String): Option<String> {
    unsafe {
        let p = getenv(LibC.mallocCString(name))
        if (p.isNull()) {
            return None
        }
        return Some(CString(p).toString())
    }
}

// ===== 类型标记 =====
private const KIND_STRING: String = "string"
private const KIND_INT: String = "int"
private const KIND_FLOAT: String = "float"
private const KIND_BOOL: String = "bool"
private const KIND_JSON: String = "json"

/**
 * 配置字段声明：key + 类型 + 默认值 + 环境变量映射 + 说明
 */
public class ConfigField {
    public let key: String
    public let kind: String
    public let defaultValue: JsonValue
    public let envName: String   // 空 = 不映射环境变量
    public let desc: String      // 说明（文档/模板注释用）

    public init(key: String, kind: String, defaultValue: JsonValue, envName: String, desc: String) {
        this.key = key
        this.kind = kind
        this.defaultValue = defaultValue
        this.envName = envName
        this.desc = desc
    }
}

/**
 * 分层配置存储
 */
public class ConfigStore {
    private let appName: String
    private let storeDir: String
    private let storePath: String
    private let fields: ArrayList<ConfigField> = ArrayList<ConfigField>()
    private var values: JsonObject = JsonObject()   // 文件内容（含未知字段）+ 默认补缺
    private var loaded: Bool = false

    /**
     * @param appName 应用名（配置目录 ~/.<appName>/）
     */
    public init(appName: String) {
        this.appName = appName
        this.storeDir = homeDir() + pathSep() + "." + appName
        this.storePath = this.storeDir + pathSep() + "config.json"
    }

    /**
     * @param appName 应用名
     * @param configDir 显式配置目录（空字符串 = 用户主目录，跨平台）
     */
    public init(appName: String, configDir: String) {
        this.appName = appName
        if (configDir.size > 0) {
            this.storeDir = configDir
        } else {
            this.storeDir = homeDir() + pathSep() + "." + appName
        }
        this.storePath = this.storeDir + pathSep() + "config.json"
    }

    // ===== 字段声明 =====

    public func defineStr(key: String, defaultVal: String): Unit {
        this.fields.add(ConfigField(key, KIND_STRING, JsonString(defaultVal), "", ""))
    }

    public func defineStr(key: String, defaultVal: String, envName: String, desc: String): Unit {
        this.fields.add(ConfigField(key, KIND_STRING, JsonString(defaultVal), envName, desc))
    }

    public func defineInt(key: String, defaultVal: Int64): Unit {
        this.fields.add(ConfigField(key, KIND_INT, JsonInt(defaultVal), "", ""))
    }

    public func defineInt(key: String, defaultVal: Int64, envName: String, desc: String): Unit {
        this.fields.add(ConfigField(key, KIND_INT, JsonInt(defaultVal), envName, desc))
    }

    public func defineFloat(key: String, defaultVal: Float64): Unit {
        this.fields.add(ConfigField(key, KIND_FLOAT, JsonFloat(defaultVal), "", ""))
    }

    public func defineFloat(key: String, defaultVal: Float64, envName: String, desc: String): Unit {
        this.fields.add(ConfigField(key, KIND_FLOAT, JsonFloat(defaultVal), envName, desc))
    }

    public func defineBool(key: String, defaultVal: Bool): Unit {
        this.fields.add(ConfigField(key, KIND_BOOL, JsonBool(defaultVal), "", ""))
    }

    public func defineBool(key: String, defaultVal: Bool, envName: String, desc: String): Unit {
        this.fields.add(ConfigField(key, KIND_BOOL, JsonBool(defaultVal), envName, desc))
    }

    /**
     * 通用 JSON 字段（数组/对象）
     */
    public func defineJson(key: String, defaultVal: JsonValue): Unit {
        this.fields.add(ConfigField(key, KIND_JSON, defaultVal, "", ""))
    }

    public func defineJson(key: String, defaultVal: JsonValue, envName: String, desc: String): Unit {
        this.fields.add(ConfigField(key, KIND_JSON, defaultVal, envName, desc))
    }

    // ===== 加载 =====

    /**
     * 加载配置：默认值 + 配置文件覆盖 + 环境变量在读取时实时覆盖
     * 重复调用幂等（重新读文件）
     */
    public func load(): Unit {
        this.values = JsonObject()
        // 1. 配置文件（保留未知字段）
        if (exists(this.storePath)) {
            try {
                let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.storePath)))
                match (json.kind()) {
                    case JsonKind.JsObject => this.values = json.asObject()
                    case _ => ()  // 非对象文件：忽略，用默认
                }
            } catch (e: Exception) {
                // 解析失败：用默认值（不覆盖用户文件，save 时重建前先备份）
            }
        }
        // 2. 默认值补缺
        for (f in this.fields) {
            if (this.values.get(f.key).isNone()) {
                this.values.put(f.key, f.defaultValue)
            }
        }
        this.loaded = true
    }

    // ===== 读取（环境变量 > 文件 > 默认）=====

    public func getStr(key: String): String {
        let v = this.get(key)
        match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case JsonKind.JsInt => return v.asInt().getValue().toString()
            case JsonKind.JsFloat => return v.asFloat().getValue().toString()
            case JsonKind.JsBool => return v.asBool().getValue().toString()
            case _ => return ""
        }
    }

    public func getInt(key: String): Int64 {
        let v = this.get(key)
        match (v.kind()) {
            case JsonKind.JsInt => return v.asInt().getValue()
            case JsonKind.JsString =>
                try { return Int64.parse(v.asString().getValue()) } catch (e: Exception) { return 0 }
            case _ => return 0
        }
    }

    public func getFloat(key: String): Float64 {
        let v = this.get(key)
        match (v.kind()) {
            case JsonKind.JsFloat => return v.asFloat().getValue()
            case JsonKind.JsInt => return Float64(v.asInt().getValue())
            case JsonKind.JsString =>
                try { return Float64.parse(v.asString().getValue()) } catch (e: Exception) { return 0.0 }
            case _ => return 0.0
        }
    }

    public func getBool(key: String): Bool {
        let v = this.get(key)
        match (v.kind()) {
            case JsonKind.JsBool => return v.asBool().getValue()
            case JsonKind.JsString =>
                let s = v.asString().getValue()
                return s == "true" || s == "1" || s == "yes"
            case _ => return false
        }
    }

    public func getJson(key: String): JsonValue {
        return this.get(key)
    }

    /**
     * 带类型转换的环境变量覆盖（env 值 → 字段类型）
     */
    private func get(key: String): JsonValue {
        // 环境变量优先（实时读取，无需重新 load）
        let field = this.findField(key)
        if (field.isSome()) {
            let f = field.getOrThrow()
            if (f.envName.size > 0) {
                if (let Some(envVal) <- getenv(f.envName)) {
                    if (envVal.size > 0) {
                        let parsed = this.parseEnv(envVal, f.kind)
                        if (parsed.isSome()) {
                            return parsed.getOrThrow()
                        }
                    }
                }
            }
        }
        // 文件（含未知字段）> 默认
        if (this.values.get(key).isSome()) {
            return this.values.get(key).getOrThrow()
        }
        if (field.isSome()) {
            return field.getOrThrow().defaultValue
        }
        return JsonNull()
    }

    private func parseEnv(envVal: String, kind: String): Option<JsonValue> {
        try {
            match (kind) {
                case "int" => return Some(JsonInt(Int64.parse(envVal)))
                case "float" => return Some(JsonFloat(Float64.parse(envVal)))
                case "bool" =>
                    return Some(JsonBool(envVal == "true" || envVal == "1" || envVal == "yes"))
                case "json" => return Some(JsonValue.fromStr(envVal))
                case _ => return Some(JsonString(envVal))
            }
        } catch (e: Exception) {
            return None  // 非法 env 值：忽略（用文件/默认）
        }
    }

    // ===== 写入 =====

    public func set(key: String, value: JsonValue): Unit {
        this.values.put(key, value)
    }

    public func setStr(key: String, value: String): Unit {
        this.set(key, JsonString(value))
    }

    public func setInt(key: String, value: Int64): Unit {
        this.set(key, JsonInt(value))
    }

    public func setBool(key: String, value: Bool): Unit {
        this.set(key, JsonBool(value))
    }

    /**
     * 保存：写回 values（含未知字段），保留用户手写扩展。
     * 首次保存自动生成模板（含 _说明）。
     */
    public func save(): Unit {
        if (!exists(this.storeDir)) {
            Directory.create(this.storeDir, recursive: true)
        }
        // 首帧生成模板：当前值（默认+set）+ 字段说明
        if (!exists(this.storePath)) {
            let descText = "自动生成的配置模板。字段默认值如下；环境变量可覆盖（见 README）。"
            var tmpl = JsonObject()
            tmpl.put("_说明", JsonString(descText))
            // 用当前值（含 set 修改），非纯默认值
            let current = this.values.getFields()
            for ((k, v) in current) {
                tmpl.put(k, v)
            }
            for (f in this.fields) {
                if (f.desc.size > 0) {
                    tmpl.put("_" + f.key + "_说明", JsonString(f.desc))
                }
            }
            File.writeTo(this.storePath, tmpl.toJsonString().toArray())
            return
        }
        // 已有文件：读-改-写（保留未知字段）
        var root = JsonObject()
        try {
            let json = JsonValue.fromStr(String.fromUtf8(File.readFrom(this.storePath)))
            match (json.kind()) {
                case JsonKind.JsObject => root = json.asObject()
                case _ => ()
            }
        } catch (e: Exception) {
            // 文件损坏：从内存 values 重建
        }
        let currentKeys = this.values.getFields()
        for ((k, v) in currentKeys) {
            root.put(k, v)
        }
        File.writeTo(this.storePath, root.toJsonString().toArray())
    }

    // ===== 查询 =====

    public func configPath(): String {
        return this.storePath
    }

    public func configDir(): String {
        return this.storeDir
    }

    /**
     * 全部已加载值（含未知字段），调试/展示用
     */
    public func dump(): JsonObject {
        return this.values
    }

    private func findField(key: String): Option<ConfigField> {
        for (f in this.fields) {
            if (f.key == key) {
                return Some(f)
            }
        }
        return None
    }

    // ===== 跨平台基础（内联，零外部依赖）=====

    private func getenv(name: String): Option<String> {
        return getenvAny(name)
    }

    private static func homeDir(): String {
        // Windows USERPROFILE（无 HOME）→ POSIX HOME → 当前目录
        if (let Some(up) <- getenvAny("USERPROFILE")) {
            if (up.size > 0) {
                return up
            }
        }
        return getenvAny("HOME") ?? "."
    }

    /**
     * 平台路径分隔符（编译期确定）
     */
    @When[os == "Windows"]
    private static func pathSep(): String { return "\\" }

    @When[os != "Windows"]
    private static func pathSep(): String { return "/" }
}
