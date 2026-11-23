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
    public func testAssistantToolCallsRoundTrip(): Unit {
        // 恢复会话不能丢 assistant.tool_calls：丢了之后 tool 结果变成孤儿，
        // 修复逻辑只能把它们丢掉，模型重启后完全失去"上一轮查过什么"。
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var args = JsonObject()
        args.put("path", JsonString("/tmp/x.txt"))
        var calls = ArrayList<ToolCall>()
        calls.add(ToolCall("call_abc", "read_file", args))
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "看看文件"))
        msgs.add(ChatMessage("assistant", "我来读一下。", calls))
        msgs.add(ChatMessage("tool", "line1\n", "call_abc", "read_file"))
        let id = store.save(msgs)

        let loaded = store.load(id)
        @Assert(loaded.size, 3)
        @Assert(loaded[1].role, "assistant")
        @Assert(loaded[1].content, "我来读一下。")
        @Assert(loaded[1].toolCalls.size, 1)
        @Assert(loaded[1].toolCalls[0].id, "call_abc")
        @Assert(loaded[1].toolCalls[0].name, "read_file")
        @Assert(loaded[1].toolCalls[0].arguments.get("path").getOrThrow().asString().getValue(),
            "/tmp/x.txt")
        // 结果消息仍按 tool_call_id 配对
        @Assert(loaded[2].toolCallId, "call_abc")
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
    public func testInternalNoticesNotPersistedAndTitleSkipsThem(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        var msgs = ArrayList<ChatMessage>()
        msgs.add(ChatMessage("user", "[System Notice] 任务已执行 50 轮（段预算已用尽），请立即结束"))
        msgs.add(ChatMessage("user", "内部续跑提醒", true))
        msgs.add(ChatMessage("user", "真实用户任务"))
        msgs.add(ChatMessage("assistant", "处理中"))
        let id = store.save(msgs)
        let loaded = store.load(id)
        // 内部提醒（新标记 + 旧前缀）都不落盘，只留真实对话
        @Assert(loaded.size, 2)
        @Assert(loaded[0].content, "真实用户任务")
        @Assert(loaded[1].content, "处理中")
        // 会话标题也不能被内部提醒占用
        @Assert(store.titleOf(id), "真实用户任务")
        // 落盘 JSON 里不能残留内部提醒文本
        let raw = String.fromUtf8(File.readFrom(this.dir + "/" + id + ".json"))
        @Assert(raw.contains("System Notice"), false)
        @Assert(raw.contains("内部续跑提醒"), false)

        // 恢复后继续保存走 saveWithId 同样过滤，不能把提醒从内存写回磁盘
        msgs.add(ChatMessage("assistant", "完成"))
        @Assert(store.saveWithId(id, msgs), true)
        let reloaded = store.load(id)
        @Assert(reloaded.size, 3)
        @Assert(reloaded[2].content, "完成")
    }

    @TestCase
    public func testLoadHonorsInternalFlagAndLegacyPrefix(): Unit {
        removeTree(this.dir)
        Directory.create(this.dir, recursive: true)
        let store = this.buildStore()
        // 旧文件：一条带 internal 元数据，一条靠前缀识别
        File.writeTo(this.dir + "/s7.7.7.json",
            ("{\"id\":\"s7.7.7\",\"created\":\"2026-01-01T00:00:00\",\"messages\":[" +
             "{\"role\":\"user\",\"content\":\"续跑指令\",\"internal\":true}," +
             "{\"role\":\"user\",\"content\":\"[System Notice] 你已连续 9 轮只调用 1 个工具\"}]}").toArray())
        let loaded = store.load("s7.7.7")
        @Assert(loaded.size, 2)
        @Assert(loaded[0].hiddenFromUser, true)
        @Assert(loaded[0].isInternalNotice(), true)
        @Assert(loaded[1].isInternalNotice(), true)
        // 列表标题跳过这两条内部提醒（没有真实用户消息 → 空标题，UI 回退显示 ID）
        @Assert(store.titleOf("s7.7.7"), "")
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

    @TestCase
    public func testSessionPaginationBounds(): Unit {
        // 第一页
        let (s0, e0) = sessionPageOf(890, "50", "0")
        @Assert(s0, 0)
        @Assert(e0, 50)
        // 末页不满
        let (s1, e1) = sessionPageOf(890, "50", "880")
        @Assert(s1, 880)
        @Assert(e1, 890)
        // offset 越界：空区间
        let (s2, e2) = sessionPageOf(890, "50", "9999")
        @Assert(s2, 890)
        @Assert(e2, 890)
        // 不传 limit（旧客户端）= 全部
        let (s3, e3) = sessionPageOf(890, "", "")
        @Assert(s3, 0)
        @Assert(e3, 890)
        // 非法 / 负数 / limit 超过总数都收敛到合法区间
        let (s4, e4) = sessionPageOf(10, "abc", "-5")
        @Assert(s4, 0)
        @Assert(e4, 10)
        let (s5, e5) = sessionPageOf(10, "999", "0")
        @Assert(s5, 0)
        @Assert(e5, 10)
    }
}
