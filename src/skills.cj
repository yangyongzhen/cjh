package cjh

/**
 * Skills 子系统：技能文件扫描、frontmatter 解析、指令注入、声明式工具注册
 *
 * 技能形态：~/.cjh/skills/<name>.md，frontmatter 声明 name/description/tools，
 * 正文为注入 system prompt 的指令文本。
 */

import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.io.*
import stdx.encoding.json.*
import cjh.agent.*
import cjh.tools.*
import cjh.tui.*
import cjterm.*
import cjutil.*

/**
 * 加载项目指令（AGENTS.md）：从当前目录向上逐级查找，最多 8 层
 */
func loadProjectInstructions(): String {
    var dir = getWorkingDirectory()
    var depth: Int64 = 0
    while (depth < 8) {
        let p = dir.toString() + "/AGENTS.md"
        if (exists(p)) {
            try {
                let content = safeFromUtf8(File.readFrom(p))
                if (content.size > 0) {
                    return content
                }
            } catch (e: Exception) {
                ()
            }
        }
        let parent = dir.parent
        if (parent.toString() == dir.toString()) {
            break
        }
        dir = parent
        depth += 1
    }
    return ""
}

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
 * 列示技能（/skills 命令）：扫描 ~/.cjh/skills/<name>.md，输出名称、启用状态、
 * 前端声明的描述与携带工具数；无技能目录时提示创建方法。
 */
func listSkills(skillsDir: String, enabled: ArrayList<String>, tui: TuiApp): Unit {
    if (!exists(skillsDir)) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[技能目录不存在: ${skillsDir}；创建 ~/.cjh/skills/<name>.md 即可启用]" + Ansi.reset())
        return
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    if (files.size == 0) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[无技能；创建 ~/.cjh/skills/<name>.md（frontmatter: name/description + 正文指令）]" + Ansi.reset())
        return
    }
    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用技能（settings.json 的 enabled_skills 白名单控制开关，空=全部启用）：" + Ansi.reset())
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            var name = f[0..f.size - 3]
            var desc = ""
            var toolCount: Int64 = 0
            if (content.startsWith("---")) {
                let endFm = content.indexOf("\n---")
                if (endFm.isSome()) {
                    let fm = content[3..endFm.getOrThrow()]
                    let fields = parseFrontmatter(fm)
                    if (let Some(v) <- fields.get("name")) {
                        if (v.size > 0) {
                            name = v
                        }
                    }
                    if (let Some(v) <- fields.get("description")) {
                        if (v.size > 0) {
                            desc = v
                        }
                    }
                    if (let Some(v) <- fields.get("tools")) {
                        // 统计 tools JSON 数组里的对象数
                        toolCount = countSkillTools(v)
                    }
                }
            }
            let state = if (skillEnabled(name, enabled)) {
                Ansi.fg(Ansi.THEME_OK) + "● 启用" + Ansi.reset()
            } else {
                Ansi.fg(Ansi.THEME_MUTED) + "○ 禁用" + Ansi.reset()
            }
            var line = "  ${state} ${name}"
            if (desc.size > 0) {
                line += " — ${desc}"
            }
            if (toolCount > 0) {
                line += Ansi.fg(Ansi.THEME_MUTED) + " [${toolCount} 个声明式工具]" + Ansi.reset()
            }
            tui.appendOutput(line)
        } catch (e: Exception) {
            ()
        }
    }
    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "示例：/skills 查看；编辑 ~/.cjh/settings.json 的 enabled_skills 数组切换开关" + Ansi.reset())
}

/**
 * 加载技能（Skills，对齐 pi 的按需能力包）：
 * 扫描 ~/.cjh/skills/<name>.md（v2 4.3c"技能即文件"：Markdown 文本资产，
 * frontmatter 声明 name/description + 正文为指令），把所有技能指令拼接返回；
 * 目录不存在或无技能返回 ""。技能指令注入 system prompt（按需能力，不破缓存）。
 */
public func loadSkills(skillsDir: String, enabled: ArrayList<String>): String {
    if (!exists(skillsDir)) {
        return ""
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    if (files.size == 0) {
        return ""
    }
    var sb = StringBuilder()
    var count: Int64 = 0
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            if (content.size == 0) {
                continue
            }
            // 提取 frontmatter：---\nname: xxx\ndescription: xxx\n---\n正文
            var name = f[0..f.size - 3]  // 去 .md
            var body = content
            if (content.startsWith("---")) {
                let endFm = content.indexOf("\n---")
                if (endFm.isSome()) {
                    let fmEnd = endFm.getOrThrow()
                    let fm = content[3..fmEnd]
                    let fields = parseFrontmatter(fm)
                    if (let Some(v) <- fields.get("name")) {
                        if (v.size > 0) {
                            name = v
                        }
                    }
                    body = content[fmEnd + 4..content.size].trimAscii()
                }
            }
            // 白名单过滤：未启用的技能不注入
            if (!skillEnabled(name, enabled)) {
                continue
            }
            if (body.size == 0) {
                continue
            }
            if (count > 0) {
                sb.append("\n\n")
            }
            sb.append("### 技能：${name}\n")
            sb.append(body)
            count += 1
        } catch (e: Exception) {
            ()
        }
    }
    return sb.toString()
}

/**
 * 解析 tools JSON 数组并注册声明式工具
 */
func registerSkillTools(jsonStr: String, registry: ToolRegistry): Unit {
    try {
        let v = JsonValue.fromStr(jsonStr)
        match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    if (let Some(item) <- arr.get(i)) {
                        match (item.kind()) {
                            case JsonKind.JsObject =>
                                let obj = item.asObject()
                                let name = obj.get("name").getOrThrow().asString().getValue()
                                let desc = obj.get("description").getOrThrow().asString().getValue()
                                let cmd = obj.get("command").getOrThrow().asString().getValue()
                                // 参数 schema（可选）：args: {"argName": "描述"}
                                var argSpecs = HashMap<String, (String, String)>()
                                if (let Some(av) <- obj.get("args")) {
                                    match (av.kind()) {
                                        case JsonKind.JsObject =>
                                            let ao = av.asObject()
                                            for ((k, sv) in ao.getFields()) {
                                                match (sv.kind()) {
                                                    case JsonKind.JsString =>
                                                        argSpecs.add(k, ("string", sv.asString().getValue()))
                                                    case _ => ()
                                                }
                                            }
                                        case _ => ()
                                    }
                                }
                                let tool = DeclarativeTool(name, desc, cmd, argSpecs)
                                registry.register(tool)
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
    } catch (e: Exception) {
        ()
    }
}

/**
 * 加载技能携带的声明式工具（对齐 v2 4.3b 声明式形态）：
 * 技能 frontmatter 的 tools 段为 JSON 数组，每项 {name, description, command, args?}，
 * 注册为 DeclarativeTool（shell 模板 + 参数 schema，低门槛）。
 * 无 tools 段或解析失败则跳过该技能；技能目录不存在时静默。
 */
func loadSkillTools(skillsDir: String, registry: ToolRegistry, enabled: ArrayList<String>): Unit {
    if (!exists(skillsDir)) {
        return
    }
    let files = ArrayList<String>()
    Directory.walk(skillsDir, { fi =>
        if (fi.name.endsWith(".md")) {
            files.add(fi.name)
        }
        return true
    })
    for (f in files) {
        try {
            let content = safeFromUtf8(File.readFrom(skillsDir + "/" + f))
            if (content.size == 0 || !content.startsWith("---")) {
                continue
            }
            let endFm = content.indexOf("\n---")
            if (endFm.isNone()) {
                continue
            }
            let fm = content[3..endFm.getOrThrow()]
            let fields = parseFrontmatter(fm)
            // 技能名（frontmatter name 或文件名去 .md），白名单过滤
            var name = f[0..f.size - 3]
            if (let Some(v) <- fields.get("name")) {
                if (v.size > 0) {
                    name = v
                }
            }
            if (!skillEnabled(name, enabled)) {
                continue
            }
            // frontmatter 的 tools 段（多行 JSON 数组），注册声明式工具
            if (let Some(toolsStr) <- fields.get("tools")) {
                if (toolsStr.size > 0) {
                    registerSkillTools(toolsStr, registry)
                }
            }
        } catch (e: Exception) {
            ()
        }
    }
}

/**
 * 组装 system prompt：全局配置 + 项目指令（AGENTS.md）+ 技能（Skills）
 */
func buildSystemPrompt(base: String, skillsDir: String, enabled: ArrayList<String>): String {
    var s = base
    let instr = loadProjectInstructions()
    if (instr.size > 0) {
        s += "\n\n## 项目指令（AGENTS.md）\n" + instr
    }
    let skills = loadSkills(skillsDir, enabled)
    if (skills.size > 0) {
        s += "\n\n## 可用技能（Skills，按需使用）\n" + skills
    }
    // 工具结果截断与回溯（对标 Pi spill extension）
    s += "\n\n## 工具结果截断\n当工具返回的结果过长时，cjh 会自动截断：保留结果的头部和尾部，"
    s += "中间被截断的部分会保存到磁盘文件。省略标记里会显示完整结果的保存路径。\n"
    s += "如果你需要查看被截断的中间部分，请使用 read_file 工具读取省略标记中提到的文件路径。"
    s += "你可以指定 offset 和 limit 参数来读取特定区段。"
    return s
}
