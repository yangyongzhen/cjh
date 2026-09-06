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
        @Assert(result.content.contains("子代理结果"), true)
        @Assert(result.content.contains("迭代 3"), true)
        @Assert(result.content.contains("=== 子代理结果结束 ==="), true)
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
