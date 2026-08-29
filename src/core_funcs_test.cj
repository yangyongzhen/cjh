package cjh

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*
import cjh.tools.*

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
        @Assert(result.content.contains("迭代次数: 3"), true)
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
