package cjh.tests

import cjutil.*

import std.collection.*
import std.fs.*
import cjcfg.*

/**
 * WorkspaceManager 单元测试：CRUD、最近访问排序、持久化往返
 */
@Test
public class WorkspaceManagerTest {

    @TestCase
    public func testAddAndDefaultName(): Unit {
        let cfgDir = testTempDir("ws1")
        let mgr = WorkspaceManager(cfgDir)
        let w = mgr.add("/home/user/project-a", "")
        @Assert(w.name, "project-a")  // 默认名 = 路径最后一段
        @Assert(w.path, "/home/user/project-a")
        @Assert(mgr.list().size, 1)
    }

    @TestCase
    public func testAddDuplicateUpdates(): Unit {
        let cfgDir = testTempDir("ws2")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add(tmpPath("a"), "name1")
        let w2 = mgr.add(tmpPath("a"), "name2")
        @Assert(w2.name, "name2")  // 同 path 更新 name
        @Assert(mgr.list().size, 1)  // 不重复
    }

    @TestCase
    public func testListSortedByLastAccess(): Unit {
        let cfgDir = testTempDir("ws3")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add(tmpPath("first"), "first")
        mgr.add(tmpPath("second"), "second")
        // 重新 touch first → first 最新
        mgr.touch(tmpPath("first"))
        let list = mgr.list()
        @Assert(list.size, 2)
        @Assert(list[0].path, tmpPath("first"))  // 最近访问在前
        @Assert(list[1].path, tmpPath("second"))
    }

    @TestCase
    public func testRemove(): Unit {
        let cfgDir = testTempDir("ws4")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add(tmpPath("rm"), "rm")
        @Assert(mgr.remove(tmpPath("rm")), true)
        @Assert(mgr.remove(tmpPath("rm")), false)  // 二次删除 false
        @Assert(mgr.list().size, 0)
    }

    @TestCase
    public func testSaveLoadRoundTrip(): Unit {
        let cfgDir = testTempDir("ws5")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add(tmpPath("p1"), "项目一")
        mgr.add(tmpPath("p2"), "p2")
        mgr.save()
        // 新实例从磁盘加载
        let mgr2 = WorkspaceManager(cfgDir)
        let list = mgr2.list()
        @Assert(list.size, 2)
        var hasP1 = false
        var hasP2 = false
        for (w in list) {
            if (w.path == tmpPath("p1") && w.name == "项目一") { hasP1 = true }
            if (w.path == tmpPath("p2")) { hasP2 = true }
        }
        @Assert(hasP1, true)
        @Assert(hasP2, true)
        // lastAccess 持久化（非 0）
        @Assert(list[0].lastAccess > 0, true)
    }

    @TestCase
    public func testLoadNonexistent(): Unit {
        let cfgDir = testTempDir("ws6")
        let mgr = WorkspaceManager(cfgDir)
        @Assert(mgr.list().size, 0)
    }
}

/**
 * 工作区目录保证（"新建工作区"的落点）
 *
 * Web POST /api/workspaces 原先只登记路径、**不校验存在性**（可登记死路径），
 * 也没有"新建目录"入口。本组用例锁定 ensureWorkspaceDir 的契约：
 * 已存在目录=通过（幂等）；不存在且 create=false=可读错误（含提示）；
 * 不存在且 create=true=递归创建；路径是文件=拒绝。
 */
@Test
public class WorkspaceDirEnsureTest {

    @TestCase
    public func testExistingDirOk(): Unit {
        let base = testTempDir("ws_ensure1")
        let target = base + "/proj"
        if (!exists(target)) {
            Directory.create(target, recursive: true)
        }
        let (ok, err) = ensureWorkspaceDir(target, false)
        @Assert(ok, true)
        @Assert(err, "")
    }

    @TestCase
    public func testMissingDirWithoutCreateFails(): Unit {
        let base = testTempDir("ws_ensure2")
        let target = base + "/not-yet"
        let (ok, err) = ensureWorkspaceDir(target, false)
        @Assert(ok, false)
        @Assert(err.contains("不存在"), true)  // 可读原因，含 create 提示
        @Assert(err.contains("create"), true)
        @Assert(exists(target), false)         // 不得偷偷建目录
    }

    @TestCase
    public func testCreateRecursiveAndIdempotent(): Unit {
        let base = testTempDir("ws_ensure3")
        let target = base + "/a/b/c"
        let (ok1, err1) = ensureWorkspaceDir(target, true)
        @Assert(ok1, true)
        @Assert(err1, "")
        @Assert(FileInfo(target).isDirectory(), true)
        // 幂等：已存在目录再次 create=true 不报错（Directory.create 本身不幂等）
        let (ok2, err2) = ensureWorkspaceDir(target, true)
        @Assert(ok2, true)
        @Assert(err2, "")
    }

    @TestCase
    public func testFileIsNotWorkspace(): Unit {
        let base = testTempDir("ws_ensure4")
        let f = base + "/afile.txt"
        File.writeTo(f, "x".toArray())
        let (ok, err) = ensureWorkspaceDir(f, false)
        @Assert(ok, false)
        @Assert(err.contains("不是目录"), true)
    }

    @TestCase
    public func testEmptyPathRejected(): Unit {
        let (ok, err) = ensureWorkspaceDir("", true)
        @Assert(ok, false)
        @Assert(err.size > 0, true)
    }
}
