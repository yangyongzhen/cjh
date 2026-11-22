package cjh.tests

import std.collection.*
import std.fs.*
import std.env.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjh.web.*

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
        // 49 个中文字符（>40），验证按 rune 截断而不是按字节切在字符中间
        msgs.add(ChatMessage("user", "这是一个很长的用户消息，超过四十个字符用来测试摘要截断行为是否正确，补充更多文字确保超过四十个字符"))
        store.save(msgs)

        let list = store.list()
        @Assert(list.size, 1)
        @Assert(list[0][1].toRuneArray().size, 41)  // 40 字符 + …
        @Assert(list[0][1].endsWith("…"), true)

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

    @TestCase
    public func testSaveRecordsCwdAndListScoped(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        let cwd = getWorkingDirectory().toString()

        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "本项目会话"))
        let mine = store.save(msgs)
        @Assert(store.cwdOf(mine), cwd)
        @Assert(store.cwdOf("s0.0.0"), "")  // 不存在

        // 旧会话（无 cwd）+ 其它工作区会话：用文件直接构造，模拟升级前数据
        File.writeTo(this.dir + "/s1.1.1.json",
            ("{\"id\":\"s1.1.1\",\"created\":\"2026-01-01T00:00:00\",\"messages\":[{\"role\":\"user\",\"content\":\"legacy\"}]}").toArray())
        File.writeTo(this.dir + "/s2.2.2.json",
            ("{\"id\":\"s2.2.2\",\"created\":\"2026-01-02T00:00:00\",\"cwd\":\"/other/project\",\"messages\":[{\"role\":\"user\",\"content\":\"other\"}]}").toArray())

        // 本项目 + 旧会话；不含其它项目
        let scoped = store.listScoped(cwd, true)
        @Assert(scoped.size, 2)
        let strict = store.listScoped(cwd, false)
        @Assert(strict.size, 1)
        @Assert(strict[0][0], mine)
        // 切到其它项目：包含它自己 + 无归属旧会话
        let other = store.listScoped("/other/project", true)
        @Assert(other.size, 2)
        // 不存在的项目：只剩旧会话（includeLegacy=false 时为空）
        @Assert(store.listScoped("/nope", true).size, 1)
        @Assert(store.listScoped("/nope", false).size, 0)
    }

    @TestCase
    public func testSaveWithIdDoesNotDuplicateAndKeepsUsage(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        let id = store.newSessionId()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "第一轮"))

        // 新会话 + 用量：一次落盘
        @Assert(store.saveWithIdUsage(id, msgs, SessionUsage(120, 30, 60, 2, 1, 2500)), true)
        @Assert(store.list().size, 1)
        let cwd = store.cwdOf(id)
        @Assert(cwd.size > 0, true)

        // 恢复后再保存：必须覆盖同一文件，且不传 usage 时保留已记录用量
        msgs.add(ChatMessage("assistant", "第二轮"))
        @Assert(store.saveWithId(id, msgs), true)
        @Assert(store.list().size, 1)
        @Assert(store.load(id).size, 2)
        @Assert(store.cwdOf(id), cwd)
        match (store.usageOf(id)) {
            case Some(u) =>
                @Assert(u.promptTokens, 120)
                @Assert(u.completionTokens, 30)
                @Assert(u.cachedTokens, 60)
                @Assert(u.rounds, 2)
                @Assert(u.tools, 1)
                @Assert(u.durationMs, 2500)
            case None => @Assert("usage 应已持久化", "")
        }

        // 未记录用量的会话：缺键而非全零
        let plain = store.newSessionId()
        @Assert(store.saveWithId(plain, msgs), true)
        match (store.usageOf(plain)) {
            case Some(_) => @Assert("无 usage 的会话不应伪造数据", "")
            case None => @Assert(true, true)
        }

        // 累计语义：同一会话再跑一轮，用量相加而不是覆盖
        @Assert(store.saveWithIdUsage(id, msgs, SessionUsage(10, 5, 0, 1, 0, 100)), true)
        match (store.usageOf(id)) {
            case Some(u) =>
                @Assert(u.promptTokens, 130)
                @Assert(u.completionTokens, 35)
                @Assert(u.rounds, 3)
            case None => @Assert("累计用量应保留", "")
        }
        @Assert(store.saveWithId("", msgs), false)
    }

    @TestCase
    public func testWebQueryAndSessionTimestamp(): Unit {
        @Assert(queryParamOf(Some("scope=project&x=1"), "scope"), "project")
        @Assert(queryParamOf(Some("x=1&scope=all"), "scope"), "all")
        @Assert(queryParamOf(Some("scope="), "scope"), "")
        @Assert(queryParamOf(None, "scope"), "")
        @Assert(sessionCreatedAt("s1787665309"), 1787665309)
        @Assert(sessionCreatedAt("s1787665309.123.4"), 1787665309)
        @Assert(sessionCreatedAt("garbage"), 0)
        @Assert(sessionCreatedAt("s"), 0)
    }
}
