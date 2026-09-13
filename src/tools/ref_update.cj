package cjh.tools

import std.collection.*
import std.fs.*
import std.process.*
import std.time.*
import cjutil.*

/*
 * cjh 内置知识层 · 三期（人显式触发路径）
 * ------------------------------------------------------------------
 * 本文件只做「语料刷新」相关的事：递归文件系统原语、清单重扫（rebuild）、
 * 来源摄取与原子替换（update）、回滚（restore）。清单/校验/CLI 文本在 ref_cli.cj。
 *
 * 保离线承诺：只有 update 且未指定 --source 时才会联网（git clone）；
 * 模型触发路径（工具调用）永远不会走到这里。
 */

// ---------------------------------------------------------------- 目录树扫描

/** 相对路径树（正斜杠分隔；文件与目录分开存）。 */
class RefTree {
    let files = ArrayList<String>()
    let dirs = ArrayList<String>()
}

/** 递归扫描 root（跳过点文件/点目录；子目录用显式递归，Directory.walk 非递归）。 */
func refScanInto(root: String, rel: String, t: RefTree, skipDots: Bool): Unit {
    var abs = root
    if (rel.size > 0) {
        abs = root + "/" + rel
    }
    let subdirs = ArrayList<String>()
    try {
        Directory.walk(abs, { fi =>
            if (!skipDots || !fi.name.startsWith(".")) {
                var childRel = fi.name
                if (rel.size > 0) {
                    childRel = rel + "/" + fi.name
                }
                if (fi.isDirectory()) {
                    subdirs.add(childRel)
                    t.dirs.add(childRel)
                } else {
                    t.files.add(childRel)
                }
            }
            true
        })
    } catch (e: Exception) {
        return
    }
    for (s in subdirs) {
        refScanInto(root, s, t, skipDots)
    }
}

/** 扫描 root 得到完整相对路径树（root 不存在时返回空树）。skipDots=true 时跳过点文件/点目录。 */
func refScanTreeAll(root: String, skipDots: Bool): RefTree {
    let t = RefTree()
    if (exists(root)) {
        refScanInto(root, "", t, skipDots)
    }
    return t
}

/** 路径深度（'/' 的个数），用于「先深后浅」删除。 */
func refDepthOf(rel: String): Int64 {
    var n = 0
    for (c in rel) {
        if (c == 47u8) {
            n++
        }
    }
    return n
}

// ---------------------------------------------------------------- 文件系统原语

/** 递归删除（仓颉无递归删除 API：remove 只处理文件与空目录，故先删文件再按深度倒序删目录）。 */
func refRemoveTree(path: String): Unit {
    if (!exists(path)) {
        return
    }
    let t = refScanTreeAll(path, false)
    var maxFile = 0
    for (f in t.files) {
        let d = refDepthOf(f)
        if (d > maxFile) {
            maxFile = d
        }
    }
    var fd = maxFile
    while (fd >= 0) {
        for (f in t.files) {
            if (refDepthOf(f) == fd) {
                try {
                    remove(path + "/" + f)
                } catch (e: Exception) {
                    ()
                }
            }
        }
        fd--
    }
    var maxDir = 0
    for (x in t.dirs) {
        let d = refDepthOf(x)
        if (d > maxDir) {
            maxDir = d
        }
    }
    var dd = maxDir
    while (dd >= 0) {
        for (x in t.dirs) {
            if (refDepthOf(x) == dd) {
                try {
                    remove(path + "/" + x)
                } catch (e: Exception) {
                    ()
                }
            }
        }
        dd--
    }
    try {
        remove(path)
    } catch (e: Exception) {
        ()
    }
}

/** 递归复制目录树（mdOnly=true 时只收 .md 正文）。返回复制的文件数。 */
func refCopyTree(from: String, to: String, mdOnly: Bool): Int64 {
    let t = refScanTreeAll(from, false)
    // 注意：Directory.create 不幂等（目标已存在即抛异常），故必须先判存在；
    // 且此处不能因建目录失败就放弃——否则会把「删旧后复制」的半途状态留成空语料。
    if (!exists(to)) {
        try {
            Directory.create(to, recursive: true)
        } catch (e: Exception) {
            return 0
        }
    }
    for (x in t.dirs) {
        let sub = to + "/" + x
        if (!exists(sub)) {
            try {
                Directory.create(sub, recursive: true)
            } catch (e: Exception) {
                ()
            }
        }
    }
    var n = 0
    for (f in t.files) {
        if (mdOnly && !f.endsWith(".md")) {
            continue
        }
        try {
            File.writeTo(to + "/" + f, File.readFrom(from + "/" + f))
            n++
        } catch (e: Exception) {
            ()
        }
    }
    return n
}

/** 目录下 .md 文件数（用于判断技能目录是否值得收录）。 */
func refMdCount(dir: String): Int64 {
    let t = refScanTreeAll(dir, true)
    var n = 0
    for (f in t.files) {
        if (f.endsWith(".md")) {
            n++
        }
    }
    return n
}

// ---------------------------------------------------------------- 时间戳与路径

/** 时间戳（用于临时目录名；只保留 [0-9A-Za-z-] 以适配文件系统）。 */
func refSanitizeStamp(s: String): String {
    var out = ""
    var i = 0
    while (i < s.size) {
        let ch = s[i..(i + 1)]
        let b = s[i]
        if ((b >= 48u8 && b <= 57u8) || (b >= 65u8 && b <= 90u8) || (b >= 97u8 && b <= 122u8) ||
            b == 45u8) {
            out = out + ch
        }
        i++
    }
    if (out.size == 0) {
        return "unknown"
    }
    return out
}

/** 当前时间戳字符串。 */
func refNowStamp(): String {
    var raw = ""
    try {
        raw = DateTime.now().toString()
    } catch (e: Exception) {
        raw = ""
    }
    return refSanitizeStamp(raw)
}

/** 语料目录的兄弟路径（staging / 快照 / 旧快照都放同级，便于整体回滚）。 */
func refSiblingDir(refDir: String, suffix: String): String {
    return refDir + "." + suffix
}

// ---------------------------------------------------------------- 清单重扫

/** 扫描语料正文（skills/<名>/ 下的 .md）生成清单。 */
func refScanCorpus(refDir: String, source: String, branch: String, mode: String): RefManifest {
    let m = RefManifest()
    m.generatedAt = refNowStamp()
    m.source = source
    m.branch = branch
    m.mode = mode
    let t = refScanTreeAll(refDir, true)
    let names = ArrayList<String>()
    for (f in t.files) {
        if (!f.endsWith(".md") || !f.startsWith("skills/")) {
            continue
        }
        let abs = refDir + "/" + f
        var size = 0
        var hash = ""
        try {
            size = File.readFrom(abs).size
            hash = sha256File(abs)
        } catch (e: Exception) {
            continue
        }
        m.entries.add(RefManifestEntry(f, size, hash))
        m.totalBytes = m.totalBytes + size
        m.markdownCount = m.markdownCount + 1
        let name = refSkillNameOf(f)
        if (name.size > 0 && !names.contains(name)) {
            names.add(name)
        }
    }
    for (n in names) {
        m.skills.add(n)
    }
    return m
}

/** 从 skills/<名>/... 相对路径里取技能名（取不到返回 ""）。 */
func refSkillNameOf(rel: String): String {
    let prefix = "skills/"
    if (!rel.startsWith(prefix)) {
        return ""
    }
    let rest = rel[prefix.size..rel.size]
    var i = 0
    while (i < rest.size) {
        if (rest[i] == 47u8) {
            return rest[0..i]
        }
        i++
    }
    return ""
}

/** `cjh ref rebuild`：纯本地重扫语料、重建清单。 */
public func refRebuild(refDir: String): RefCliResult {
    if (!exists(refDir)) {
        return RefCliResult("清单重建：失败\n  语料目录不存在 : " + refDir +
            "\n  提示：先运行 cjh ref update（或 scripts/install-cangjie-knowledge.sh）\n", 1)
    }
    var source = "local"
    var branch = "local"
    var mode = "local"
    match (loadRefManifest(refDir)) {
        case Some(p) =>
            if (p.source.size > 0) {
                source = p.source
            }
            if (p.branch.size > 0) {
                branch = p.branch
            }
            if (p.mode.size > 0) {
                mode = p.mode
            }
        case None => ()
    }
    let m = refScanCorpus(refDir, source, branch, mode)
    if (m.entries.size == 0) {
        return RefCliResult("清单重建：失败\n  未找到可收录正文（期望 skills/<技能名>/ 下的 .md）\n", 1)
    }
    saveRefManifest(refDir, m)
    let sb = StringBuilder()
    sb.append("清单重建：完成\n")
    sb.append("  语料目录 : " + refDir + "\n")
    sb.append("  条目数   : " + m.entries.size.toString() + " 个文件、" + m.totalBytes.toString() +
        " 字节\n")
    sb.append("  技能     : " + refJoinSkills(m.skills) + "\n")
    sb.append("  清单     : " + refManifestPath(refDir) + "\n")
    return RefCliResult(sb.toString(), 0)
}

// ---------------------------------------------------------------- 来源定位

/** 一个技能在来源仓库里的位置。 */
public class RefSkillSource {
    public let name: String
    public let dir: String

    public init(name: String, dir: String) {
        this.name = name
        this.dir = dir
    }
}

/** 收集 base 下「含 .md 正文」的直接子目录为技能源。 */
func refCollectSkillSources(base: String, out: ArrayList<RefSkillSource>): Unit {
    if (!exists(base)) {
        return
    }
    let kids = ArrayList<String>()
    try {
        Directory.walk(base, { fi =>
            if (fi.isDirectory() && !fi.name.startsWith(".")) {
                kids.add(fi.name)
            }
            true
        })
    } catch (e: Exception) {
        return
    }
    for (k in kids) {
        let dir = base + "/" + k
        if (refMdCount(dir) > 0) {
            out.add(RefSkillSource(k, dir))
        }
    }
}

/**
 * 在来源仓库根下定位技能目录：优先「发布件布局」.agents/skills/<名>，
 * 退化到「开发态布局」skills/<名>（两者其一命中即可）。
 */
func refSkillSourceDirs(repoRoot: String): ArrayList<RefSkillSource> {
    let out = ArrayList<RefSkillSource>()
    refCollectSkillSources(repoRoot + "/.agents/skills", out)
    if (out.size == 0) {
        refCollectSkillSources(repoRoot + "/skills", out)
    }
    return out
}

// ---------------------------------------------------------------- update 选项

/** `cjh ref update` 的选项。 */
public class RefUpdateOptions {
    public var source: String = ""
    public var repo: String = "https://atomgit.com/Cangjie-SIG/CangjieSkills"
    public var branch: String = "cangjie-1.0.5"
    public var dryRun: Bool = false
    public var restore: Bool = false
}

/** 解析 update 选项；返回 (选项, 错误文本)（错误文本非空表示用法错误）。 */
func refParseUpdateOptions(args: Array<String>): (RefUpdateOptions, String) {
    let o = RefUpdateOptions()
    var i = 2
    while (i < args.size) {
        let a = args[i]
        if (a == "--source") {
            if (i + 1 >= args.size) {
                return (o, "选项 --source 缺少参数值\n")
            }
            o.source = args[i + 1]
            i = i + 2
        } else if (a == "--repo") {
            if (i + 1 >= args.size) {
                return (o, "选项 --repo 缺少参数值\n")
            }
            o.repo = args[i + 1]
            i = i + 2
        } else if (a == "--branch") {
            if (i + 1 >= args.size) {
                return (o, "选项 --branch 缺少参数值\n")
            }
            o.branch = args[i + 1]
            i = i + 2
        } else if (a == "--dry-run") {
            o.dryRun = true
            i++
        } else if (a == "--restore") {
            o.restore = true
            i++
        } else {
            return (o, "未知选项 : " + a + "\n")
        }
    }
    return (o, "")
}

// ---------------------------------------------------------------- 联网取源

/** git clone --depth 1 --branch <branch> <repo> <dest>；返回退出码（无法启动返回 -1）。 */
func refGitClone(repo: String, branch: String, dest: String): Int64 {
    let a = ArrayList<String>()
    a.add("clone")
    a.add("--depth")
    a.add("1")
    a.add("--branch")
    a.add(branch)
    a.add(repo)
    a.add(dest)
    try {
        let (code, outBytes, errBytes) = executeWithOutput("git", a.toArray())
        return code
    } catch (e: Exception) {
        return -1
    }
}

// ---------------------------------------------------------------- update / restore

/** 一次覆盖的计数（供输出报告：覆盖了几个技能、写了几个文件、清了几个旧 md、留了几个非 md）。 */
class RefApplyStats {
    var skills: Int64 = 0
    var copied: Int64 = 0
    var removedMd: Int64 = 0
    var keptOther: Int64 = 0
}

/**
 * 把 staging 里的技能目录覆盖到 live。
 * 语义：**只对齐 .md 正文**——同名技能目录里残留的旧 .md 会被清掉（让 md 集合镜像来源），
 * 非 .md 资产（上游技能自带的脚本 / 知识库等）保留；来源里没有的技能目录原样不动。
 * 早期实现是「整树删除再复制」，会把 cangjie-coding 自带的 doc_search 脚本与
 * knowledge.sqlite3（8.9 MB）一起清掉，与 install 脚本装出来的语料不一致。
 */
func refApplyStaging(staging: String, refDir: String, skills: ArrayList<RefSkillSource>): RefApplyStats {
    let st = RefApplyStats()
    try {
        Directory.create(refDir + "/skills", recursive: true)
    } catch (e: Exception) {
        ()
    }
    for (s in skills) {
        let target = refDir + "/skills/" + s.name
        let src = staging + "/skills/" + s.name
        if (!exists(src)) {
            continue
        }
        st.skills = st.skills + 1
        // 只清同名技能目录里的旧 md；非 md 资产留着不动
        for (f in refScanTreeAll(target, false).files) {
            if (f.endsWith(".md")) {
                try {
                    remove(target + "/" + f)
                    st.removedMd = st.removedMd + 1
                } catch (e: Exception) {
                    ()
                }
            } else {
                st.keptOther = st.keptOther + 1
            }
        }
        st.copied = st.copied + refCopyTree(src, target, true)
    }
    return st
}

/**
 * 把 prev 快照整树写回 refDir（回滚用）。
 * 安全性：先复制到同级临时目录并确认非空，确认后才删现网并搬入——
 * 任何一步失败都不会把现网语料删成空的。
 */
func refRestoreFrom(prev: String, refDir: String): Bool {
    if (!exists(prev)) {
        return false
    }
    let tmp = refSiblingDir(refDir, "restoring-" + refNowStamp())
    refRemoveTree(tmp)
    let staged = refCopyTree(prev, tmp, false)
    if (staged == 0) {
        refRemoveTree(tmp)
        return false
    }
    refRemoveTree(refDir)
    let moved = refCopyTree(tmp, refDir, false)
    refRemoveTree(tmp)
    return moved > 0
}

/** `cjh ref update --restore`：把上一份快照回滚为现网语料。 */
func refRestore(refDir: String): RefCliResult {
    let prev = refSiblingDir(refDir, "prev")
    if (!exists(prev)) {
        return RefCliResult("语料回滚：失败\n  没有可用快照 : " + prev +
            "\n  提示：快照由 cjh ref update 在覆盖前生成\n", 1)
    }
    let old = refSiblingDir(refDir, "pre-restore-" + refNowStamp())
    if (exists(refDir)) {
        refCopyTree(refDir, old, false)
    }
    if (!refRestoreFrom(prev, refDir)) {
        if (exists(old)) {
            refRestoreFrom(old, refDir)
        }
        return RefCliResult("语料回滚：失败\n  快照内容为空，已保持原样 : " + prev + "\n", 1)
    }
    // 快照若本来就不含清单（覆盖前语料尚未建清单），恢复后没有清单是「忠实恢复」而非失败，
    // 此时按恢复后的语料重扫生成，避免把一次成功回滚误判成「快照校验不通过」再撤回去。
    var note = ""
    if (!exists(refManifestPath(refDir))) {
        let rb = refRebuild(refDir)
        if (rb.exitCode == 0) {
            note = "  说明 : 快照不含清单，已按恢复后的语料重扫生成\n"
        }
    }
    let v = refVerifyResult(refDir)
    if (!v.ok) {
        // 回滚后的快照自身校验不过：把回滚前的内容放回去
        if (exists(old)) {
            refRestoreFrom(old, refDir)
        }
        refRemoveTree(old)
        return RefCliResult("语料回滚：失败（快照校验不通过，已恢复回滚前语料）\n" + v.text, 1)
    }
    refRemoveTree(old)
    let sb = StringBuilder()
    sb.append("语料回滚：完成（已从快照恢复）\n")
    sb.append("  语料目录 : " + refDir + "\n")
    sb.append("  快照来源 : " + prev + "\n")
    if (note.size > 0) {
        sb.append(note)
    }
    sb.append(v.text)
    return RefCliResult(sb.toString(), 0)
}

/**
 * `cjh ref update`：唯一联网入口（未指定 --source 时 git clone）。
 * 顺序：取源 → 选技能 → staging → 快照 → 覆盖 → 重建清单 → 校验；任一步失败都能回到覆盖前。
 */
public func refUpdate(refDir: String, opts: RefUpdateOptions): RefCliResult {
    if (opts.restore) {
        return refRestore(refDir)
    }
    // 1) 取源：本地目录（离线）或 git clone（联网，人显式触发才走到）
    var repoRoot = opts.source
    var tmpDir = ""
    var netMode = false
    if (repoRoot.size == 0) {
        netMode = true
        tmpDir = refSiblingDir("/tmp/cjh-ref-clone", refNowStamp())
        if (exists(tmpDir)) {
            refRemoveTree(tmpDir)
        }
        try {
            Directory.create(tmpDir, recursive: true)
        } catch (e: Exception) {
            return RefCliResult("语料刷新：失败\n  无法建临时目录 : " + tmpDir + "\n", 1)
        }
        let dest = tmpDir + "/CangjieSkills"
        let code = refGitClone(opts.repo, opts.branch, dest)
        if (code != 0) {
            refRemoveTree(tmpDir)
            var hint = ""
            if (code < 0) {
                hint = "\n  提示：未找到可用的 git（联网路径需要 git；也可用 --source <本地目录> 离线刷新）\n"
            } else {
                hint = "\n  提示：检查网络与仓库地址，或用 --source <本地目录> 离线刷新\n"
            }
            return RefCliResult("语料刷新：失败（git clone 退出码 " + code.toString() + "）\n  仓库 : " +
                opts.repo + "\n  分支 : " + opts.branch + "\n" + hint, 1)
        }
        repoRoot = dest
    }
    if (!exists(repoRoot)) {
        let msg = "语料刷新：失败\n  来源目录不存在 : " + repoRoot + "\n"
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        return RefCliResult(msg, 1)
    }
    // 2) 选技能（只收含 .md 正文的技能目录）
    let skills = refSkillSourceDirs(repoRoot)
    if (skills.size == 0) {
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        return RefCliResult("语料刷新：失败\n  来源里没有可用技能（期望 .agents/skills/<名>/ 或 skills/<名>/ 含 .md）\n  来源 : " +
            repoRoot + "\n", 1)
    }
    // 3) 预演：只报告，不落盘
    if (opts.dryRun) {
        let sb = StringBuilder()
        sb.append("语料刷新（预演，未改动任何文件）\n")
        sb.append("  来源   : " + repoRoot + "\n")
        sb.append("  模式   : " + (if (netMode) { "联网 git clone" } else { "离线 --source" }) + "\n")
        sb.append("  目标   : " + refDir + "\n")
        sb.append("  技能   : " + skills.size.toString() + " 个\n")
        var i = 0
        while (i < skills.size) {
            sb.append("    - " + skills[i].name + "（" + refMdCount(skills[i].dir).toString() +
                " 个 .md）\n")
            i++
        }
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        return RefCliResult(sb.toString(), 0)
    }
    // 4) staging：先把来源内容搬进同级临时目录，避免半途失败污染现网
    let staging = refSiblingDir(refDir, "new-" + refNowStamp())
    if (exists(staging)) {
        refRemoveTree(staging)
    }
    var copied = 0
    for (s in skills) {
        copied = copied + refCopyTree(s.dir, staging + "/skills/" + s.name, true)
    }
    if (copied == 0) {
        refRemoveTree(staging)
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        return RefCliResult("语料刷新：失败\n  来源里没有可收录的 .md 正文\n  来源 : " + repoRoot +
            "\n", 1)
    }
    // 5) 覆盖前快照（整树，含旧清单）
    let prev = refSiblingDir(refDir, "prev")
    var hadLive = false
    if (exists(refDir)) {
        hadLive = true
        if (exists(prev)) {
            refRemoveTree(prev)
        }
        refCopyTree(refDir, prev, false)
    }
    // 6) 覆盖 + 重建清单
    let applied = refApplyStaging(staging, refDir, skills)
    let srcLabel = if (netMode) { opts.repo } else { "local:" + repoRoot }
    let modeLabel = if (netMode) { "git" } else { "local" }
    let m = refScanCorpus(refDir, srcLabel, opts.branch, modeLabel)
    if (m.entries.size == 0) {
        let rolled = refRestoreFrom(prev, refDir)
        refRemoveTree(staging)
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        var extra = ""
        if (hadLive && rolled) {
            extra = "（已回滚到覆盖前语料）"
        }
        return RefCliResult("语料刷新：失败\n  覆盖后扫不到任何 .md 正文" + extra + "\n", 1)
    }
    saveRefManifest(refDir, m)
    // 7) 覆盖后自检
    let v = refVerifyResult(refDir)
    if (!v.ok) {
        var extra = ""
        if (hadLive) {
            let rolled = refRestoreFrom(prev, refDir)
            if (rolled) {
                extra = "（已回滚到覆盖前语料：" + prev + "）"
            } else {
                extra = "（回滚失败，快照仍在：" + prev + "）"
            }
        }
        refRemoveTree(staging)
        if (tmpDir.size > 0) {
            refRemoveTree(tmpDir)
        }
        return RefCliResult("语料刷新：失败（覆盖后校验不通过）" + extra + "\n" + v.text, 1)
    }
    // 8) 收尾
    refRemoveTree(staging)
    if (tmpDir.size > 0) {
        refRemoveTree(tmpDir)
    }
    let sb = StringBuilder()
    sb.append("语料刷新：完成\n")
    sb.append("  来源   : " + srcLabel + "\n")
    sb.append("  分支   : " + opts.branch + "\n")
    sb.append("  目标   : " + refDir + "\n")
    sb.append("  技能   : " + refJoinSkills(m.skills) + "\n")
    sb.append("  正文   : " + m.entries.size.toString() + " 个文件、" + m.totalBytes.toString() +
        " 字节（本次写入 " + applied.copied.toString() + " 个文件）\n")
    sb.append("  同名技能: 覆盖 " + applied.skills.toString() + " 个（清理旧 md " +
        applied.removedMd.toString() + " 个，保留非 md " + applied.keptOther.toString() + " 个）\n")
    if (hadLive) {
        sb.append("  快照   : " + prev + "（可 cjh ref update --restore 回滚）\n")
    }
    sb.append(v.text)
    return RefCliResult(sb.toString(), 0)
}
