package cjh.tools

/**
 * 插件系统（V2b Step 1 + Step 2）
 *
 * Step 1: plugin.json + 插件加载
 *   - ~/.cjh/plugins/<name>/plugin.json 声明工具元数据
 *   - 工具实现 = shell 脚本，stdin 接收 JSON 参数，stdout 返回结果
 *   - PluginManager 扫描 pluginsDir，解析 plugin.json，注册 PluginTool
 *
 * Step 2: 事件钩子
 *   - plugin.json 的 hooks 段声明事件钩子脚本
 *   - on_tool_result: 工具执行完毕、回填消息历史之前触发
 *     stdin 收到 {"tool":"bash","call_id":"...","content":"..."}
 *     stdout 输出改写后的 content（钩子可拦截/改写工具结果）
 *
 * 设计参考：Pi extension API（pi.on 事件钩子 + pi.registerTool）
 * 文档：docs/插件系统实现方案.md
 */

import std.collection.*
import std.env.*
import std.process.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjutil.*

/**
 * 插件工具：由 plugin.json 的 tools 段定义，shell 脚本实现。
 *
 * 执行协议：
 *   输入：stdin 收到 JSON 字符串（LLM 传来的参数）
 *   输出：stdout 输出结果文本（回填到消息历史）
 *   退出码：0=成功，非0=失败（is_error=true）
 */
public class PluginTool <: CjhTool {
    private let name: String
    private let description: String
    private let scriptPath: String        // 工具实现脚本的绝对路径
    private let paramSchema: JsonObject   // JSON Schema 参数定义
    private let readOnly: Bool            // is_read_only

    public init(name: String, description: String, scriptPath: String,
        paramSchema: JsonObject, readOnly: Bool) {
        this.name = name
        this.description = description
        this.scriptPath = scriptPath
        this.paramSchema = paramSchema
        this.readOnly = readOnly
    }

    public func isReadOnly(): Bool {
        return this.readOnly
    }

    public override func spec(): ToolSpec {
        return ToolSpec(this.name, this.description, this.paramSchema)
    }

    public override func execute(args: JsonObject): ToolResult {
        if (!exists(this.scriptPath)) {
            return ToolResult("plugin script not found: ${this.scriptPath}", true)
        }
        try {
            // 参数通过环境变量 CJH_TOOL_ARGS 传递（JSON 字符串）
            // 避免 stdin pipe 无法关闭的问题
            let argsJson = args.toJsonString()
            var env = HashMap<String, String>()
            env.add("CJH_TOOL_ARGS", argsJson)

            // 执行：bash <scriptPath>
            var argv = Array<String>(2, repeat: "")
            argv[0] = this.scriptPath
            let (code, stdoutBytes, stderrBytes) = executeWithOutput("bash", argv,
                environment: env)

            var out = safeFromUtf8(stdoutBytes)
            var err = safeFromUtf8(stderrBytes)

            // 退出码非0 = 失败
            if (code != 0) {
                var msg = "plugin ${this.name} failed (exit ${code})"
                if (err.size > 0) {
                    msg += ": ${err}"
                }
                return ToolResult(msg, true)
            }

            // stdout 作为结果文本
            if (out.size == 0 && err.size > 0) {
                // 某些脚本把结果写到 stderr
                return ToolResult(err, false)
            }
            return ToolResult(out, false)
        } catch (e: Exception) {
            return ToolResult("plugin ${this.name} exception: ${e}", true)
        }
    }
}

/**
 * 插件管理器：扫描 pluginsDir，加载插件，管理事件钩子。
 *
 * 加载流程：
 *   1. 扫描插件根目录下每个子目录的 plugin.json
 *   2. 解析 name/version/tools/hooks
 *   3. 白名单过滤（enabledPlugins 空=全部启用）
 *   4. tools 段注册为 PluginTool
 *   5. hooks 段记录事件钩子脚本路径
 *
 * 安全：
 *   - command/script 路径 resolve 后必须仍在插件目录内
 *   - 否则拒绝加载该插件（路径遍历防护）
 */
public class PluginManager {
    private let pluginsDir: String
    private var hooks: HashMap<String, String>   // 事件名 → 脚本绝对路径
    private var loadedPlugins: ArrayList<String> // 已加载的插件名列表

    public init(pluginsDir: String) {
        this.pluginsDir = pluginsDir
        this.hooks = HashMap<String, String>()
        this.loadedPlugins = ArrayList<String>()
    }

    /**
     * 扫描插件根目录下每个子目录的 plugin.json，加载所有插件
     * - 解析 tools 段，注册为 PluginTool
     * - 解析 hooks 段，记录事件钩子
     *
     * @param registry  工具注册中心
     * @param enabled   白名单（空=全部启用）
     * @param requireSignature  是否强制插件必须带签名（true=无签名拒绝加载）
     */
    public func loadAll(registry: ToolRegistry, enabled: ArrayList<String>,
        requireSignature: Bool): Unit {
        if (!exists(this.pluginsDir)) {
            return
        }
        // 临时启动计时（与 main.cj 的 CJH_STARTUP_PROF 联动）
        let profiling = (getVariable("CJH_STARTUP_PROF") ?? "") == "1"
        func tmark(label: String): Unit {
            if (!profiling) { return }
            try {
                let f = File("/tmp/cjh_startup.log", OpenMode.Append)
                f.write(stringToBytes("  [PLUGIN] ${label}\n"))
                f.close()
            } catch (e: Exception) {}
        }
        tmark("loadAll enter, scanning ${this.pluginsDir}")
        // 扫描 pluginsDir 下的一级子目录
        let entries = ArrayList<String>()
        Directory.walk(this.pluginsDir, { fi =>
            // 只收集一级子目录（plugin 目录）
            if (fi.isDirectory()) {
                entries.add(fi.path.toString())
            }
            return true
        })
        tmark("Directory.walk done, ${entries.size} entries")
        for (pluginDir in entries) {
            let pluginJsonPath = pluginDir + "/plugin.json"
            if (!exists(pluginJsonPath)) {
                continue
            }
            tmark("loading ${pluginDir}")
            try {
                this.loadPlugin(pluginDir, pluginJsonPath, registry, enabled, requireSignature)
            } catch (e: Exception) {
                Log.warn("加载插件失败: ${pluginDir} - ${e}")
            }
            tmark("loaded ${pluginDir}")
        }
        tmark("loadAll done")
        if (this.loadedPlugins.size > 0) {
            Log.info("[PLUGIN] 已加载插件: ${this.loadedPlugins}")
        }
    }

    /**
     * 加载单个插件
     */
    private func loadPlugin(pluginDir: String, pluginJsonPath: String,
        registry: ToolRegistry, enabled: ArrayList<String>,
        requireSignature: Bool): Unit {

        let content = safeFromUtf8(File.readFrom(pluginJsonPath))
        let v = JsonValue.fromStr(content)

        match (v.kind()) {
            case JsonKind.JsObject =>
                let obj = v.asObject()

                // 插件名
                var pluginName = ""
                if (let Some(n) <- obj.get("name")) {
                    match (n.kind()) {
                        case JsonKind.JsString => pluginName = n.asString().getValue()
                        case _ => ()
                    }
                }
                if (pluginName.size == 0) {
                    Log.warn("[PLUGIN] 插件缺少 name 字段: ${pluginJsonPath}")
                    return
                }

                // V3 Step 1：校验和验证（plugin.json 可选 checksum 字段）
                // checksum = SHA256(插件目录除 plugin.json 外所有文件)
                // 存在则强制验证，不匹配则拒绝加载（检测篡改）
                var expectedChecksum = ""
                if (let Some(cs) <- obj.get("checksum")) {
                    match (cs.kind()) {
                        case JsonKind.JsString => expectedChecksum = cs.asString().getValue()
                        case _ => ()
                    }
                }
                if (expectedChecksum.size > 0) {
                    let actualChecksum = sha256DirExcluding(pluginDir, "plugin.json")
                    if (actualChecksum != expectedChecksum) {
                        Log.warn("[PLUGIN] 校验和不匹配，拒绝加载: ${pluginName} (expected=${expectedChecksum}, actual=${actualChecksum})")
                        return
                    }
                    Log.debug("[PLUGIN] 校验和验证通过: ${pluginName}")
                }

                // V3 Step 2：SM2 签名验证（plugin.json 可选字段）
                //   publisher : 发布者 ID（如 "github:alice"）
                //   pubkey    : 发布者 SM2 公钥（DER 编码的 hex）
                //   signature : 对 checksum 值的 SM2 签名（DER 编码的 hex）
                // 三个字段同时存在时强制验签；任一缺失则跳过（兼容无签名插件）
                var publisher = ""
                if (let Some(p) <- obj.get("publisher")) {
                    match (p.kind()) {
                        case JsonKind.JsString => publisher = p.asString().getValue()
                        case _ => ()
                    }
                }
                var pubkeyHex = ""
                if (let Some(pk) <- obj.get("pubkey")) {
                    match (pk.kind()) {
                        case JsonKind.JsString => pubkeyHex = pk.asString().getValue()
                        case _ => ()
                    }
                }
                var signatureHex = ""
                if (let Some(sig) <- obj.get("signature")) {
                    match (sig.kind()) {
                        case JsonKind.JsString => signatureHex = sig.asString().getValue()
                        case _ => ()
                    }
                }
                // 三字段齐全才验签
                if (pubkeyHex.size > 0 && signatureHex.size > 0 && expectedChecksum.size > 0) {
                    match (verifySm2(pubkeyHex, signatureHex, expectedChecksum)) {
                        case Sm2VerifyResult.Verified =>
                            Log.debug("[PLUGIN] SM2 签名验证通过: ${pluginName} publisher=${publisher}")
                        case Sm2VerifyResult.Invalid =>
                            Log.warn("[PLUGIN] SM2 签名不匹配，拒绝加载: ${pluginName}")
                            return
                        case Sm2VerifyResult.BadKey =>
                            Log.warn("[PLUGIN] SM2 公钥格式错误，拒绝加载: ${pluginName}")
                            return
                        case Sm2VerifyResult.BadSignature =>
                            Log.warn("[PLUGIN] SM2 签名格式错误，拒绝加载: ${pluginName}")
                            return
                        case Sm2VerifyResult.Error =>
                            Log.warn("[PLUGIN] SM2 验签内部错误，拒绝加载: ${pluginName}")
                            return
                    }
                } else if (pubkeyHex.size > 0 || signatureHex.size > 0) {
                    // 部分字段存在但不全，记录警告但不拒绝（兼容过渡）
                    Log.warn("[PLUGIN] 签名字段不完整，跳过验签: ${pluginName} (pubkey=${pubkeyHex.size > 0}, sig=${signatureHex.size > 0}, checksum=${expectedChecksum.size > 0})")
                }

                // require_signature 强制模式：无 checksum 或无 pubkey/signature → 拒绝
                if (requireSignature) {
                    let hasChecksum = expectedChecksum.size > 0
                    let hasSig = pubkeyHex.size > 0 && signatureHex.size > 0
                    if (!hasChecksum || !hasSig) {
                        Log.warn("[PLUGIN] require_signature=true，插件缺少完整签名，拒绝加载: ${pluginName} (checksum=${hasChecksum}, sig=${hasSig})")
                        return
                    }
                }

                // 白名单过滤（空=全部启用）
                if (enabled.size > 0 && !enabled.contains(pluginName)) {
                    return
                }

                // 版本（仅日志）
                var version = ""
                if (let Some(vv) <- obj.get("version")) {
                    match (vv.kind()) {
                        case JsonKind.JsString => version = vv.asString().getValue()
                        case _ => ()
                    }
                }

                // tools 段：注册插件工具
                if (let Some(toolsVal) <- obj.get("tools")) {
                    match (toolsVal.kind()) {
                        case JsonKind.JsArray =>
                            let toolsArr = toolsVal.asArray()
                            for (i in 0..toolsArr.size()) {
                                if (let Some(toolItem) <- toolsArr.get(i)) {
                                    this.registerPluginTool(pluginDir, toolItem, registry)
                                }
                            }
                        case _ => ()
                    }
                }

                // hooks 段：记录事件钩子
                if (let Some(hooksVal) <- obj.get("hooks")) {
                    match (hooksVal.kind()) {
                        case JsonKind.JsObject =>
                            let hooksObj = hooksVal.asObject()
                            for ((eventName, scriptVal) in hooksObj.getFields()) {
                                match (scriptVal.kind()) {
                                    case JsonKind.JsString =>
                                        let scriptRel = scriptVal.asString().getValue()
                                        let scriptPath = this.resolveScript(pluginDir, scriptRel)
                                        if (scriptPath.size > 0 && exists(scriptPath)) {
                                            this.hooks.add(eventName, scriptPath)
                                            Log.debug("[PLUGIN] 注册钩子: ${eventName} → ${scriptPath}")
                                        }
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                }

                this.loadedPlugins.add(pluginName + (if (version.size > 0) { "@${version}" } else { "" }))
            case _ => ()
        }
    }

    /**
     * 注册单个插件工具
     */
    private func registerPluginTool(pluginDir: String, toolItem: JsonValue,
        registry: ToolRegistry): Unit {
        match (toolItem.kind()) {
            case JsonKind.JsObject =>
                let toolObj = toolItem.asObject()

                // 工具名
                var toolName = ""
                if (let Some(n) <- toolObj.get("name")) {
                    match (n.kind()) {
                        case JsonKind.JsString => toolName = n.asString().getValue()
                        case _ => ()
                    }
                }
                if (toolName.size == 0) {
                    Log.warn("[PLUGIN] 工具缺少 name 字段")
                    return
                }

                // 工具描述
                var toolDesc = ""
                if (let Some(d) <- toolObj.get("description")) {
                    match (d.kind()) {
                        case JsonKind.JsString => toolDesc = d.asString().getValue()
                        case _ => ()
                    }
                }

                // command 字段：工具实现脚本的相对路径
                var scriptRel = ""
                if (let Some(c) <- toolObj.get("command")) {
                    match (c.kind()) {
                        case JsonKind.JsString => scriptRel = c.asString().getValue()
                        case _ => ()
                    }
                }
                let scriptPath = this.resolveScript(pluginDir, scriptRel)
                if (scriptPath.size == 0 || !exists(scriptPath)) {
                    Log.warn("[PLUGIN] 工具脚本不存在: ${scriptRel} (plugin=${pluginDir})")
                    return
                }

                // is_read_only（默认 false）
                var readOnly = false
                if (let Some(r) <- toolObj.get("is_read_only")) {
                    match (r.kind()) {
                        case JsonKind.JsBool => readOnly = r.asBool().getValue()
                        case _ => ()
                    }
                }

                // parameters 段：JSON Schema 参数定义
                var paramSchema = JsonObject()
                if (let Some(p) <- toolObj.get("parameters")) {
                    match (p.kind()) {
                        case JsonKind.JsObject => paramSchema = p.asObject()
                        case _ => ()
                    }
                }

                let tool = PluginTool(toolName, toolDesc, scriptPath, paramSchema, readOnly)
                registry.register(tool)
                Log.debug("[PLUGIN] 注册工具: ${toolName} (script=${scriptPath})")
            case _ => ()
        }
    }

    /**
     * 解析脚本路径（安全：路径遍历防护）
     * resolve 后必须仍在插件目录内
     */
    private func resolveScript(pluginDir: String, scriptRel: String): String {
        if (scriptRel.size == 0) {
            return ""
        }
        // 规范化路径：pluginDir + "/" + scriptRel
        let full = pluginDir + "/" + scriptRel
        // 防路径遍历：不允许 ../
        if (scriptRel.contains("..")) {
            Log.warn("[PLUGIN] 拒绝路径遍历: ${scriptRel}")
            return ""
        }
        return full
    }

    /**
     * 触发事件钩子
     *
     * @param event  事件名（如 "on_tool_result"）
     * @param data    事件数据（JSON）
     * @return 钩子改写后的内容；无钩子时返回空字符串（调用方据此决定是否改写）
     */
    public func fireHook(event: String, data: JsonValue): String {
        if (!this.hooks.contains(event)) {
            return ""
        }
        let scriptPath = this.hooks.get(event).getOrThrow()
        if (!exists(scriptPath)) {
            return ""
        }
        try {
            // 事件数据通过环境变量 CJH_HOOK_DATA 传递（JSON 字符串）
            let hookJson = data.toJsonString()
            var env = HashMap<String, String>()
            env.add("CJH_HOOK_DATA", hookJson)

            var argv = Array<String>(2, repeat: "")
            argv[0] = scriptPath
            let (code, stdoutBytes, _) = executeWithOutput("bash", argv,
                environment: env)
            if (code != 0) {
                Log.warn("[PLUGIN] 钩子 ${event} 失败 (exit ${code})，用原内容")
                return ""
            }
            return safeFromUtf8(stdoutBytes)
        } catch (e: Exception) {
            Log.warn("[PLUGIN] 钩子 ${event} 异常: ${e}")
            return ""
        }
    }

    /**
     * 已加载的插件列表（用于日志/UI 显示）
     */
    public func getLoadedPlugins(): ArrayList<String> {
        return this.loadedPlugins
    }

    /**
     * 是否注册了指定事件钩子
     */
    public func hasHook(event: String): Bool {
        return this.hooks.contains(event)
    }
}
