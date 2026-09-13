/**
 * cjh ref 子命令：仓颉知识层语料的清单读写 + status / verify 纯本地实现。
 *
 * 设计边界（见 docs/设计-仓颉内置知识层.md §14 三期设计）：
 *   - 只有 `cjh ref update` 联网，且必须由人显式敲命令触发；模型回答途中永不触发下载；
 *   - 逻辑集中在本文件（package cjh.tools）便于单测，命令行 glue 放 src/main.cj，
 *     与既有 trust 子命令同构（main.cj 不可被 cjh.tests 导入，故不放逻辑）。
 */
package cjh.tools

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjutil.*

/** 语料清单文件名（固定放在语料根目录下）。 */
public let REF_MANIFEST_FILE: String = ".cjh-ref-manifest.json"

/** 清单里的单个文件条目：相对语料根的路径 + 字节数 + SHA-256。 */
public class RefManifestEntry {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        this.path = path
        this.bytes = bytes
        this.sha256 = sha256
    }
}

/** 语料清单：来源 / 分支 / 逐文件摘要，`verify` 与 `status` 都以它为准。 */
public class RefManifest {
    public var generatedAt: String = ""
    public var source: String = ""
    public var branch: String = ""
    public var mode: String = ""
    public var markdownCount: Int64 = 0
    public var totalBytes: Int64 = 0
    public var skills: ArrayList<String> = ArrayList<String>()
    public var entries: ArrayList<RefManifestEntry> = ArrayList<RefManifestEntry>()
}

/** 语料清单路径。 */
public func refManifestPath(refDir: String): String {
    return refDir + "/" + REF_MANIFEST_FILE
}

/** 仓颉枚举不支持 == / != 比较，统一用 match 转 Bool 的谓词。 */
func refIsObject(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsObject => return true
        case _ => return false
    }
}

func refIsArray(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsArray => return true
        case _ => return false
    }
}

func refIsString(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsString => return true
        case _ => return false
    }
}

/** 取 JSON 值里的字符串字段（仅当它是对象且该字段为字符串时返回其值，否则 ""）。 */
func refStrField(v: JsonValue, field: String): String {
    if (!refIsObject(v)) {
        return ""
    }
    match (v.asObject().get(field)) {
        case Some(fv) =>
            if (refIsString(fv)) {
                return fv.asString().getValue()
            }
        case None => ()
    }
    return ""
}

/** 取 JSON 对象里的整数字段；缺失 / 类型不符返回 def。 */
func refJsonIntField(obj: JsonObject, field: String, def: Int64): Int64 {
    match (obj.get(field)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => return def
            }
        case None => return def
    }
}

/** 读清单：文件不存在 / 读失败 / JSON 坏掉 / 结构不符，一律返回 None（不抛）。 */
public func loadRefManifest(refDir: String): Option<RefManifest> {
    let mp = refManifestPath(refDir)
    if (!exists(mp)) {
        return None
    }
    var text = ""
    try {
        text = safeFromUtf8(File.readFrom(mp))
    } catch (e: Exception) {
        return None
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(text)
    } catch (e: Exception) {
        return None
    }
    if (!refIsObject(root)) {
        return None
    }
    let obj = root.asObject()
    let m = RefManifest()
    m.generatedAt = refStrField(root, "generated_at")
    m.source = refStrField(root, "source")
    m.branch = refStrField(root, "branch")
    m.mode = refStrField(root, "mode")
    m.markdownCount = refJsonIntField(obj, "markdown_count", 0)
    m.totalBytes = refJsonIntField(obj, "total_bytes", 0)
    match (obj.get("skills")) {
        case Some(sv) =>
            if (refIsArray(sv)) {
                let arr = sv.asArray()
                var i = 0
                while (i < arr.size()) {
                    let item = arr[i]
                    if (refIsString(item)) {
                        m.skills.add(item.asString().getValue())
                    }
                    i++
                }
            }
        case None => ()
    }
    match (obj.get("files")) {
        case Some(fv) =>
            if (refIsArray(fv)) {
                let arr = fv.asArray()
                var i = 0
                while (i < arr.size()) {
                    let item = arr[i]
                    if (refIsObject(item)) {
                        let p = refStrField(item, "path")
                        let h = refStrField(item, "sha256")
                        let b = refJsonIntField(item.asObject(), "bytes", 0)
                        if (p.size > 0) {
                            m.entries.add(RefManifestEntry(p, b, h))
                        }
                    }
                    i++
                }
            }
        case None => ()
    }
    return Some(m)
}

/** 写清单（紧凑 JSON，写失败抛异常由调用方处理）。 */
public func saveRefManifest(refDir: String, m: RefManifest): Unit {
    let filesArr = ArrayList<JsonValue>()
    for (e in m.entries) {
        let fo = JsonObject()
        fo.put("path", JsonString(e.path))
        fo.put("bytes", JsonInt(e.bytes))
        fo.put("sha256", JsonString(e.sha256))
        filesArr.add(fo)
    }
    let skillsArr = ArrayList<JsonValue>()
    for (s in m.skills) {
        skillsArr.add(JsonString(s))
    }
    let obj = JsonObject()
    obj.put("format", JsonInt(1))
    obj.put("generated_at", JsonString(m.generatedAt))
    obj.put("source", JsonString(m.source))
    obj.put("branch", JsonString(m.branch))
    obj.put("mode", JsonString(m.mode))
    obj.put("markdown_count", JsonInt(m.markdownCount))
    obj.put("total_bytes", JsonInt(m.totalBytes))
    obj.put("skills", JsonArray(skillsArr))
    obj.put("files", JsonArray(filesArr))
    File.writeTo(refManifestPath(refDir), obj.toString().toArray())
}

/** 取摘要前 8 位用于人读（清单里存完整值）。 */
func refShortHash(h: String): String {
    if (h.size <= 8) {
        return h
    }
    return h[0..8]
}

/** join 技能名列表（最多前 5 个，其余折叠）。 */
func refJoinSkills(skills: ArrayList<String>): String {
    if (skills.size == 0) {
        return "（无）"
    }
    var sb = StringBuilder()
    var i = 0
    while (i < skills.size && i < 5) {
        if (i > 0) {
            sb.append(", ")
        }
        sb.append(skills[i])
        i++
    }
    if (skills.size > 5) {
        sb.append(" 等 " + skills.size.toString() + " 篇")
    }
    return sb.toString()
}

/** `cjh ref status`：纯本地，打印语料目录 / 清单 / 来源概况。 */
public func refStatusText(refDir: String): String {
    let sb = StringBuilder()
    sb.append("cjh 知识层语料状态\n")
    sb.append("  语料目录 : " + refDir + "\n")
    if (!exists(refDir)) {
        sb.append("  状态     : 未安装（目录不存在）\n")
        sb.append("  安装指引 : bash scripts/install-cangjie-knowledge.sh --with-cangjie-skills\n")
        sb.append("  联网刷新 : cjh ref update（需人显式触发）\n")
        return sb.toString()
    }
    sb.append("  状态     : 已安装\n")
    let mp = refManifestPath(refDir)
    if (!exists(mp)) {
        sb.append("  清单文件 : " + mp + "（缺失）\n")
        sb.append("  提示     : 运行 cjh ref rebuild 重建清单\n")
        return sb.toString()
    }
    sb.append("  清单文件 : " + mp + "\n")
    match (loadRefManifest(refDir)) {
        case Some(m) =>
            sb.append("  清单条目 : " + m.entries.size.toString() + " 个文件 / " +
                m.totalBytes.toString() + " 字节（其中 Markdown " + m.markdownCount.toString() + " 篇）\n")
            sb.append("  技能     : " + refJoinSkills(m.skills) + "\n")
            sb.append("  来源     : " + m.source + "\n")
            sb.append("  分支     : " + m.branch + "（" + m.mode + "）\n")
            sb.append("  生成时间 : " + m.generatedAt + "\n")
        case None =>
            sb.append("  清单状态 : 解析失败（JSON 损坏或结构不符）\n")
            sb.append("  提示     : 运行 cjh ref rebuild 重建清单\n")
    }
    return sb.toString()
}

/** 校验结果：是否通过 + 人读报告 + 问题条数。 */
public class RefVerifyResult {
    public let ok: Bool
    public let text: String
    public let issues: Int64

    public init(ok: Bool, text: String, issues: Int64) {
        this.ok = ok
        this.text = text
        this.issues = issues
    }
}

/** `cjh ref verify`：按清单逐文件重算 SHA-256，纯本地、不联网。 */
public func refVerifyResult(refDir: String): RefVerifyResult {
    if (!exists(refDir)) {
        return RefVerifyResult(false, "语料校验：失败\n  语料目录不存在 : " + refDir + "\n", 1)
    }
    match (loadRefManifest(refDir)) {
        case None =>
            return RefVerifyResult(false,
                "语料校验：失败\n  未找到可用清单 : " + refManifestPath(refDir) +
                "\n  提示：运行 cjh ref rebuild 重建清单\n", 1)
        case Some(m) =>
            if (m.entries.size == 0) {
                return RefVerifyResult(false, "语料校验：失败\n  清单为空（0 个文件）\n", 1)
            }
            let problems = ArrayList<String>()
            for (e in m.entries) {
                let abs = refDir + "/" + e.path
                if (!exists(abs)) {
                    problems.add("  ✗ 缺失     : " + e.path)
                    continue
                }
                let actual = sha256File(abs)
                if (actual != e.sha256) {
                    problems.add("  ✗ 被修改   : " + e.path + "（清单 " + refShortHash(e.sha256) +
                        "…，实际 " + refShortHash(actual) + "…）")
                }
            }
            if (problems.size == 0) {
                return RefVerifyResult(true,
                    "语料校验：通过（" + m.entries.size.toString() + " 个文件，SHA-256 全部一致）\n", 0)
            }
            let sb = StringBuilder()
            sb.append("语料校验：失败（" + problems.size.toString() + " 个问题）\n")
            var i = 0
            while (i < problems.size && i < 20) {
                sb.append(problems[i] + "\n")
                i++
            }
            if (problems.size > 20) {
                sb.append("  …（其余 " + (problems.size - 20).toString() + " 条省略）\n")
            }
            return RefVerifyResult(false, sb.toString(), problems.size)
    }
}

/** `cjh ref` 用法说明。 */
public func refUsageText(): String {
    let sb = StringBuilder()
    sb.append("用法：cjh ref <子命令> [选项]\n")
    sb.append("  status   显示语料状态（纯本地，不联网）\n")
    sb.append("  verify   按清单校验语料完整性（纯本地，不联网）\n")
    sb.append("  update   从来源刷新语料（唯一联网入口，需人显式触发；--source 可离线）\n")
    sb.append("             --source <目录>  以本地目录为来源（离线，不联网）\n")
    sb.append("             --repo <地址>    git 仓库地址（默认 Cangjie-SIG/CangjieSkills）\n")
    sb.append("             --branch <分支>  git 分支（默认 cangjie-1.0.5）\n")
    sb.append("             --dry-run        只预演报告，不改动任何文件\n")
    sb.append("             --restore        回滚到覆盖前快照（<语料目录>.prev）\n")
    sb.append("  rebuild  重扫语料重建清单（纯本地，不联网）\n")
    sb.append("  search <关键词…>  跑一次语料检索（纯本地，不联网；与 cangjie_ref 工具同一实现）\n")
    return sb.toString()
}

/** 子命令执行结果：待打印文本 + 进程退出码。 */
public class RefCliResult {
    public let output: String
    public let exitCode: Int64

    public init(output: String, exitCode: Int64) {
        this.output = output
        this.exitCode = exitCode
    }
}

/**
 * `cjh ref` 的完整分发（输出文本 + 退出码；main.cj 只负责打印与返回）。
 * args 为原始 argv（args[0] == "ref"）。
 */
public func refCliMain(args: Array<String>, refDir: String): RefCliResult {
    if (args.size < 2) {
        return RefCliResult(refUsageText(), 2)
    }
    let sub = args[1]
    match (sub) {
        case "status" => return RefCliResult(refStatusText(refDir), 0)
        case "verify" =>
            let r = refVerifyResult(refDir)
            if (r.ok) {
                return RefCliResult(r.text, 0)
            }
            return RefCliResult(r.text, 1)
        case "update" =>
            let (opts, err) = refParseUpdateOptions(args)
            if (err.size > 0) {
                return RefCliResult("cjh ref update：" + err + refUsageText(), 2)
            }
            return refUpdate(refDir, opts)
        case "rebuild" => return refRebuild(refDir)
        case "search" => return refSearchResult(args, refDir)
        case _ => return RefCliResult("未知子命令：" + sub + "\n" + refUsageText(), 2)
    }
}

/**
 * `cjh ref search <关键词…>`：直接跑一次二期只读检索（纯本地、离线）。
 * 复用 CangjieRefTool 的实现，避免 TUI 面板另造一套检索逻辑。
 */
public func refSearchResult(args: Array<String>, refDir: String): RefCliResult {
    if (args.size < 3) {
        return RefCliResult("用法：cjh ref search <关键词…>\n", 2)
    }
    var query = ""
    var i = 2
    while (i < args.size) {
        if (query.size > 0) {
            query += " "
        }
        query += args[i]
        i++
    }
    let ja = JsonObject()
    ja.put("query", JsonString(query))
    let r = CangjieRefTool(refDir).execute(ja)
    if (r.isError) {
        return RefCliResult(r.content + "\n", 1)
    }
    return RefCliResult(r.content + "\n", 0)
}
