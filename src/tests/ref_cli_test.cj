package cjh.tests

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import cjh.tools.*
import cjutil.*

// 注意：本仓 @Assert 是「等式断言」——@Assert(actual, expected)，第二参是期望值而非消息；
// 逻辑真值断言写 @Assert(cond, true)，期望为假写 @Assert(cond, false)。

// ---------------------------------------------------------------- 测试辅助

/** 建一个干净的语料目录（testTempDir 内部先清空再建，天然幂等）。 */
func refNewCorpus(name: String): String {
    return testTempDir(name)
}

/** 在语料目录下写文件（sub 非空时先建父目录；Directory.create 不幂等，须先判存在）。 */
func refPutFile(refDir: String, sub: String, fileName: String, content: String): String {
    var dir = refDir
    if (sub.size > 0) {
        dir = refDir + "/" + sub
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }
    let abs = dir + "/" + fileName
    writeTextFile(abs, content)
    return abs
}

/** 由「相对路径 + 内容」两组同长列表造清单（sha256 按内容实算）。 */
func refManifestOf(rels: ArrayList<String>, contents: ArrayList<String>): RefManifest {
    let m = RefManifest()
    m.generatedAt = "2026-09-12T00:00:00Z"
    m.source = "local-fixture"
    m.branch = "test-branch"
    m.mode = "local"
    var i = 0
    while (i < rels.size) {
        let c = contents[i]
        m.entries.add(RefManifestEntry(rels[i], stringToBytes(c).size, sha256Hex(stringToBytes(c))))
        m.totalBytes = m.totalBytes + stringToBytes(c).size
        m.markdownCount = m.markdownCount + 1
        i++
    }
    m.skills.add("cangjie-coding")
    m.skills.add("cangjie-code-review")
    return m
}

/** 造「语料目录 + 清单」就绪的 fixture：SKILL.md(alpha) + notes/b.md(beta)。 */
func refReadyCorpus(name: String): String {
    let dir = refNewCorpus(name)
    refPutFile(dir, "", "SKILL.md", "alpha")
    refPutFile(dir, "notes", "b.md", "beta")
    let rels = ArrayList<String>()
    rels.add("SKILL.md")
    rels.add("notes/b.md")
    let contents = ArrayList<String>()
    contents.add("alpha")
    contents.add("beta")
    saveRefManifest(dir, refManifestOf(rels, contents))
    return dir
}

// ---------------------------------------------------------------- 清单读写

@Test
public func testRefManifestPathJoin(): Unit {
    @Assert(refManifestPath("/tmp/x"), "/tmp/x/" + REF_MANIFEST_FILE)
    @Assert(REF_MANIFEST_FILE, ".cjh-ref-manifest.json")
}

@Test
public func testRefManifestRoundTrip(): Unit {
    let dir = refReadyCorpus("ref_cli_rt")
    let opt = loadRefManifest(dir)
    @Assert(opt.isSome(), true)
    let m = opt.getOrThrow()
    @Assert(m.source, "local-fixture")
    @Assert(m.branch, "test-branch")
    @Assert(m.mode, "local")
    @Assert(m.generatedAt, "2026-09-12T00:00:00Z")
    @Assert(m.entries.size, 2)
    @Assert(m.skills.size, 2)
    @Assert(m.totalBytes, 9)
    @Assert(m.markdownCount, 2)
    @Assert(m.entries[1].path, "notes/b.md")
    @Assert(m.entries[0].sha256, sha256Hex(stringToBytes("alpha")))
}

@Test
public func testRefManifestLoadMissingDir(): Unit {
    @Assert(loadRefManifest("/tmp/cjh_ut_ref_cli_absent_dir_xyz").isSome(), false)
}

@Test
public func testRefManifestLoadMissingFile(): Unit {
    let dir = refNewCorpus("ref_cli_nomanifest")
    @Assert(loadRefManifest(dir).isSome(), false)
}

@Test
public func testRefManifestLoadCorruptJson(): Unit {
    let dir = refNewCorpus("ref_cli_badjson")
    writeTextFile(refManifestPath(dir), "{ this is not json")
    // JSON 损坏必须返回 None（而不是抛出去把 CLI 打死）
    @Assert(loadRefManifest(dir).isSome(), false)
}

@Test
public func testRefManifestLoadNonObject(): Unit {
    let dir = refNewCorpus("ref_cli_nonobj")
    writeTextFile(refManifestPath(dir), "[1,2,3]")
    @Assert(loadRefManifest(dir).isSome(), false)
}

@Test
public func testRefManifestSkipsMalformedEntries(): Unit {
    let dir = refNewCorpus("ref_cli_malformed")
    let raw = "{\"source\":\"s\",\"files\":[{\"path\":\"ok.md\",\"bytes\":3,\"sha256\":\"aa\"}," +
        "7,{\"path\":\"\",\"bytes\":1,\"sha256\":\"bb\"}],\"skills\":[\"good\",9]}"
    writeTextFile(refManifestPath(dir), raw)
    let opt = loadRefManifest(dir)
    @Assert(opt.isSome(), true)
    let m = opt.getOrThrow()
    @Assert(m.entries.size, 1)
    @Assert(m.entries[0].path, "ok.md")
    @Assert(m.skills.size, 1)
    @Assert(m.source, "s")
}

// ---------------------------------------------------------------- status

@Test
public func testRefStatusNotInstalled(): Unit {
    let t = refStatusText("/tmp/cjh_ut_ref_cli_never_exist_abc")
    @Assert(t.contains("未安装"), true)
    @Assert(t.contains("cjh ref update"), true)
}

@Test
public func testRefStatusWithoutManifest(): Unit {
    let dir = refNewCorpus("ref_cli_status_nm")
    let t = refStatusText(dir)
    @Assert(t.contains("已安装"), true)
    @Assert(t.contains("缺失"), true)
    @Assert(t.contains("cjh ref rebuild"), true)
}

@Test
public func testRefStatusWithManifest(): Unit {
    let dir = refReadyCorpus("ref_cli_status_ok")
    let t = refStatusText(dir)
    @Assert(t.contains("2 个文件"), true)
    @Assert(t.contains("9 字节"), true)
    @Assert(t.contains("cangjie-coding"), true)
    @Assert(t.contains("local-fixture"), true)
    @Assert(t.contains("test-branch"), true)
}

@Test
public func testRefStatusBrokenManifest(): Unit {
    let dir = refNewCorpus("ref_cli_status_bad")
    writeTextFile(refManifestPath(dir), "not-json")
    let t = refStatusText(dir)
    @Assert(t.contains("解析失败"), true)
}

// ---------------------------------------------------------------- verify

@Test
public func testRefVerifyMissingDir(): Unit {
    let r = refVerifyResult("/tmp/cjh_ut_ref_cli_never_exist_def")
    @Assert(r.ok, false)
    @Assert(r.issues >= 1, true)
}

@Test
public func testRefVerifyWithoutManifest(): Unit {
    let dir = refNewCorpus("ref_cli_verify_nm")
    let r = refVerifyResult(dir)
    @Assert(r.ok, false)
    @Assert(r.text.contains("未找到可用清单"), true)
}

@Test
public func testRefVerifyEmptyManifest(): Unit {
    let dir = refNewCorpus("ref_cli_verify_empty")
    saveRefManifest(dir, refManifestOf(ArrayList<String>(), ArrayList<String>()))
    let r = refVerifyResult(dir)
    @Assert(r.ok, false)
    @Assert(r.text.contains("清单为空"), true)
}

@Test
public func testRefVerifyPassesWhenIntact(): Unit {
    let dir = refReadyCorpus("ref_cli_verify_pass")
    let r = refVerifyResult(dir)
    @Assert(r.ok, true)
    @Assert(r.issues, 0)
    @Assert(r.text.contains("通过"), true)
    @Assert(r.text.contains("2 个文件"), true)
}

@Test
public func testRefVerifyDetectsTamperedFile(): Unit {
    let dir = refReadyCorpus("ref_cli_verify_tamper")
    writeTextFile(dir + "/SKILL.md", "ALPHA-CHANGED")
    let r = refVerifyResult(dir)
    @Assert(r.ok, false)
    @Assert(r.text.contains("被修改"), true)
    @Assert(r.text.contains("SKILL.md"), true)
    @Assert(r.issues, 1)
}

@Test
public func testRefVerifyDetectsMissingFile(): Unit {
    let dir = refReadyCorpus("ref_cli_verify_missing")
    removeTree(dir + "/notes")
    let r = refVerifyResult(dir)
    @Assert(r.ok, false)
    @Assert(r.text.contains("缺失"), true)
    @Assert(r.text.contains("notes/b.md"), true)
    @Assert(r.issues, 1)
}

// ---------------------------------------------------------------- 子命令分发

@Test
public func testRefCliUsageWithoutSubcommand(): Unit {
    let args = ["ref"]
    let r = refCliMain(args, "/tmp/cjh_ut_ref_cli_never_exist_ghi")
    @Assert(r.exitCode, 2)
    @Assert(r.output.contains("用法"), true)
    @Assert(r.output.contains("update"), true)
}

@Test
public func testRefCliUnknownSubcommand(): Unit {
    let args = ["ref", "bogus"]
    let r = refCliMain(args, "/tmp/cjh_ut_ref_cli_never_exist_jkl")
    @Assert(r.exitCode, 2)
    @Assert(r.output.contains("未知子命令"), true)
}

@Test
public func testRefCliStatusExitCode(): Unit {
    let dir = refReadyCorpus("ref_cli_main_status")
    let args = ["ref", "status"]
    let r = refCliMain(args, dir)
    @Assert(r.exitCode, 0)
    @Assert(r.output.contains("cjh 知识层语料状态"), true)
}

@Test
public func testRefCliVerifyExitCodes(): Unit {
    let good = refReadyCorpus("ref_cli_main_verify_good")
    let okRun = refCliMain(["ref", "verify"], good)
    @Assert(okRun.exitCode, 0)

    writeTextFile(good + "/SKILL.md", "changed")
    let badRun = refCliMain(["ref", "verify"], good)
    @Assert(badRun.exitCode, 1)
    @Assert(badRun.output.contains("失败"), true)
}
