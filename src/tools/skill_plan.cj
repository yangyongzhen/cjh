package cjh.tools

/**
 * 技能索引规划与技能文件扫描。
 *
 * 渐进披露（progressive disclosure）：
 * - system prompt 只放「名称 + 描述」索引，正文不进入提示词；
 * - 模型按任务调用 `skill_load(name)` 取回完整正文；
 * - 索引预算按整行计算：装不下的整条跳过，绝不从描述/正文中间截断。
 *
 * 扫描逻辑集中在此，供根包（prompt / slash 命令）和 cjh.web（/api/skills）共用，
 * 避免三处各自解析 frontmatter 产生口径差异。
 */

import std.collection.*
import std.fs.*
import std.sort.*
import stdx.encoding.json.*
import cjutil.*

/**
 * 解析 Markdown frontmatter（--- 之间的 YAML 子集）。
 * 返回字段名 → 原始值字符串的 map。支持两种形态：
 *   1) 单行标量：`name: xxx` → value = "xxx"
 *   2) 多行块：`tools:` 单独成行，其后到下一个顶级 key 或 frontmatter
 *      结束的所有行合并为 value（保留 JSON 数组字面量）
 * 标量值做 trimAscii；多行块保留原始缩进与换行，由调用方按 JSON 解析。
 */
public func parseFrontmatter(fm: String): HashMap<String, String> {
    let result = HashMap<String, String>()
    let lines = fm.split("\n", -1)
    var i = 0
    while (i < lines.size) {
        let line = lines[i]
        let t = line.trimAscii()
        if (t.size == 0 || t.startsWith("#")) {
            i += 1
            continue
        }
        // key: value 单行形态
        let colon = t.indexOf(":")
        if (colon.isSome()) {
            let key = t[0..colon.getOrThrow()].trimAscii()
            let rest = t[colon.getOrThrow() + 1..t.size].trimAscii()
            if (rest.size > 0) {
                // 单行标量：key: value
                result.add(key, rest)
                i += 1
            } else {
                // 多行块：key: 单独成行，后续缩进行合并
                var sb = StringBuilder()
                var j = i + 1
                var gathered: Bool = false
                while (j < lines.size) {
                    let nl = lines[j]
                    let nt = nl.trimAscii()
                    // 空行或注释跳过
                    if (nt.size == 0) {
                        j += 1
                        continue
                    }
                    // 下一个顶级 key（非缩进、含冒号）则结束块
                    let nColon = nt.indexOf(":")
                    if (nColon.isSome() && nl.size > 0 && nl[0] != 32u8 /* ' ' */ && nl[0] != 9u8 /* '\t' */) {
                        break
                    }
                    // 缩进行：合并（保留 trimAscii 后内容，换行分隔）
                    if (gathered) {
                        sb.append("\n")
                    }
                    sb.append(nt)
                    gathered = true
                    j += 1
                }
                if (gathered) {
                    result.add(key, sb.toString())
                }
                i = j
            }
        } else {
            i += 1
        }
    }
    return result
}

/**
 * 统计 frontmatter tools 段里声明的工具数（JSON 数组长度）。
 * 解析失败或非数组返回 0。
 */
public func countSkillTools(toolsStr: String): Int64 {
    try {
        let v = JsonValue.fromStr(toolsStr)
        match (v.kind()) {
            case JsonKind.JsArray => return Int64(v.asArray().size())
            case _ => return 0
        }
    } catch (e: Exception) {
        return 0
    }
}

/**
 * 技能是否启用（enabledSkills 空=全部启用；非空=白名单）
 */
public func skillEnabled(name: String, enabled: ArrayList<String>): Bool {
    if (enabled.size == 0) {
        return true
    }
    for (e in enabled) {
        if (e == name) {
            return true
        }
    }
    return false
}

/**
 * 一份已解析的技能文件。
 *
 * path 用于 skill_load 回显来源；toolsJson 保留原始数组字面量，供声明式工具注册。
 */
public struct SkillCandidate {
    public let name: String
    public let description: String
    public let body: String
    public let toolsJson: String
    public let enabled: Bool
    public let path: String

    public init(name: String, description: String, body: String, toolsJson: String, enabled: Bool, path: String) {
        this.name = name
        this.description = description
        this.body = body
        this.toolsJson = toolsJson
        this.enabled = enabled
        this.path = path
    }
}

/**
 * 技能索引中一条技能的规划结果。
 *
 * bodyBytes = 正文大小（真正按需加载的体积）；
 * indexBytes = 该技能在索引里占用的整行字节数（含名称/描述/格式符）。
 */
public struct SkillInjection {
    public let name: String
    public let bodyBytes: Int64
    public let indexBytes: Int64
    public let injected: Bool
    public let reason: String

    public init(name: String, bodyBytes: Int64, indexBytes: Int64, injected: Bool, reason: String) {
        this.name = name
        this.bodyBytes = bodyBytes
        this.indexBytes = indexBytes
        this.injected = injected
        this.reason = reason
    }
}

/**
 * 扫描技能目录（非递归），按文件名升序返回所有可解析技能。
 * 目录不存在、文件读取失败或正文为空时返回空/跳过，不抛出。
 */
public func scanSkills(skillsDir: String, enabled: ArrayList<String>): ArrayList<SkillCandidate> {
    let out = ArrayList<SkillCandidate>()
    if (!exists(skillsDir)) {
        return out
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (!fi.isDirectory() && fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    sort(files, by: { a, b => a.compare(b) }, stable: true)
    for (f in files) {
        try {
            let path = skillsDir + "/" + f
            let content = safeFromUtf8(File.readFrom(path))
            if (content.size == 0) {
                continue
            }
            // 提取 frontmatter：---\nname: xxx\ndescription: xxx\n---\n正文
            var name = f[0..f.size - 3]  // 去 .md
            var description = ""
            var toolsJson = ""
            var body = content
            if (content.startsWith("---")) {
                let endFm = content.indexOf("\n---")
                if (endFm.isSome()) {
                    let fmEnd = endFm.getOrThrow()
                    let fields = parseFrontmatter(content[3..fmEnd])
                    if (let Some(v) <- fields.get("name")) {
                        if (v.size > 0) {
                            name = v
                        }
                    }
                    if (let Some(v) <- fields.get("description")) {
                        description = v
                    }
                    if (let Some(v) <- fields.get("tools")) {
                        toolsJson = v
                    }
                    body = content[fmEnd + 4..content.size].trimAscii()
                }
            }
            out.add(SkillCandidate(name, description, body, toolsJson, skillEnabled(name, enabled), path))
        } catch (e: Exception) {
            ()
        }
    }
    return out
}

/**
 * 生成索引中的单行文本。无描述时省略冒号，避免空描述占位。
 */
func skillIndexLine(c: SkillCandidate): String {
    if (c.description.size == 0) {
        return "- **${c.name}**"
    }
    return "- **${c.name}**: ${c.description}"
}

/**
 * 规划技能索引（不是正文）。
 *
 * @param candidates 已解析的技能候选（可含未启用/空正文）
 * @param maxBytes system prompt 中技能索引段的字节上限（prompt_skills_max_bytes）
 * @return (索引文本, 每个候选的状态)
 */
public func planSkillIndex(candidates: ArrayList<SkillCandidate>, maxBytes: Int64): (String, ArrayList<SkillInjection>) {
    let ordered = ArrayList<SkillCandidate>()
    for (c in candidates) {
        ordered.add(c)
    }
    sort(ordered, by: { a, b => a.name.compare(b.name) }, stable: true)
    var sb = StringBuilder()
    let statuses = ArrayList<SkillInjection>()
    var used: Int64 = 0
    for (c in ordered) {
        let line = skillIndexLine(c)
        let indexBytes = line.size
        if (!c.enabled) {
            statuses.add(SkillInjection(c.name, c.body.size, indexBytes, false, "disabled"))
            continue
        }
        if (c.body.size == 0) {
            statuses.add(SkillInjection(c.name, c.body.size, indexBytes, false, "empty"))
            continue
        }
        let sepBytes: Int64 = if (used > 0) { 1 } else { 0 }
        if (used + sepBytes + indexBytes > maxBytes) {
            statuses.add(SkillInjection(c.name, c.body.size, indexBytes, false, "over_budget"))
            continue
        }
        if (used > 0) {
            sb.append("\n")
        }
        sb.append(line)
        used += sepBytes + indexBytes
        statuses.add(SkillInjection(c.name, c.body.size, indexBytes, true, ""))
    }
    return (sb.toString(), statuses)
}
