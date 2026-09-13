package cjh.tests

import std.collection.*
import std.fs.*
import cjh.tools.*
import cjutil.*

// 注意：本仓 @Assert 是「等式断言」——@Assert(actual, expected)，第二参是期望值而非消息；
// 逻辑真值断言写 @Assert(cond, true)，期望为假写 @Assert(cond, false)。
//
// 本文件覆盖三期「语料刷新」（ref_update.cj）：清单重扫、来源摄取、预演、回滚。
// 一律走公共 API（refRebuild / refUpdate / refCliMain）断言可观测结果，不测私有实现；
// refNewCorpus / refPutFile 复用 ref_cli_test.cj 的辅助。

// ---------------------------------------------------------------- 辅助

/** 造语料：skills/alpha/SKILL.md + skills/beta/extra.md + 根级 README.md（不应被收录）。 */
func ruCorpus(name: String): String {
    let dir = refNewCorpus(name)
    refPutFile(dir, "skills/alpha", "SKILL.md", "alpha-body")
    refPutFile(dir, "skills/beta", "extra.md", "beta-body")
    refPutFile(dir, "", "README.md", "root-level-not-collected")
    return dir
}

/** 造发布件布局来源：.agents/skills/foo/（含 2 篇 .md + 1 个非 .md）。 */
func ruSourceAgents(name: String): String {
    let dir = refNewCorpus(name)
    refPutFile(dir, ".agents/skills/foo", "SKILL.md", "foo-body")
    refPutFile(dir, ".agents/skills/foo", "guide.md", "foo-guide")
    refPutFile(dir, ".agents/skills/foo/notes", "deep.txt", "not-markdown")
    return dir
}

/** 造本地目录布局来源：skills/<名>/。 */
func ruSourceSkills(name: String): String {
    let dir = refNewCorpus(name)
    refPutFile(dir, "skills/bar", "SKILL.md", "bar-body")
    return dir
}

/** 造选项：只指定来源目录（离线）。 */
func ruLocalOpts(source: String): RefUpdateOptions {
    let o = RefUpdateOptions()
    o.source = source
    return o
}

// ---------------------------------------------------------------- rebuild

@Test
public func testRefRebuildFailsWithoutCorpus(): Unit {
    let r = refRebuild("/tmp/cjh_ut_ru_never_exist_ghi")
    @Assert(r.exitCode, 1)
    @Assert(r.output.contains("语料目录不存在"), true)
}

@Test
public func testRefRebuildFailsWhenNothingCollectable(): Unit {
    let dir = refNewCorpus("ru_rebuild_empty")
    refPutFile(dir, "", "loose.md", "不在 skills/ 下，不应收录")
    let r = refRebuild(dir)
    @Assert(r.exitCode, 1)
    @Assert(r.output.contains("未找到可收录正文"), true)
    @Assert(exists(refManifestPath(dir)), false)
}

@Test
public func testRefRebuildWritesManifestAndVerifyPasses(): Unit {
    let dir = ruCorpus("ru_rebuild_ok")
    let r = refRebuild(dir)
    @Assert(r.exitCode, 0)
    let m = loadRefManifest(dir).getOrThrow()
    @Assert(m.entries.size, 2)
    @Assert(m.markdownCount, 2)
    @Assert(m.totalBytes, 19)
    @Assert(m.skills.size, 2)
    let v = refVerifyResult(dir)
    @Assert(v.ok, true)
    @Assert(v.issues, 0)
}

@Test
public func testRefRebuildKeepsPreviousSourceLabels(): Unit {
    let dir = ruCorpus("ru_rebuild_labels")
    let m = RefManifest()
    m.source = "https://example.com/repo"
    m.branch = "cangjie-1.0.5"
    m.mode = "git"
    saveRefManifest(dir, m)
    let r = refRebuild(dir)
    @Assert(r.exitCode, 0)
    let back = loadRefManifest(dir).getOrThrow()
    @Assert(back.source, "https://example.com/repo")
    @Assert(back.branch, "cangjie-1.0.5")
    @Assert(back.mode, "git")
    @Assert(back.entries.size, 2)
}

// ---------------------------------------------------------------- update：预演

@Test
public func testRefUpdateDryRunTouchesNothing(): Unit {
    let corpus = ruCorpus("ru_upd_dry")
    let src = ruSourceAgents("ru_upd_dry_src")
    let o = ruLocalOpts(src)
    o.dryRun = true
    let r = refUpdate(corpus, o)
    @Assert(r.exitCode, 0)
    @Assert(r.output.contains("预演"), true)
    @Assert(r.output.contains("foo"), true)
    // 预演不落盘：没多出技能目录、没写清单、没建快照
    @Assert(exists(corpus + "/skills/foo"), false)
    @Assert(exists(refManifestPath(corpus)), false)
    @Assert(exists(corpus + ".prev"), false)
}

// ---------------------------------------------------------------- update：离线摄取

@Test
public func testRefUpdateFromAgentsLayout(): Unit {
    let corpus = ruCorpus("ru_upd_agents")
    let src = ruSourceAgents("ru_upd_agents_src")
    let r = refUpdate(corpus, ruLocalOpts(src))
    @Assert(r.exitCode, 0)
    @Assert(exists(corpus + "/skills/foo/SKILL.md"), true)
    @Assert(exists(corpus + "/skills/foo/guide.md"), true)
    @Assert(exists(corpus + "/skills/foo/notes/deep.txt"), false) // 非 .md 不收
    @Assert(exists(corpus + "/skills/alpha/SKILL.md"), true) // 既有语料保持不动
    let m = loadRefManifest(corpus).getOrThrow()
    @Assert(m.entries.size, 4) // alpha + beta + foo/SKILL.md + foo/guide.md
    @Assert(m.markdownCount, 4)
    @Assert(m.skills.contains("foo"), true)
    @Assert(m.mode, "local")
    let v = refVerifyResult(corpus)
    @Assert(v.ok, true)
    removeTree(corpus + ".prev")
}

@Test
public func testRefUpdateFromSkillsLayout(): Unit {
    let corpus = ruCorpus("ru_upd_skills")
    let src = ruSourceSkills("ru_upd_skills_src")
    let r = refUpdate(corpus, ruLocalOpts(src))
    @Assert(r.exitCode, 0)
    @Assert(exists(corpus + "/skills/bar/SKILL.md"), true)
    @Assert(loadRefManifest(corpus).getOrThrow().skills.contains("bar"), true)
    removeTree(corpus + ".prev")
}

@Test
public func testRefUpdatePrefersAgentsLayoutWhenBothExist(): Unit {
    let corpus = ruCorpus("ru_upd_both")
    let src = refNewCorpus("ru_upd_both_src")
    refPutFile(src, ".agents/skills/foo", "SKILL.md", "foo-body")
    refPutFile(src, "skills/bar", "SKILL.md", "bar-body")
    let o = ruLocalOpts(src)
    o.dryRun = true
    let r = refUpdate(corpus, o)
    @Assert(r.exitCode, 0)
    @Assert(r.output.contains("foo"), true)
    @Assert(r.output.contains("bar"), false)
}

// ---------------------------------------------------------------- update：错误路径

@Test
public func testRefUpdateMissingSourceFails(): Unit {
    let corpus = ruCorpus("ru_upd_miss")
    let r = refUpdate(corpus, ruLocalOpts("/tmp/cjh_ut_ru_never_exist_jkl"))
    @Assert(r.exitCode, 1)
    @Assert(r.output.contains("来源目录不存在"), true)
    @Assert(exists(refManifestPath(corpus)), false)
}

@Test
public func testRefUpdateSourceWithoutSkillsFails(): Unit {
    let corpus = ruCorpus("ru_upd_noskills")
    let src = refNewCorpus("ru_upd_noskills_src")
    refPutFile(src, "", "loose.md", "不在技能目录下")
    let r = refUpdate(corpus, ruLocalOpts(src))
    @Assert(r.exitCode, 1)
    @Assert(r.output.contains("来源里没有可用技能"), true)
    @Assert(exists(refManifestPath(corpus)), false) // 失败不留半成品
}

// ---------------------------------------------------------------- update：回滚

@Test
public func testRefUpdateRestoreKeepsCorpusIntact(): Unit {
    // 回归：回滚必须「先复制到临时目录确认非空、再动现网」——
    // 早期实现先删现网再复制，复制一旦失败（如目标目录已存在导致 Directory.create 抛异常）
    // 就把语料删成了空的。
    let corpus = ruCorpus("ru_upd_restore")
    let src = ruSourceAgents("ru_upd_restore_src")
    @Assert(refUpdate(corpus, ruLocalOpts(src)).exitCode, 0)
    @Assert(exists(corpus + "/skills/foo/SKILL.md"), true)

    let ro = RefUpdateOptions()
    ro.restore = true
    let r = refUpdate(corpus, ro)
    @Assert(r.exitCode, 0)
    @Assert(exists(corpus + "/skills/foo"), false) // 新增技能已回滚
    @Assert(exists(corpus + "/skills/alpha/SKILL.md"), true) // 原有语料仍在
    @Assert(exists(corpus + "/skills/beta/extra.md"), true)
    let v = refVerifyResult(corpus)
    @Assert(v.ok, true)
    @Assert(v.issues, 0)
    removeTree(corpus + ".prev")
}

@Test
public func testRefRestoreWithoutSnapshotFailsAndKeepsCorpus(): Unit {
    let corpus = ruCorpus("ru_restore_none")
    removeTree(corpus + ".prev")
    let ro = RefUpdateOptions()
    ro.restore = true
    let r = refUpdate(corpus, ro)
    @Assert(r.exitCode, 1)
    @Assert(r.output.contains("没有可用快照"), true)
    @Assert(exists(corpus + "/skills/alpha/SKILL.md"), true)
    @Assert(exists(corpus + "/skills/beta/extra.md"), true)
}

// ---------------------------------------------------------------- CLI 分发

@Test
public func testRefCliDispatchRebuild(): Unit {
    let corpus = ruCorpus("ru_cli_rebuild")
    let r = refCliMain(["ref", "rebuild"], corpus)
    @Assert(r.exitCode, 0)
    @Assert(loadRefManifest(corpus).getOrThrow().entries.size, 2)
}

@Test
public func testRefCliDispatchUpdateDryRun(): Unit {
    let corpus = ruCorpus("ru_cli_upd")
    let src = ruSourceAgents("ru_cli_upd_src")
    let r = refCliMain(["ref", "update", "--source", src, "--dry-run"], corpus)
    @Assert(r.exitCode, 0)
    @Assert(r.output.contains("预演"), true)
    @Assert(exists(corpus + "/skills/foo"), false)
}

@Test
public func testRefCliDispatchUpdateMissingOptionValue(): Unit {
    let corpus = ruCorpus("ru_cli_badopt")
    let r = refCliMain(["ref", "update", "--source"], corpus)
    @Assert(r.exitCode, 2)
    @Assert(r.output.contains("缺少参数值"), true)
    @Assert(r.output.contains("用法"), true)
}

@Test
public func testRefCliDispatchUpdateUnknownOption(): Unit {
    let corpus = ruCorpus("ru_cli_badopt2")
    let r = refCliMain(["ref", "update", "--nope"], corpus)
    @Assert(r.exitCode, 2)
    @Assert(r.output.contains("未知选项"), true)
}
