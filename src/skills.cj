package cjh

/**
 * Skills 子系统：技能文件扫描、索引注入、按需正文读取、声明式工具注册
 *
 * 技能形态：~/.cjh/skills/<name>.md，frontmatter 声明 name/description/tools；
 * system prompt 只注入「名称 + 描述」索引，正文由 `skill_load` 按需读取。
 */

import std.collection.*
import std.env.*
import std.fs.*
import std.sort.*
import std.time.*
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjh.tools.*
import cjh.tui.*
import cjlog.*
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
 * 列示技能（/skills 命令）：扫描 ~/.cjh/skills/<name>.md，输出名称、索引注入状态、
 * 前端声明的描述与携带工具数；无技能目录时提示创建方法。
 *
 * 状态必须与 buildSystemPrompt 的 planSkillIndex 完全同源：用户需要一眼看出
 * “为什么这个技能没在模型上下文里”，而不是只看到“启用”却毫无效果。
 */
func listSkills(skillsDir: String, enabled: ArrayList<String>, maxBytes: Int64, tui: TuiApp): Unit {
    if (!exists(skillsDir)) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[技能目录不存在: ${skillsDir}；创建 ~/.cjh/skills/<name>.md 即可启用]" + Ansi.reset())
        return
    }
    let skills = scanSkills(skillsDir, enabled)
    if (skills.size == 0) {
        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[无技能；创建 ~/.cjh/skills/<name>.md（frontmatter: name/description + 正文指令）]" + Ansi.reset())
        return
    }
    let ordered = ArrayList<SkillCandidate>()
    for (c in skills) {
        ordered.add(c)
    }
    sort(ordered, by: { a, b => a.name.compare(b.name) }, stable: true)
    let (_, statuses) = planSkillIndex(ordered, maxBytes)
    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) +
        "可用技能（settings.json 的 enabled_skills 白名单，空=全部启用；索引预算 ${maxBytes}B）：" + Ansi.reset())
    for (i in 0..statuses.size) {
        let status = statuses[i]
        let c = ordered[i]
        let state = if (!status.injected) {
            match (status.reason) {
                case "disabled" => Ansi.fg(Ansi.THEME_MUTED) + "○ 禁用" + Ansi.reset()
                case "empty" => Ansi.fg(Ansi.THEME_MUTED) + "○ 正文为空" + Ansi.reset()
                case "over_budget" => Ansi.fg(Ansi.THEME_WARN) + "⚠ 索引超预算（未注入）" + Ansi.reset()
                case _ => Ansi.fg(Ansi.THEME_MUTED) + "○ 未注入" + Ansi.reset()
            }
        } else {
            Ansi.fg(Ansi.THEME_OK) + "● 已注入索引" + Ansi.reset()
        }
        var line = "  ${state} ${c.name}"
        if (status.reason == "over_budget") {
            // 状态与原因必须排在描述之前：长描述会吃掉整行宽度，尾部说明在 80 列终端里看不到。
            line += Ansi.fg(Ansi.THEME_MUTED) + "（正文 ${fmtBytesShort(status.bodyBytes)}，仍可 skill_load）" + Ansi.reset()
        }
        if (c.description.size > 0) {
            line += " — ${c.description}"
        }
        let toolCount = countSkillTools(c.toolsJson)
        if (toolCount > 0) {
            line += Ansi.fg(Ansi.THEME_MUTED) + " [${toolCount} 个声明式工具]" + Ansi.reset()
        }
        tui.appendOutput(line)
    }
    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) +
        "超预算只影响索引注入；正文仍可 skill_load。开关：settings.json 的 enabled_skills" + Ansi.reset())
}

/**
 * 按预算生成技能索引：只含「名称 + 描述」，正文不进入提示词。
 * 按技能名升序确定性排列，装不下的整条跳过，不做中间截断。
 * 返回索引文本与逐技能状态（含 over_budget 原因），供 `buildSystemPrompt`
 * 告警和 `/api/skills` 展示。
 */
public func loadSkillIndexWithBudget(skillsDir: String, enabled: ArrayList<String>, maxBytes: Int64): (String, ArrayList<SkillInjection>) {
    return planSkillIndex(scanSkills(skillsDir, enabled), maxBytes)
}

/**
 * 技能索引预算告警：只报"装不下"的技能（未启用/空正文是用户显式选择，不告警），
 * 避免超预算后模型看不到技能、工具链却毫无提示。
 */
private func warnDroppedSkills(statuses: ArrayList<SkillInjection>, maxBytes: Int64): Unit {
    var dropped: Int64 = 0
    let names = StringBuilder()
    for (s in statuses) {
        if (s.reason != "over_budget") {
            continue
        }
        if (dropped > 0) {
            names.append(", ")
        }
        names.append("${s.name}(${s.indexBytes}B)")
        dropped += 1
    }
    if (dropped > 0) {
        Log.warn("技能索引超出预算 prompt_skills_max_bytes=${maxBytes}：${dropped} 个技能未列出（${names}）；" +
            "按技能名升序整条尝试，装不下的整条跳过，不会截断描述。技能正文始终按需 skill_load 加载")
    }
}

/**
 * 读取技能正文工具（渐进披露的第二步）。
 *
 * system prompt 只列名称/描述；模型判断任务匹配后调用本工具取正文。
 * 只读、无副作用，可与其他只读工具并发。
 */
public class SkillLoadTool <: CjhTool {
    private let skillsDir: String
    private let enabled: ArrayList<String>

    public init(skillsDir: String, enabled: ArrayList<String>) {
        this.skillsDir = skillsDir
        let copy = ArrayList<String>()
        for (e in enabled) {
            copy.add(e)
        }
        this.enabled = copy
    }

    public func spec(): ToolSpec {
        let props = HashMap<String, JsonValue>()
        props.add("name", JsonSchema.str("技能名（取自 system prompt 的 Available skills 索引）"))
        let schema = JsonSchema.object(props, ArrayList<String>(["name"]))
        return ToolSpec("skill_load",
            "读取指定技能的完整正文。system prompt 只列技能名与描述；当任务匹配某个技能时，" +
            "先调用本工具加载正文，再严格按其指令执行。只加载与当前任务相关的技能，不要预加载全部。",
            schema)
    }

    public func isReadOnly(): Bool {
        return true
    }

    public func execute(args: JsonObject): ToolResult {
        if (!args.containsKey("name")) {
            return ToolResult("缺少参数: name", true)
        }
        let rawName = match (args.get("name").getOrThrow().kind()) {
            case JsonKind.JsString => args.get("name").getOrThrow().asString().getValue().trimAscii()
            case _ => return ToolResult("参数 name 必须是字符串", true)
        }
        if (rawName.size == 0) {
            return ToolResult("参数 name 不能为空", true)
        }
        let candidates = scanSkills(this.skillsDir, this.enabled)
        var target: ?SkillCandidate = None
        for (c in candidates) {
            if (c.name == rawName) {
                target = Some(c)
                break
            }
        }
        match (target) {
            case Some(c) =>
                if (!c.enabled) {
                    return ToolResult("技能已禁用: ${c.name}（检查 ~/.cjh/settings.json 的 enabled_skills）", true)
                }
                if (c.body.size == 0) {
                    return ToolResult("技能正文为空: ${c.name}（${c.path}）", true)
                }
                return ToolResult("# Skill: ${c.name}\nSource: ${c.path}\n\n${c.body}", false)
            case None =>
                let available = StringBuilder()
                var count: Int64 = 0
                for (c in candidates) {
                    if (!c.enabled || c.body.size == 0) {
                        continue
                    }
                    if (count > 0) {
                        available.append(", ")
                    }
                    available.append(c.name)
                    count += 1
                    if (count >= 20) {
                        break
                    }
                }
                if (count == 0) {
                    return ToolResult("未知技能: ${rawName}；当前没有可用技能（目录: ${this.skillsDir}）", true)
                }
                return ToolResult("未知技能: ${rawName}；可用技能: ${available.toString()}", true)
        }
    }
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
 * 注册技能相关工具：
 * 1) `skill_load`：按需读取技能正文（始终注册，即使当前目录为空，运行期新增技能也能用）；
 * 2) 技能 frontmatter 的 tools 段（JSON 数组，每项 {name, description, command, args?}）
 *    注册为 DeclarativeTool（shell 模板 + 参数 schema，低门槛）。
 * 无 tools 段或解析失败则跳过该技能；技能目录不存在时只注册 skill_load。
 */
func loadSkillTools(skillsDir: String, registry: ToolRegistry, enabled: ArrayList<String>): Unit {
    registry.register(SkillLoadTool(skillsDir, enabled))
    for (c in scanSkills(skillsDir, enabled)) {
        if (!c.enabled || c.toolsJson.size == 0) {
            continue
        }
        registerSkillTools(c.toolsJson, registry)
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
    let skillResult = loadSkillIndexWithBudget(skillsDir, enabled, skillsMaxBytes)
    let (skills, skillStatuses) = skillResult
    if (skills.size > 0) {
        s += "\n\n## Available skills (progressive disclosure)\n"
        s += "Skill bodies are not loaded. When a task matches a skill below, call `skill_load` with its name "
        s += "before following its instructions. Load only skills relevant to the current task; do not preload all. "
        s += "If several skills apply, call each one (multiple calls in one turn are allowed). "
        s += "If a skill body is already present in this conversation, reuse it instead of loading it again.\n\n"
        s += skills
    }
    warnDroppedSkills(skillStatuses, skillsMaxBytes)
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


