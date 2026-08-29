package cjh.tests

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
        mgr.add("/tmp/a", "name1")
        let w2 = mgr.add("/tmp/a", "name2")
        @Assert(w2.name, "name2")  // 同 path 更新 name
        @Assert(mgr.list().size, 1)  // 不重复
    }

    @TestCase
    public func testListSortedByLastAccess(): Unit {
        let cfgDir = testTempDir("ws3")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add("/tmp/first", "first")
        mgr.add("/tmp/second", "second")
        // 重新 touch first → first 最新
        mgr.touch("/tmp/first")
        let list = mgr.list()
        @Assert(list.size, 2)
        @Assert(list[0].path, "/tmp/first")  // 最近访问在前
        @Assert(list[1].path, "/tmp/second")
    }

    @TestCase
    public func testRemove(): Unit {
        let cfgDir = testTempDir("ws4")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add("/tmp/rm", "rm")
        @Assert(mgr.remove("/tmp/rm"), true)
        @Assert(mgr.remove("/tmp/rm"), false)  // 二次删除 false
        @Assert(mgr.list().size, 0)
    }

    @TestCase
    public func testSaveLoadRoundTrip(): Unit {
        let cfgDir = testTempDir("ws5")
        let mgr = WorkspaceManager(cfgDir)
        mgr.add("/tmp/p1", "项目一")
        mgr.add("/tmp/p2", "p2")
        mgr.save()
        // 新实例从磁盘加载
        let mgr2 = WorkspaceManager(cfgDir)
        let list = mgr2.list()
        @Assert(list.size, 2)
        var hasP1 = false
        var hasP2 = false
        for (w in list) {
            if (w.path == "/tmp/p1" && w.name == "项目一") { hasP1 = true }
            if (w.path == "/tmp/p2") { hasP2 = true }
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
