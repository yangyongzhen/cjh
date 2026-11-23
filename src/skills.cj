package cjh

/**
 * Skills 子系统：技能文件扫描、frontmatter 解析、指令注入、声明式工具注册
 *
 * 技能形态：~/.cjh/skills/<name>.md，frontmatter 声明 name/description/tools，
 * 正文为注入 system prompt 的指令文本。
 */

import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*
import cjh.tools.*
import cjh.tui.*
import cjterm.*
import cjutil.*

/**
 * 查找项目指令（AGENTS.md）：从当前目录向上逐级查找，最多 8 层。
 * 返回绝对路径，空串表示未找到。
 */
func findProjectInstructionsPath(): String {
    var dir = getWorkingDirectory()
    var depth: Int64 = 0
    while (depth < 8) {
        let p = dir.toString() + "/AGENTS.md"
        if (exists(p)) {
            return p
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
            sb.append("### Skill: ${name}\n")
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
 * 项目上下文注入上限（字节）。AGENTS.md/技能/记忆都可能很大，
 * 全量拼进 system prompt 会稀释规则、挤占上下文；超限时保留头部 + 源路径。
 */

/**
 * 截断注入段并附来源提示，保证模型仍可通过 read_file 读全文。
 */
func clipPromptSection(text: String, maxBytes: Int64, source: String): String {
    if (text.size <= maxBytes) {
        return text
    }
    return truncateUtf8(text, maxBytes) +
        "\n\n… [truncated by cjh: ${source} exceeds ${maxBytes} bytes; read the source file for the full text]"
}

/**
 * 项目指令按「节」压缩：优先保留规则/安全/测试/构建/命令类小节，再按原文顺序填充。
 *
 * 纯头部截断会把 AGENTS.md 后半段的强制门禁整段丢掉（实测 14 KB 文件 6 KB 上限只留前 43%）。
 * 按小节整段取舍既保住高优先级规则，也不把代码块/列表切一半。
 */
func compactProjectInstructions(text: String, maxBytes: Int64, source: String): String {
    if (text.size <= maxBytes) {
        return text
    }
    let lines = text.split("\n", -1)
    let preamble = StringBuilder()
    let sections = ArrayList<String>()
    var seenHeading = false
    var current = StringBuilder()
    for (i in 0..lines.size) {
        let line = lines[i]
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("#")) {
            if (seenHeading) {
                sections.add(current.toString())
            } else if (current.toString().size > 0) {
                preamble.append(current.toString())
            }
            current = StringBuilder()
            current.append(line)
            current.append("\n")
            seenHeading = true
        } else {
            current.append(line)
            current.append("\n")
        }
    }
    if (seenHeading) {
        sections.add(current.toString())
    } else {
        return clipPromptSection(text, maxBytes, source)
    }
    let chosen = ArrayList<Bool>()
    for (_ in 0..sections.size) {
        chosen.add(false)
    }
    var used: Int64 = 0
    let pre = preamble.toString()
    if (pre.size <= maxBytes / 3) {
        used = pre.size
    }
    // 第一遍只给高优先级小节留位；第二遍用剩余预算按原顺序补普通小节。
    for (i in 0..sections.size) {
        if (!chosen[i] && isPriorityPromptSection(sections[i]) && used + sections[i].size <= maxBytes) {
            chosen[i] = true
            used += sections[i].size
        }
    }
    for (i in 0..sections.size) {
        if (!chosen[i] && used + sections[i].size <= maxBytes) {
            chosen[i] = true
            used += sections[i].size
        }
    }
    var kept = 0
    for (i in 0..chosen.size) {
        if (chosen[i]) {
            kept += 1
        }
    }
    if (kept == 0) {
        return clipPromptSection(text, maxBytes, source)
    }
    let sb = StringBuilder()
    if (used > 0 && pre.size <= maxBytes / 3) {
        sb.append(pre)
    }
    for (i in 0..sections.size) {
        if (chosen[i]) {
            sb.append(sections[i])
        }
    }
    let omitted = sections.size - kept
    sb.append("\n… [cjh: ${source} exceeds ${maxBytes} bytes; kept ${kept}/${sections.size} sections")
    if (omitted > 0) {
        sb.append(", omitted ${omitted} lower-priority sections")
    }
    sb.append("; read the source file for the full text]")
    return sb.toString()
}

func isPriorityPromptSection(section: String): Bool {
    let l = section.toAsciiLower()
    let keywords = ["rule", "safety", "security", "must", "never", "forbid", "test", "build",
        "command", "workflow", "contract", "gate", "禁止", "必须", "安全", "测试", "构建", "命令", "规则", "约束"]
    for (i in 0..keywords.size) {
        if (l.contains(keywords[i])) {
            return true
        }
    }
    return false
}

@When[os == "Windows"]
func promptPlatform(): String {
    return "Windows"
}

@When[os != "Windows"]
func promptPlatform(): String {
    return "POSIX"
}

func promptShell(): String {
    match (readEnv("SHELL")) {
        case Some(s) => if (s.size > 0) { s } else { "unknown" }
        case None => "unknown"
    }
}

/** 日期只取到天：时分秒每次会话都变，会让 provider 前缀缓存整段失效。 */
func promptDateOf(raw: String): String {
    match (raw.indexOf("T")) {
        case Some(idx) => if (idx > 0) { return raw[0..idx] } else { () }
        case None => ()
    }
    if (raw.size >= 10) {
        return raw[0..10]
    }
    return raw
}

/**
 * 组装 system prompt：基础规则 + 项目指令 + 技能 + 项目记忆 + 工具截断说明 + 当前环境。
 * 项目上下文均有字节上限，避免 14 KB 的 AGENTS.md 之类把基础规则挤出注意力。
 * 易变的当前环境放最末尾（日期只到天），让不同会话/不同时段共享尽可能长的稳定前缀，
 * provider 的前缀缓存才有命中率（实测同一任务 cached=0）。
 */
func buildSystemPrompt(base: String, skillsDir: String, enabled: ArrayList<String>, memoryDir: String,
    agentsMaxBytes: Int64, skillsMaxBytes: Int64, memoryMaxBytes: Int64): String {
    var s = base
    let instrPath = findProjectInstructionsPath()
    if (instrPath.size > 0) {
        try {
            let instr = safeFromUtf8(File.readFrom(instrPath))
            if (instr.size > 0) {
                s += "\n\n## Project instructions (AGENTS.md)\nSource: ${instrPath}\n\n" +
                    compactProjectInstructions(instr, agentsMaxBytes, instrPath)
            }
        } catch (e: Exception) {
            ()
        }
    }
    let skills = loadSkills(skillsDir, enabled)
    if (skills.size > 0) {
        s += "\n\n## Available skills (load on demand)\n" +
            clipPromptSection(skills, skillsMaxBytes, skillsDir)
    }
    // 跨会话项目记忆（P1-6）：上次会话的关键信息，帮助快速恢复上下文
    let memory = loadProjectMemory(memoryDir)
    if (memory.size > 0) {
        s += "\n\n## Project memory (previous session, stale context)\nSource: ${memoryDir}/" +
            currentProjectName() + ".md\n\n" +
            clipPromptSection(memory, memoryMaxBytes, memoryDir + "/" + currentProjectName() + ".md")
    }
    // 工具结果截断与回溯（对标 Pi spill extension）
    s += "\n\n## Tool result truncation\nLong tool results are shortened by cjh: head and tail are kept, "
    s += "and the omitted middle is saved to disk. The marker shows the path. Read that path with read_file "
    s += "(using offset/limit) when the middle matters."
    // 当前环境置底：日期/工作目录/平台在本会话内不变，跨会话也尽量同前缀（日期只到天）
    s += "\n\n## Current environment\n"
    s += "- Working directory: ${getWorkingDirectory()}\n"
    s += "- Platform: ${promptPlatform()}\n"
    s += "- Shell: ${promptShell()}\n"
    s += "- Date: ${promptDateOf(DateTime.now().toString())}"
    return s
}
func currentProjectName(): String {
    let cwd = getWorkingDirectory().toString()
    let slash = cwd.lastIndexOf("/")
    match (slash) {
        case Some(idx) =>
            let name = cwd[(idx + 1)..cwd.size]
            return if (name.size > 0) { name } else { "root" }
        case None => return cwd
    }
}

/**
 * 保存项目记忆（P1-6，Hindsight 式）：会话结束后写 memoryDir/<project>.md
 * 保留关键信息，供下次会话注入。限制：只覆盖写入，不累积（防膨胀）。
 */
func saveProjectMemory(memoryDir: String, summary: String): Unit {
    try {
        if (!exists(memoryDir)) {
            Directory.create(memoryDir, recursive: true)
        }
        let name = currentProjectName()
        let now = DateTime.now().toString()
        let content = "# 项目记忆：${name}\n> 更新时间：${now}\n\n${summary}"
        File.writeTo(memoryDir + "/" + name + ".md", content.toArray())
    } catch (e: Exception) {
        // 记忆写入失败不影响主流程
    }
}

/**
 * 读取项目记忆（供 buildSystemPrompt 注入）
 */
func loadProjectMemory(memoryDir: String): String {
    try {
        if (!exists(memoryDir)) {
            return ""
        }
        let name = currentProjectName()
        let path = memoryDir + "/" + name + ".md"
        if (!exists(path)) {
            return ""
        }
        return safeFromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        return ""
    }
}


