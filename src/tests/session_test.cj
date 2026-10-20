package cjh.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*

/**
 * SessionStore 单元测试：保存/恢复/列出/父会话
 */
@Test
public class SessionStoreTest {
    private let dir: String = testTempDir("sessions")

    private func buildStore(): SessionStore {
        return SessionStore(this.dir)
    }

    @TestCase
    public func testSaveAndLoadRoundTrip(): Unit {
        removeTree(this.dir)  // 用例隔离：清理上一用例残留
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "你好"))
        msgs.add(ChatMessage("assistant", "hello"))
        let id = store.save(msgs)
        @Assert(id.startsWith("s"), true)
        @Assert(id.size > 2, true)

        let loaded = store.load(id)
        @Assert(loaded.size, 2)
        @Assert(loaded[0].role, "user")
        @Assert(loaded[0].content, "你好")
        @Assert(loaded[1].role, "assistant")
        @Assert(loaded[1].content, "hello")
    }

    @TestCase
    public func testSaveForkWithParent(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "root"))
        let rootId = store.save(msgs)

        var forkMsgs = ArrayList<ChatMessage>()
        forkMsgs.add(ChatMessage("user", "root"))
        forkMsgs.add(ChatMessage("assistant", "分支"))
        let forkId = store.saveFork(forkMsgs, rootId)

        @Assert(store.parentOf(forkId), rootId)
        @Assert(store.parentOf(rootId), "")
    }

    @TestCase
    public func testListAndTree(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "这是一个很长的用户消息，超过四十个字符用来测试摘要截断行为是否正确"))
        store.save(msgs)

        let list = store.list()
        @Assert(list.size, 1)
        @Assert(list[0][1].size <= 41, true)  // 摘要截断到 40 字符 + …

        let tree = store.listTree()
        @Assert(tree.size, 1)
        @Assert(tree[0][0], list[0][0])  // id 一致
    }

    @TestCase
    public func testLoadNonexistent(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        let loaded = store.load("s999.999")
        @Assert(loaded.size, 0)
    }

    @TestCase
    public func testToolMessageRoundTrip(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "q"))
        msgs.add(ChatMessage("tool", "tool result content", "call_123", "bash"))
        let id = store.save(msgs)
        let loaded = store.load(id)
        @Assert(loaded.size, 2)
        @Assert(loaded[1].role, "tool")
        @Assert(loaded[1].content, "tool result content")
        @Assert(loaded[1].toolCallId, "call_123")
        @Assert(loaded[1].name, "bash")
    }

    @TestCase
    public func testRenamePersistsTitle(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "原始首条消息"))
        msgs.add(ChatMessage("assistant", "ok"))
        let id = store.save(msgs)
        // 重命名前：标题来自首条 user 消息
        @Assert(store.titleOf(id), "原始首条消息")
        @Assert(store.rename(id, "  重构登录模块  "), true)
        // 重命名后：title 优先，且首尾空白被裁掉
        @Assert(store.titleOf(id), "重构登录模块")
        let list = store.list()
        @Assert(list.size, 1)
        @Assert(list[0][1], "重构登录模块")
        // 消息历史不受影响
        @Assert(store.load(id).size, 2)
        // 空白标题拒绝
        @Assert(store.rename(id, "   "), false)
        // 不存在的会话
        @Assert(store.rename("s999.999.9", "x"), false)
    }

    @TestCase
    public func testRemoveSession(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "待删除"))
        let id = store.save(msgs)
        @Assert(store.list().size, 1)
        @Assert(store.removeSession(id), true)
        @Assert(store.list().size, 0)
        @Assert(store.load(id).size, 0)
        // 重复删除返回 false
        @Assert(store.removeSession(id), false)
    }

    @TestCase
    public func testDefectCountFlagsOrphanToolMessage(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        // 健康会话：user + assistant
        var healthy = ArrayList<ChatMessage>()
        healthy.add(ChatMessage("user", "q"))
        healthy.add(ChatMessage("assistant", "a"))
        let hid = store.save(healthy)
        @Assert(store.defectCount(hid), 0)
        // 残缺会话：只有孤儿 tool 消息（回合被打断）
        var broken = ArrayList<ChatMessage>()
        broken.add(ChatMessage("user", "q"))
        broken.add(ChatMessage("tool", "半截结果", "call_missing", "bash"))
        let bid = store.save(broken)
        @Assert(store.defectCount(bid), 1)
    }
}
