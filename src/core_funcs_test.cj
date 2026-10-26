package cjh

import std.collection.*
import std.env.*
import std.fs.*
import std.net.*
import std.process.*
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjutil.*
import cjh.tools.*
import cjh.agent.*
import cjterm.*
import stdx.crypto.keys.*

/**
 * 根包（cjh）纯函数单元测试：
 * - Skills 子系统：frontmatter 解析、工具计数、白名单过滤、技能加载
 * - tool_format：工具参数紧凑显示
 * - TaskTool：子代理派发校验
 *
 * 注意：cjh 是 executable 根包，测试文件必须放本包内（cjh.tests 无法 import 根包）。
 */

func coreTestTempDir(name: String): String {
    let dir = "/tmp/cjh_ut_" + name
    removeTreeForTest(dir)
    Directory.create(dir, recursive: true)
    return dir
}

func coreWriteTextFile(path: String, content: String): Unit {
    File.writeTo(path, content.toArray())
}

func removeTreeForTest(path: String): Unit {
    try {
        var args = Array<String>(2, repeat: "")
        args[0] = "-c"
        args[1] = "rm -rf '" + path + "'"
        let _ = executeWithOutput("/bin/bash", args)
    } catch (e: Exception) {
        // 忽略清理失败
    }
}

@Test
public class CoreSkillsTest {

    @TestCase
    public func testParseFrontmatterScalars(): Unit {
        let fm = "name: my-skill\ndescription: 这是一个技能\nenabled: true\n"
        let fields = parseFrontmatter(fm)
        @Assert(fields.get("name").getOrThrow(), "my-skill")
        @Assert(fields.get("description").getOrThrow(), "这是一个技能")
        @Assert(fields.get("enabled").getOrThrow(), "true")
    }

    @TestCase
    public func testParseFrontmatterMultilineBlock(): Unit {
        let fm = "name: skill\n" +
            "tools:\n" +
            "  [\n" +
            "    {\"name\": \"a\"},\n" +
            "    {\"name\": \"b\"}\n" +
            "  ]\n" +
            "other: x\n"
        let fields = parseFrontmatter(fm)
        @Assert(fields.get("name").getOrThrow(), "skill")
        let tools = fields.get("tools").getOrThrow()
        @Assert(tools.contains("\"name\": \"a\""), true)
        @Assert(tools.contains("\"name\": \"b\""), true)
        @Assert(fields.get("other").getOrThrow(), "x")
    }

    @TestCase
    public func testParseFrontmatterCommentsAndEmpty(): Unit {
        let fm = "# 注释行\n\nname: skill\n"
        let fields = parseFrontmatter(fm)
        @Assert(fields.get("name").getOrThrow(), "skill")
        @Assert(fields.size, 1)
    }

    @TestCase
    public func testParseFrontmatterEmptyInput(): Unit {
        @Assert(parseFrontmatter("").size, 0)
    }

    @TestCase
    public func testParseFrontmatterColonInValue(): Unit {
        let fields = parseFrontmatter("description: 修复: 缓存问题\n")
        @Assert(fields.get("description").getOrThrow(), "修复: 缓存问题")
    }

    @TestCase
    public func testCountSkillTools(): Unit {
        @Assert(countSkillTools("[{\"name\":\"a\"},{\"name\":\"b\"},{\"name\":\"c\"}]"), 3)
        @Assert(countSkillTools("[]"), 0)
        @Assert(countSkillTools("not json"), 0)
        @Assert(countSkillTools("{\"name\":\"not array\"}"), 0)
    }

    @TestCase
    public func testSkillEnabledWhitelist(): Unit {
        var enabled = ArrayList<String>()
        enabled.add("a")
        enabled.add("b")
        @Assert(skillEnabled("a", enabled), true)
        @Assert(skillEnabled("c", enabled), false)
        var empty = ArrayList<String>()
        @Assert(skillEnabled("anything", empty), true)
    }

    @TestCase
    public func testLoadSkillsFromDir(): Unit {
        let dir = coreTestTempDir("skills")
        coreWriteTextFile(dir + "/one.md",
            "---\nname: skill-one\ndescription: 第一个\n---\n技能一指令")
        coreWriteTextFile(dir + "/two.md",
            "---\nname: skill-two\ndescription: 第二个\n---\n技能二指令")
        var enabled = ArrayList<String>()
        let all = loadSkills(dir, enabled)
        @Assert(all.contains("skill-one"), true)
        @Assert(all.contains("技能一指令"), true)
        @Assert(all.contains("skill-two"), true)
        var whitelist = ArrayList<String>()
        whitelist.add("skill-one")
        let filtered = loadSkills(dir, whitelist)
        @Assert(filtered.contains("技能一指令"), true)
        @Assert(filtered.contains("技能二指令"), false)
    }

    @TestCase
    public func testLoadSkillsNonexistentDir(): Unit {
        var enabled = ArrayList<String>()
        @Assert(loadSkills("/tmp/cjh_ut_no_such_skills_dir", enabled), "")
    }

    @TestCase
    public func testLoadSkillsBodyTrimmed(): Unit {
        let dir = coreTestTempDir("skills2")
        coreWriteTextFile(dir + "/t.md", "---\nname: t\n---\n  正文内容  \n")
        var enabled = ArrayList<String>()
        let result = loadSkills(dir, enabled)
        @Assert(result.contains("正文内容"), true)
        @Assert(result.endsWith("正文内容"), true)
    }
}

@Test
public class CoreToolFormatTest {

    @TestCase
    public func testFormatToolArgsBash(): Unit {
        var args = JsonObject()
        args.put("command", JsonString("ls -la"))
        @Assert(formatToolArgs("bash", args), "ls -la")
    }

    @TestCase
    public func testFormatToolArgsReadFile(): Unit {
        var args = JsonObject()
        args.put("path", JsonString("src/main.cj"))
        @Assert(formatToolArgs("read_file", args), "src/main.cj")
    }

    @TestCase
    public func testFormatToolArgsMultiField(): Unit {
        var args = JsonObject()
        args.put("path", JsonString("src"))
        args.put("pattern", JsonString("TODO"))
        let result = formatToolArgs("grep", args)
        @Assert(result.contains("src"), true)
        @Assert(result.contains("pattern: TODO"), true)
    }

    @TestCase
    public func testFormatToolArgsTruncation(): Unit {
        var args = JsonObject()
        args.put("path", JsonString(coreRepeatStr("x", 200)))
        let result = formatToolArgs("read_file", args)
        @Assert(result.endsWith("…"), true)
        @Assert(result.size <= 125, true)
    }

    @TestCase
    public func testFormatToolArgsEmpty(): Unit {
        @Assert(formatToolArgs("bash", JsonObject()), "")
    }

    private func coreRepeatStr(s: String, n: Int64): String {
        var sb = StringBuilder()
        for (i in 0..n) {
            sb.append(s)
        }
        return sb.toString()
    }
}

@Test
public class CoreTaskToolTest {

    @TestCase
    public func testTaskToolSpawn(): Unit {
        let tool = TaskTool({ description, prompt, subagentType =>
            TaskSpawnResult("子代理结果: ${prompt}", 3, 100, 50)
        })
        var args = JsonObject()
        args.put("description", JsonString("测试任务"))
        args.put("prompt", JsonString("做某事"))
        args.put("subagent_type", JsonString("worker"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        @Assert(result.content.contains("├─ [worker] 测试任务 · ok · 迭代 3"), true)
        @Assert(result.content.contains("↑100 ↓50"), true)
        @Assert(result.content.contains("└─ (task 结束)"), true)
    }

    @TestCase
    public func testTaskToolMissingParams(): Unit {
        let tool = TaskTool({ _, _, _ => TaskSpawnResult("", 0, 0, 0) })
        var args = JsonObject()
        args.put("description", JsonString("只有描述"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }

    @TestCase
    public func testTaskToolInvalidSubagentType(): Unit {
        let tool = TaskTool({ _, _, _ => TaskSpawnResult("", 0, 0, 0) })
        var args = JsonObject()
        args.put("description", JsonString("d"))
        args.put("prompt", JsonString("p"))
        args.put("subagent_type", JsonString("hacker"))
        let result = tool.execute(args)
        @Assert(result.isError, true)
        @Assert(result.content.contains("无效的 subagent_type"), true)
    }

    @TestCase
    public func testTaskToolEmptyPrompt(): Unit {
        let tool = TaskTool({ _, _, _ => TaskSpawnResult("", 0, 0, 0) })
        var args = JsonObject()
        args.put("description", JsonString("d"))
        args.put("prompt", JsonString(""))
        let result = tool.execute(args)
        @Assert(result.isError, true)
    }
}

// ==================== P1a：makeProvider 接线 ====================
// 注意：makeProvider 对 OpenAiProvider 会后台 spawn warmup（内部异常静默）；
// 测试断言的是装配结果（provider 类型 + 采样参数），不依赖 warmup 完成。

@Test
public class P1aMakeProviderTest {
    /** makeProvider 后清理 provider 环境变量，防止污染后续用例 */
    func cleanupProviderEnv(): Unit {
        removeVariable("CJH_PROVIDER")
        removeVariable("ANTHROPIC_BASE_URL")
        removeVariable("ANTHROPIC_API_KEY")
    }

    @TestCase
    public func testMakeProviderOpenAiWiring(): Unit {
        // baseUrl 不能含 localhost/127.0.0.1（makeProvider 会据此误判为 Ollama）；
        // 用不可解析主机名：warmup 是后台 spawn 且内部异常静默，不影响断言
        cleanupProviderEnv()
        let cfg = CjhConfig()
        cfg.baseUrl = "http://openai.mock:18210"
        cfg.apiKey = "k"
        cfg.model = "m"
        cfg.temperature = 0.3
        cfg.maxTokens = 4096
        cfg.reasoningEffort = "medium"
        let p = makeProvider(cfg)
        let isOa = match (p) {
            case _: OpenAiProvider => true
            case _ => false
        }
        @Assert(isOa, true)
        match (p) {
            case oa: OpenAiProvider =>
                @Assert(oa.reasoningEffort, "medium")
                @Assert(oa.temperature, 0.3)
                @Assert(oa.maxTokens, 4096)
            case _ => ()
        }
    }

    @TestCase
    public func testMakeProviderAnthropicWiring(): Unit {
        cleanupProviderEnv()
        setVariable("CJH_PROVIDER", "anthropic")
        setVariable("ANTHROPIC_BASE_URL", "http://127.0.0.1:18211")
        setVariable("ANTHROPIC_API_KEY", "ak")
        let cfg = CjhConfig()
        cfg.apiKey = "ignored"
        cfg.model = "claude-x"
        cfg.reasoningEffort = "high"
        let p = makeProvider(cfg)
        let isAp = match (p) {
            case _: AnthropicProvider => true
            case _ => false
        }
        @Assert(isAp, true)
        match (p) {
            case ap: AnthropicProvider =>
                // high → 8192；maxTokens 默认 16384 > 8192 无降级
                @Assert(ap.thinkingBudget, 8192)
                @Assert(ap.model, "claude-x")
            case _ => ()
        }
        cleanupProviderEnv()
    }

    @TestCase
    public func testMakeProviderOllamaWiring(): Unit {
        cleanupProviderEnv()
        setVariable("CJH_PROVIDER", "ollama")
        let cfg = CjhConfig()
        cfg.baseUrl = "http://127.0.0.1:11434"
        cfg.model = "llama"
        cfg.reasoningEffort = "low"
        let p = makeProvider(cfg)
        let isOp = match (p) {
            case _: OllamaProvider => true
            case _ => false
        }
        @Assert(isOp, true)
        match (p) {
            case op: OllamaProvider =>
                @Assert(op.model, "llama")
            case _ => ()
        }
        cleanupProviderEnv()
    }
}

// ==================== V3 Step 3：信任列表（trusted-publishers）====================

/**
 * 构造带真实 SM2 签名的插件（复用 signed-demo 的签名流程：
 * checksum → SM2 密钥对 → 公钥 DER hex → 签 checksum → 写 plugin.json）。
 * 工具脚本放插件目录根（sha256DirExcluding 用非递归 walk，resolveScript 禁止 ..）。
 */
func coreMakeSignedPlugin(base: String, pluginName: String, publisher: String): Unit {
    let pluginDir = base + "/" + pluginName
    Directory.create(pluginDir, recursive: true)
    File.writeTo(pluginDir + "/run.sh", stringToBytes("echo hi"))
    // 1. checksum（排除 plugin.json）
    let checksum = sha256DirExcluding(pluginDir, "plugin.json")
    // 2. SM2 密钥对（测试用，真实场景私钥离线保管）
    let privateKey = SM2PrivateKey()
    let publicKey = SM2PublicKey(privateKey)
    // 3. 公钥 DER → hex
    let pubkeyHex = bytesToHex(publicKey.encodeToDer().body)
    // 4. 用私钥签 checksum 字节
    let signatureHex = bytesToHex(signSm2(privateKey, hexToBytes(checksum)))
    // 5. 组装 plugin.json（四字段齐全 + 一个工具）
    var tool = JsonObject()
    tool.put("name", JsonString(pluginName + "_tool"))
    tool.put("description", JsonString("trust test tool"))
    tool.put("command", JsonString("run.sh"))
    let tools = JsonArray()
    tools.add(tool)
    var obj = JsonObject()
    obj.put("name", JsonString(pluginName))
    obj.put("publisher", JsonString(publisher))
    obj.put("checksum", JsonString(checksum))
    obj.put("pubkey", JsonString(pubkeyHex))
    obj.put("signature", JsonString(signatureHex))
    obj.put("tools", tools)
    File.writeTo(pluginDir + "/plugin.json", stringToBytes(obj.toJsonString()))
}

/**
 * 构造无签名插件
 */
func coreMakePlainPlugin(base: String, pluginName: String): Unit {
    let pluginDir = base + "/" + pluginName
    Directory.create(pluginDir, recursive: true)
    File.writeTo(pluginDir + "/run.sh", stringToBytes("echo hi"))
    var tool = JsonObject()
    tool.put("name", JsonString(pluginName + "_tool"))
    tool.put("command", JsonString("run.sh"))
    let tools = JsonArray()
    tools.add(tool)
    var obj = JsonObject()
    obj.put("name", JsonString(pluginName))
    obj.put("tools", tools)
    File.writeTo(pluginDir + "/plugin.json", stringToBytes(obj.toJsonString()))
}

@Test
public class CoreTrustTest {

    @TestCase
    public func testParseTrustList(): Unit {
        let text = "# comment\n\n  alice  \nbob\n#another\n"
        let list = parseTrustList(text)
        @Assert(list.size, 2)
        @Assert(list.contains("alice"), true)
        @Assert(list.contains("bob"), true)
    }

    @TestCase
    public func testTrustAdd(): Unit {
        let dir = coreTestTempDir("trust_add")
        let path = dir + "/trusted-publishers"
        // @Assert 对 enum 泛型推断失败，用 match 转 Bool 断言
        let isAdded = match (trustAdd(path, "alice")) {
            case TrustResult.Added => true
            case _ => false
        }
        @Assert(isAdded, true)
        let isDup = match (trustAdd(path, "alice")) {
            case TrustResult.AlreadyTrusted => true
            case _ => false
        }
        @Assert(isDup, true)
        let isEmpty = match (trustAdd(path, "")) {
            case TrustResult.EmptyEntry => true
            case _ => false
        }
        @Assert(isEmpty, true)
        let list = readTrustList(path)
        @Assert(list.size, 1)
        @Assert(list.contains("alice"), true)
        removeTreeForTest(dir)
    }

    @TestCase
    public func testTrustRemove(): Unit {
        let dir = coreTestTempDir("trust_rm")
        let path = dir + "/trusted-publishers"
        trustAdd(path, "alice")
        trustAdd(path, "bob")
        let isRemoved = match (trustRemove(path, "bob")) {
            case TrustResult.Removed => true
            case _ => false
        }
        @Assert(isRemoved, true)
        let isMissing = match (trustRemove(path, "bob")) {
            case TrustResult.NotTrusted => true
            case _ => false
        }
        @Assert(isMissing, true)
        let isEmpty = match (trustRemove(path, "")) {
            case TrustResult.EmptyEntry => true
            case _ => false
        }
        @Assert(isEmpty, true)
        let list = readTrustList(path)
        @Assert(list.size, 1)
        @Assert(list.contains("alice"), true)
        removeTreeForTest(dir)
    }

    @TestCase
    public func testIsTrusted(): Unit {
        var list = ArrayList<String>()
        list.add("github:alice")
        list.add("ABCDEF01")
        // publisher 命中
        @Assert(isTrusted(list, "github:alice", ""), true)
        // publisher 未命中但 pubkey 命中
        @Assert(isTrusted(list, "someone-else", "ABCDEF01"), true)
        // 都未命中
        @Assert(isTrusted(list, "someone-else", "FFFF"), false)
        // 空列表（开放模式前置：isTrusted 本身恒 false，由加载逻辑按 size>0 把关）
        let empty = ArrayList<String>()
        @Assert(isTrusted(empty, "x", "y"), false)
    }

    @TestCase
    public func testReadTrustListMissing(): Unit {
        @Assert(readTrustList("/tmp/cjh_ut_no_such/trusted-publishers").size, 0)
    }

    // 端到端：签名插件在开放/严格模式下的加载行为
    @TestCase
    public func testTrustEnforcementEndToEnd(): Unit {
        let base = coreTestTempDir("trust_e2e")
        coreMakeSignedPlugin(base, "signed-p", "github:alice")
        coreMakePlainPlugin(base, "plain-p")

        // 开放模式（空信任列表）：签名 + 无签名插件都加载
        let reg1 = ToolRegistry()
        let pm1 = PluginManager(base)
        pm1.loadAll(reg1, ArrayList<String>(), false, ArrayList<String>())
        @Assert(reg1.has("signed-p_tool"), true)
        @Assert(reg1.has("plain-p_tool"), true)

        // 严格模式：信任 alice → 签名插件加载，无签名插件拒绝
        var trusted = ArrayList<String>()
        trusted.add("github:alice")
        let reg2 = ToolRegistry()
        let pm2 = PluginManager(base)
        pm2.loadAll(reg2, ArrayList<String>(), false, trusted)
        @Assert(reg2.has("signed-p_tool"), true)
        @Assert(reg2.has("plain-p_tool"), false)

        // 严格模式：信任别人 → 签名插件也拒绝
        var untrusted = ArrayList<String>()
        untrusted.add("github:mallory")
        let reg3 = ToolRegistry()
        let pm3 = PluginManager(base)
        pm3.loadAll(reg3, ArrayList<String>(), false, untrusted)
        @Assert(reg3.has("signed-p_tool"), false)

        removeTreeForTest(base)
    }
}

// ---------------------------------------------------------------------------
// /ref 面板纯函数（TUI 斜杠命令解析 + 联网闸门，见 src/slash_command.cj）
// ---------------------------------------------------------------------------

@Test
public func testRefPanelSubDefaultsToStatus(): Unit {
    @Assert(refPanelSub(["/ref"]), "status")
    @Assert(refPanelSub(["/ref", ""]), "status")
    @Assert(refPanelSub(["/ref", "verify"]), "verify")
    @Assert(refPanelSub(["/ref", "search", "ArrayList"]), "search")
}

@Test
public func testRefPanelStripDropsYesGate(): Unit {
    let a = refPanelStrip(["/ref", "update", "--yes", "--dry-run"])
    @Assert(a.size, 3)
    @Assert(a[0], "ref")
    @Assert(a[1], "update")
    @Assert(a[2], "--dry-run")
    let b = refPanelStrip(["/ref"])
    @Assert(b.size, 1)
    @Assert(b[0], "ref")
}

@Test
public func testRefPanelNeedsConfirmOnlyForNetworkUpdate(): Unit {
    // 只有「未指定离线来源、也未经人确认」的 update 才拦一道
    @Assert(refPanelNeedsConfirm(["/ref", "update"]), true)
    @Assert(refPanelNeedsConfirm(["/ref", "update", "--branch", "b"]), true)
    @Assert(refPanelNeedsConfirm(["/ref", "update", "--yes"]), false)
    @Assert(refPanelNeedsConfirm(["/ref", "update", "--source", "/tmp/x"]), false)
    @Assert(refPanelNeedsConfirm(["/ref", "update", "--source", "/tmp/x", "--dry-run"]), false)
    // 纯本地动作一律不拦
    @Assert(refPanelNeedsConfirm(["/ref", "status"]), false)
    @Assert(refPanelNeedsConfirm(["/ref", "search", "ArrayList"]), false)
    @Assert(refPanelNeedsConfirm(["/ref", "rebuild"]), false)
    @Assert(refPanelNeedsConfirm(["/ref", "verify"]), false)
}

@Test
public func testRefPanelOptionOfReadsValueOrDefault(): Unit {
    let a = ["/ref", "update", "--repo", "https://example.com/r", "--branch", "dev"]
    @Assert(refPanelOptionOf(a, "--repo", "d"), "https://example.com/r")
    @Assert(refPanelOptionOf(a, "--branch", "d"), "dev")
    @Assert(refPanelOptionOf(a, "--source", "fallback"), "fallback")
    // 选项在末尾但没有值时退回默认
    @Assert(refPanelOptionOf(["/ref", "update", "--repo"], "--repo", "dft"), "dft")
}

@Test
public func testRefPanelConfirmTextShowsPlanAndGate(): Unit {
    let t = refPanelConfirmText(["/ref", "update"], "/tmp/corpus")
    @Assert(t.contains("/tmp/corpus"), true)
    @Assert(t.contains("CangjieSkills"), true)
    @Assert(t.contains("cangjie-1.0.5"), true)
    @Assert(t.contains("--yes"), true)
    let t2 = refPanelConfirmText(["/ref", "update", "--repo", "https://x/y", "--branch", "b9"], "/d")
    @Assert(t2.contains("https://x/y"), true)
    @Assert(t2.contains("b9"), true)
}

@Test
public func testCliVersionTextMatchesLogoVersion(): Unit {
    // 防漂移：--version 输出与 cjterm 的 Logo.VERSION 同源。
    // 发版只改 cjpm.toml 而漏改 Logo.VERSION（或反之）时这两处会打架，
    // 与 WebVersionSyncTest 一样靠测试兜住。
    let text = cliVersionText()
    @Assert(text, "cjh " + Logo.VERSION)
    // Logo.VERSION 带 v 前缀（titlebar 展示用），--version 沿用同一形态
    @Assert(text.startsWith("cjh v"), true)
    @Assert(text.size > 6, true)
}

@Test
public func testCliVersionTextIsSingleLine(): Unit {
    // --version 必须是单行、无多余空白，脚本可直接解析比较
    let text = cliVersionText()
    @Assert(text.contains("\n"), false)
    @Assert(text.contains("  "), false)
    @Assert(text.endsWith(" "), false)
}

@Test
public func testCliHelpTextCoversDispatchFlags(): Unit {
    // 帮助文本要与 main() 的参数分派一一对应：新增入口漏写帮助会被这条挡住
    let help = cliHelpText()
    let flags = [
        "--version", "--help", "--resume", "--list", "--cli",
        "--mode", "--mock", "web", "ref", "trust", "untrust", "trust-list"
    ]
    for (f in flags) {
        @Assert(help.contains(f), true)
    }
}

@Test
public func testCliHelpTextMentionsConfigAndCredentialPaths(): Unit {
    // 凭据只写 auth.json 是项目硬约束，帮助里必须点明这两个路径
    let help = cliHelpText()
    @Assert(help.contains("~/.cjh/config.json"), true)
    @Assert(help.contains("~/.cjh/auth.json"), true)
    @Assert(help.contains("https://github.com/yangyongzhen/cjh"), true)
}

// ==================== 并行子代理 + 上下文隔离（方案 §5-§7） ====================

/**
 * 父代理脚本 provider（S2 后父与子不再共享实例）：
 * call 1 → 派 task 工具调用；call 2+ → 最终答复。
 * spawnTwice=true 时 call 2 再派一个 task（供"每子代理独立 provider"用例）。
 */
class SubagentScriptProvider <: LlmProvider {
    public var spawnTwice: Bool = false
    public var callCount: Int64 = 0

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        if (callCount == 1 || (this.spawnTwice && callCount == 2)) {
            var calls = ArrayList<ToolCall>()
            var a = JsonObject()
            a.put("description", JsonString("调查任务"))
            a.put("prompt", JsonString("查一下"))
            a.put("subagent_type", JsonString("explore"))
            calls.add(ToolCall("t1", "task", a))
            return ModelResponse("派发子代理", calls)
        }
        return ModelResponse("parent done", ArrayList<ToolCall>())
    }
}

/**
 * 子代理脚本 provider（S2：由工厂每次派生新建实例，模拟真实接线）：
 * 首次调用捕获简报（最后一条 user 消息），按 childBehavior 行动：
 * 0=正常文本答复；1=调 read_file（配 capability 触发审批）；2=抛异常。
 */
class SubChildProvider <: LlmProvider {
    public var childBehavior: Int64 = 0
    public var callCount: Int64 = 0
    public var lastChildUser: String = ""
    public var aborted: Bool = false

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        callCount += 1
        var i = messages.size - 1
        while (i >= 0) {
            if (messages[i].role == "user") {
                this.lastChildUser = messages[i].content
                break
            }
            i -= 1
        }
        match (this.childBehavior) {
            case 1 =>
                var calls = ArrayList<ToolCall>()
                var a = JsonObject()
                a.put("path", JsonString("/tmp/cjh_ut_sub/x.cj"))
                calls.add(ToolCall("s1", "read_file", a))
                return ModelResponse("读一下", calls)
            case 2 =>
                throw LlmException("子代理模拟异常")
            case 3 =>
                // S4 超时用例：每轮 300ms（> 测试超时上限 100ms）
                sleep(Duration.millisecond * 300)
                return ModelResponse("child done slow", ArrayList<ToolCall>())
            case _ =>
                return ModelResponse("child done", ArrayList<ToolCall>())
        }
    }

    public override func abort(): Unit {
        this.aborted = true
    }
}

/** 子代理 provider 工厂（S2 测试用）：每次派生新建实例并记录，供实例隔离断言 */
class SubChildFactory {
    public var childBehavior: Int64 = 0
    public let created = ArrayList<SubChildProvider>()

    public func make(): LlmProvider {
        let p = SubChildProvider()
        p.childBehavior = this.childBehavior
        this.created.add(p)
        return p
    }
}

@Test
public class SubagentIsolationTest {

    // 组装父 agent + 全量 registry（含 task / todo_write），TaskTool 已接线 spawnSubagent
    private func buildParent(provider: LlmProvider, cap: Capability):
        (Agent, ToolRegistry, AgentConfig) {
        return this.buildParent(provider, cap, SubChildFactory())
    }

    // S2 重载：子代理 provider 由工厂每次派生新建（模拟真实接线），created 供隔离断言
    private func buildParent(provider: LlmProvider, cap: Capability, factory: SubChildFactory):
        (Agent, ToolRegistry, AgentConfig) {
        let registry = ToolRegistry()
        registry.register(ReadTool())
        registry.register(GrepTool())
        registry.register(WriteTool())
        registry.register(BashTool())
        registry.register(TodoWriteTool(
            { _ => 1 }, { _ => () }, { _ => () }, { _, _ => () }, { => () }, { => "Tasks:" }))
        let config = AgentConfig("parent system", 5, cap, 0, 0, 6, 6000,
            "/tmp/cjh_ut_sub_spill", "sess-sub")
        let agent = Agent(provider, registry, config)
        registry.register(TaskTool({ d, p, t =>
            spawnSubagent(factory.make(), registry, agent, config, d, p, t)
        }))
        return (agent, registry, config)
    }

    private func lastToolResult(msgs: ArrayList<ChatMessage>, name: String): String {
        var found = ""
        for (m in msgs) {
            if (m.role == "tool" && m.name == name) {
                found = m.content
            }
        }
        return found
    }

    @TestCase
    public func testSubagentRegistryView(): Unit {
        // G2/G3/G4：explore 只读视图物理不可达写工具；worker 全量但剥离 task/todo_write
        let (_, registry, _) = this.buildParent(SubagentScriptProvider(), Capability())
        let explore = buildSubagentRegistry(registry, "explore")
        @Assert(explore.has("read_file"), true)
        @Assert(explore.has("grep"), true)
        @Assert(explore.has("write_file"), false)
        @Assert(explore.has("bash"), false)
        @Assert(explore.has("task"), false)
        @Assert(explore.has("todo_write"), false)
        let worker = buildSubagentRegistry(registry, "worker")
        @Assert(worker.has("read_file"), true)
        @Assert(worker.has("write_file"), true)
        @Assert(worker.has("bash"), true)
        @Assert(worker.has("task"), false)
        @Assert(worker.has("todo_write"), false)
    }

    @TestCase
    public func testSubagentConfigInheritsCapabilityAndIsolatesSpill(): Unit {
        // G1 capability 继承（子 ⊆ 父）+ G6 spill 落盘按 /sub-<type> 隔离
        let cap = Capability()
        cap.enabled = true
        cap.tools.add("read_file")
        let (_, _, config) = this.buildParent(SubagentScriptProvider(), cap)
        let sub = buildSubagentConfig(config, "explore")
        @Assert(sub.capability.enabled == true, true)
        @Assert(sub.capability.tools.size == 1, true)
        @Assert(sub.capability.tools[0] == "read_file", true)
        // 短生命周期：maxIterations=5，compaction 关闭
        @Assert(sub.maxIterations == 5, true)
        @Assert(sub.compactThreshold == 0, true)
        @Assert(sub.compactTokenThreshold == 0, true)
        @Assert(sub.sessionId == "sess-sub/sub-explore", true)
        @Assert(sub.spillDir == "/tmp/cjh_ut_sub_spill", true)
        @Assert(sub.toolResultMaxChars == config.toolResultMaxChars, true)
    }

    @TestCase
    public func testSpawnSubagentOkStatusAndBrief(): Unit {
        let provider = SubagentScriptProvider()
        let factory = SubChildFactory()
        let (agent, _, _) = this.buildParent(provider, Capability(), factory)
        // 预置父历史（assistant toolCalls 与 tool 结果配对，否则 repairHistory 会剥孤儿
        // tool 消息）→ 简报摘要应携带该路径（D1 上下文块）
        var history = ArrayList<ChatMessage>()
        history.add(ChatMessage("user", "主任务"))
        var hc = ArrayList<ToolCall>()
        var ha = JsonObject()
        ha.put("path", JsonString("/tmp/cjh_ut_sub/main.cj"))
        hc.add(ToolCall("h1", "read_file", ha))
        history.add(ChatMessage("assistant", "读主文件", hc))
        history.add(ChatMessage("tool", "已读取 /tmp/cjh_ut_sub/main.cj 的内容", "h1", "read_file"))
        agent.loadHistory(history)

        let summary = agent.run("派个子任务")
        @Assert(summary.reply.contains("parent done"), true)
        // 简报：子任务 prompt + 父会话上下文块（摘要里的涉及文件）
        @Assert(factory.created.size, 1)
        @Assert(factory.created[0].lastChildUser.contains("查一下"), true)
        @Assert(factory.created[0].lastChildUser.contains("--- 父会话上下文"), true)
        @Assert(factory.created[0].lastChildUser.contains("/tmp/cjh_ut_sub/main.cj"), true)
        // 树状结果：ok 状态 + 树形头尾（#8）
        let taskResult = this.lastToolResult(agent.getMessages(), "task")
        @Assert(taskResult.contains("├─ [explore] 调查任务 · ok · 迭代 1"), true)
        @Assert(taskResult.contains("└─ (task 结束)"), true)
        // S5(c) 事后纠偏：1 轮完成 + 结论 10 字符（<200）→ 尾部挂 [路由提示]
        @Assert(taskResult.contains("[路由提示]"), true)
        @Assert(taskResult.contains("请直接处理"), true)
    }

    @TestCase
    public func testTaskToolRoutingOff(): Unit {
        // S5(d)：/parallel off → task 派发物理关闭（execute 直接拒绝，不进 spawnFn）
        let old = SubagentRouting.current()
        SubagentRouting.set("off")
        // 仓颉 lambda 不能捕获可变局部变量：ArrayList 包装哨兵
        let spawned = ArrayList<Bool>()
        spawned.add(false)
        let tool = TaskTool({ _, _, _ =>
            spawned[0] = true
            TaskSpawnResult("不应到达", 0, 0, 0, "ok")
        })
        var a = JsonObject()
        a.put("description", JsonString("x"))
        a.put("prompt", JsonString("y"))
        a.put("subagent_type", JsonString("explore"))
        let r = tool.execute(a)
        SubagentRouting.set(old)  // 恢复（静态状态，别的用例还要用）
        @Assert(r.isError, false)
        @Assert(r.content.contains("并行子代理已关闭"), true)
        @Assert(spawned[0], false)
    }

    @TestCase
    public func testSpawnSubagentFailedStatus(): Unit {
        // 子代理 LLM 调用抛异常 → 结构化 failed 回传，父回合不受影响继续完成
        let provider = SubagentScriptProvider()
        let factory = SubChildFactory()
        factory.childBehavior = 2
        let (agent, _, _) = this.buildParent(provider, Capability(), factory)
        let summary = agent.run("派失败子任务")
        @Assert(summary.reply.contains("parent done"), true)
        let taskResult = this.lastToolResult(agent.getMessages(), "task")
        @Assert(taskResult.contains("· failed"), true)
        @Assert(taskResult.contains("└─ (task 结束)"), true)
    }

    @TestCase
    public func testSpawnSubagentApprovalPropagation(): Unit {
        // G5：子代理审批经父通道，reason 带 [task:label] 前缀（TUI/WS 展示 reason，协议零变更）
        let cap = Capability()
        cap.enabled = true
        cap.tools.add("task")
        cap.tools.add("read_file")
        cap.approval.add("read_file")
        let provider = SubagentScriptProvider()
        let factory = SubChildFactory()
        factory.childBehavior = 1
        let (agent, _, _) = this.buildParent(provider, cap, factory)
        let seen = ArrayList<String>()
        agent.onApproval = { _, _, reason =>
            seen.add(reason)
            false
        }
        let summary = agent.run("派审批子任务")
        @Assert(summary.reply.contains("parent done"), true)
        @Assert(seen.size > 0, true)
        @Assert(seen[0].contains("[task:调查任务]"), true)
        @Assert(seen[0].contains("read_file"), true)
    }

    @TestCase
    public func testSpawnSubagentProvidersNotShared(): Unit {
        // S2（评审 P0-2）：每次派生新建 provider 实例——OpenAiProvider.currentTransport
        // 是单槽，共享实例时并发子代理的 abort() 会关到别人的连接
        let provider = SubagentScriptProvider()
        provider.spawnTwice = true
        let factory = SubChildFactory()
        let (agent, _, _) = this.buildParent(provider, Capability(), factory)
        let summary = agent.run("连派两个子任务")
        @Assert(summary.reply.contains("parent done"), true)
        // 两次派生 → 工厂创建 2 个实例（互不共享），父 provider 不被子代理调用
        @Assert(factory.created.size, 2)
        @Assert(factory.created[0].callCount, 1)
        @Assert(factory.created[1].callCount, 1)
        @Assert(provider.callCount, 3)  // 父：task → task → final
    }

    @TestCase
    public func testSpawnSubagentBudgetExceeded(): Unit {
        // S4：本回合派生上限触顶 → 后续派生结构化 budget_exceeded（子代理不运行）
        let provider = SubagentScriptProvider()
        provider.spawnTwice = true
        let factory = SubChildFactory()
        let (agent, _, _) = this.buildParent(provider, Capability(), factory)
        agent.subagentScheduler = Some(SubagentScheduler(4, 1, 0, 0))  // 每回合只许派 1 个
        let summary = agent.run("连派两个子任务")
        @Assert(summary.reply.contains("parent done"), true)
        let taskResult = this.lastToolResult(agent.getMessages(), "task")
        @Assert(taskResult.contains("· budget_exceeded"), true)
        @Assert(taskResult.contains("请直接处理本任务"), true)
        // factory.make() 是 spawnSubagent 的实参（求值先于闸门），实例会建但子代理不运行：
        @Assert(factory.created.size, 2)
        @Assert(factory.created[1].callCount, 0)  // 第二个派生被闸门拦下，LLM 一次未调
    }

    @TestCase
    public func testSpawnSubagentTimeout(): Unit {
        // S4：墙钟超时 → 结构化 timeout（子代理 300ms/轮 > 100ms 上限）
        let provider = SubagentScriptProvider()
        let factory = SubChildFactory()
        factory.childBehavior = 3
        let (agent, _, _) = this.buildParent(provider, Capability(), factory)
        agent.subagentScheduler = Some(SubagentScheduler(4, 0, 0, 100))
        let summary = agent.run("派慢子任务")
        @Assert(summary.reply.contains("parent done"), true)
        let taskResult = this.lastToolResult(agent.getMessages(), "task")
        @Assert(taskResult.contains("· timeout"), true)
        @Assert(taskResult.contains("已中断并回收引用"), true)
    }
}
