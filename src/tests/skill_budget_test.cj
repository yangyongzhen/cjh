package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import cjh.tools.*
import cjh.web.*

/**
 * 技能索引预算（替代旧的正文注入）：system prompt 只放「名称 + 描述」，
 * 超预算必须整条跳过并如实上报，正文由 skill_load 按需读取。
 */
@Test
public class SkillBudgetPlanTest {

    private func cand(name: String, description: String, body: String, enabled: Bool): SkillCandidate {
        return SkillCandidate(name, description, body, "", enabled, "/tmp/${name}.md")
    }

    private func candidates(): ArrayList<SkillCandidate> {
        let list = ArrayList<SkillCandidate>()
        list.add(cand("zz-small", "SMALL", "ZZ-BODY", true))
        list.add(cand("aa-big", repeatStr("B", 500), repeatStr("A", 200), true))
        list.add(cand("mm-off", "OFF", "OFF-BODY", false))
        list.add(cand("nn-empty", "EMPTY", "", true))
        return list
    }

    @TestCase
    public func testDeterministicOrderAndWholeSkillOnly(): Unit {
        let result = planSkillIndex(candidates(), Int64.Max)
        let (text, statuses) = result
        // 排序与传入顺序无关：aa-big, mm-off, nn-empty, zz-small
        @Assert(statuses[0].name, "aa-big")
        @Assert(statuses[1].name, "mm-off")
        @Assert(statuses[2].name, "nn-empty")
        @Assert(statuses[3].name, "zz-small")
        // 未启用/空正文有明确原因，不算静默丢失
        @Assert(statuses[1].reason, "disabled")
        @Assert(statuses[2].reason, "empty")
        @Assert(text.contains("- **zz-small**: SMALL"), true)
        @Assert(text.contains("BIG"), false)  // 长描述条目在默认预算下也会完整判断
        // 正文绝不进入索引
        @Assert(text.contains("ZZ-BODY"), false)
        @Assert(text.contains("OFF-BODY"), false)
        @Assert(text.contains("AAAA"), false)
        @Assert(text.contains("### Skill:"), false)
    }

    @TestCase
    public func testOverBudgetSkipsWholeEntryAndKeepsLaterOne(): Unit {
        // aa-big 的索引行约 514 B，装不下；zz-small 约 22 B，仍应列出
        let result = planSkillIndex(candidates(), 80)
        let (text, statuses) = result
        @Assert(text.contains("- **zz-small**: SMALL"), true)
        @Assert(text.contains("BBBB"), false)  // 没有任何被切断的描述
        @Assert(statuses[0].name, "aa-big")
        @Assert(statuses[0].injected, false)
        @Assert(statuses[0].reason, "over_budget")
        @Assert(statuses[0].bodyBytes, 200)
        @Assert(statuses[3].name, "zz-small")
        @Assert(statuses[3].injected, true)
    }

    @TestCase
    public func testZeroBudgetInjectsNothing(): Unit {
        let result = planSkillIndex(candidates(), 0)
        let (text, statuses) = result
        @Assert(text, "")
        for (s in statuses) {
            @Assert(s.injected, false)
        }
    }

    @TestCase
    public func testBudgetCountsWholeIndexLine(): Unit {
        let one = ArrayList<SkillCandidate>()
        one.add(cand("aa-big", "d", "0123456789", true))
        let line = "- **aa-big**: d"
        let tight = planSkillIndex(one, line.size - 1)
        let (tightText, _) = tight
        @Assert(tightText, "")
        let exact = planSkillIndex(one, line.size)
        let (exactText, exactStatuses) = exact
        @Assert(exactText, line)
        @Assert(exactStatuses[0].injected, true)
        @Assert(exactStatuses[0].indexBytes, line.size)
        @Assert(exactStatuses[0].bodyBytes, 10)
    }
}

/**
 * GET /api/skills 的数据源：injected/reason/bytes/index_bytes 必须与索引规划一致。
 */
@Test
public class SkillListJsonTest {

    private func readStr(obj: JsonObject, key: String): String {
        return obj.get(key).getOrThrow().asString().getValue()
    }

    private func readBool(obj: JsonObject, key: String): Bool {
        return obj.get(key).getOrThrow().asBool().getValue()
    }

    private func readInt(obj: JsonObject, key: String): Int64 {
        return obj.get(key).getOrThrow().asInt().getValue()
    }

    @TestCase
    public func testReportsInjectedAndOverBudget(): Unit {
        let dir = testTempDir("skills_list_json")
        let bigDesc = repeatStr("大", 80)
        writeTextFile(dir + "/big.md",
            "---\nname: aa-big\ndescription: ${bigDesc}\n---\n" + repeatStr("A", 501))
        writeTextFile(dir + "/small.md",
            "---\nname: zz-small\ndescription: 小技能\n---\nSMALL")
        try {
            var enabled = ArrayList<String>()
            let arr = buildSkillListJson(dir, enabled, 100)
            @Assert(arr.size(), 2)
            // 输出顺序与索引顺序一致（技能名升序）
            let big = arr.get(0).getOrThrow().asObject()
            @Assert(readStr(big, "name"), "aa-big")
            @Assert(readStr(big, "description"), bigDesc)
            @Assert(readBool(big, "injected"), false)
            @Assert(readStr(big, "reason"), "over_budget")
            // bytes=正文体积（按需 skill_load），index_bytes=索引整行体积
            @Assert(readInt(big, "bytes"), 501)
            @Assert(readInt(big, "index_bytes") > 100, true)
            let small = arr.get(1).getOrThrow().asObject()
            @Assert(readStr(small, "name"), "zz-small")
            @Assert(readBool(small, "injected"), true)
            @Assert(readStr(small, "reason"), "")
            @Assert(readInt(small, "bytes"), 5)
            @Assert(readInt(small, "index_bytes") > 0, true)
            @Assert(readInt(small, "index_bytes") < 100, true)
        } finally {
            removeTree(dir)
        }
    }

    @TestCase
    public func testDisabledSkillListedButNotInjected(): Unit {
        let dir = testTempDir("skills_list_disabled")
        writeTextFile(dir + "/one.md", "---\nname: one\ndescription: 关闭\n---\nONE")
        try {
            var enabled = ArrayList<String>()
            enabled.add("other")
            let arr = buildSkillListJson(dir, enabled, Int64.Max)
            @Assert(arr.size(), 1)
            let one = arr.get(0).getOrThrow().asObject()
            @Assert(readBool(one, "enabled"), false)
            @Assert(readBool(one, "injected"), false)
            @Assert(readStr(one, "reason"), "disabled")
        } finally {
            removeTree(dir)
        }
    }
}
