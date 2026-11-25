package cjh.agent

import std.collection.*
import stdx.encoding.json.*
import cjllm.*
import cjcfg.*
import cjh.tools.*
import std.fs.*

/**
 * 回合内只读工具缓存（工具名 + 参数 + 解析路径）回归测试。
 *
 * 目标：长任务里模型反复 read_file/grep/glob/list_dir 同一目标时，第二次起直接回填；
 * 任何写工具执行后缓存必须整表失效，避免拿旧内容继续推理。
 */

/** 按脚本逐轮返回响应，脚本耗尽后返回最终文本。 */
class CacheScriptProvider <: LlmProvider {
    public let script: ArrayList<ModelResponse>
    public var calls: Int64 = 0
    /** 每次请求前的钩子（测试用：模拟外部进程在两轮之间改文件） */
    public var onChat: (Int64) -> Unit = { _ => }

    public init(script: ArrayList<ModelResponse>) {
        this.script = script
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        this.calls += 1
        this.onChat(this.calls)
        if (this.calls <= Int64(this.script.size)) {
            return this.script[this.calls - 1]
        }
        return ModelResponse("CACHE-DONE", ArrayList<ToolCall>())
    }
}

/** 模拟只读文件工具；可配置前 N 次返回错误。 */
class CacheReadTool <: CjhTool {
    public var calls: Int64 = 0
    public let failFirst: Bool

    public init(failFirst: Bool) {
        this.failFirst = failFirst
    }

    public override func spec(): ToolSpec {
        return ToolSpec("read_file", "cache read probe", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        if (this.failFirst && this.calls == 1) {
            return ToolResult("READ-ERROR", true)
        }
        // 假工具也要有一个真实路径，缓存条目才能记录 mtime（生产里成功读取必然有文件）
        if (let Some(pv) <- args.get("path")) {
            let p = pv.asString().getValue()
            if (!exists(p)) {
                File.writeTo(p, "cache probe\n".toArray())
            }
        }
        return ToolResult("READ-CONTENT", false)
    }

    public override func isReadOnly(): Bool {
        return true
    }
}

/** 模拟写工具；执行后应使只读缓存失效。 */
class CacheWriteTool <: CjhTool {
    public var calls: Int64 = 0

    public override func spec(): ToolSpec {
        return ToolSpec("write_file", "cache write probe", JsonObject())
    }

    public override func execute(args: JsonObject): ToolResult {
        this.calls += 1
        return ToolResult("WROTE", false)
    }

    public override func isReadOnly(): Bool {
        return false
    }
}

func cacheCall(id: String, path: String, offset: Int64): ToolCall {
    var args = JsonObject()
    args.put("path", JsonString(path))
    args.put("offset", JsonInt(offset))
    return ToolCall(id, "read_file", args)
}

func cacheBuildAgent(script: ArrayList<ModelResponse>, read: CacheReadTool,
    write: ?CjhTool): Agent {
    let registry = ToolRegistry()
    registry.register(read)
    if (let Some(w) <- write) {
        registry.register(w)
    }
    return Agent(CacheScriptProvider(script), registry, AgentConfig("cache test", 8, Capability()))
}

func cacheToolContents(agent: Agent): ArrayList<String> {
    let out = ArrayList<String>()
    for (m in agent.getMessages()) {
        if (m.role == "tool") {
            out.add(m.content)
        }
    }
    return out
}

@Test
public class ToolResultCacheTest {

    @TestCase
    public func testRepeatedReadHitsCache() {
        let read = CacheReadTool(false)
        let script = ArrayList<ModelResponse>()
        script.add(ModelResponse("read once", ArrayList<ToolCall>([cacheCall("c1", "/tmp/cjh_cache_a.cj", 0)])))
        // 第二轮参数完全相同：不执行工具，直接回填
        script.add(ModelResponse("read again", ArrayList<ToolCall>([cacheCall("c2", "/tmp/cjh_cache_a.cj", 0)])))
        let agent = cacheBuildAgent(script, read, None)
        let summary = agent.run("重复读同一文件")

        @Assert(summary.reply, "CACHE-DONE")
        @Assert(read.calls, 1)
        @Assert(summary.toolCacheHits, 1)
        @Assert(agent.toolCacheHitCount(), 1)
        let contents = cacheToolContents(agent)
        @Assert(contents.size, 2)
        @Assert(contents[0], "READ-CONTENT")
        @Assert(contents[1], "READ-CONTENT")
    }

    @TestCase
    public func testWriteInvalidatesReadCache() {
        let read = CacheReadTool(false)
        let write = CacheWriteTool()
        let script = ArrayList<ModelResponse>()
        script.add(ModelResponse("read", ArrayList<ToolCall>([cacheCall("c1", "/tmp/cjh_cache_b.cj", 0)])))
        let writeArgs = JsonObject()
        writeArgs.put("path", JsonString("/tmp/cjh_cache_other.cj"))
        script.add(ModelResponse("write", ArrayList<ToolCall>([ToolCall("c2", "write_file", writeArgs)])))
        script.add(ModelResponse("read after write",
            ArrayList<ToolCall>([cacheCall("c3", "/tmp/cjh_cache_b.cj", 0)])))
        script.add(ModelResponse("read again",
            ArrayList<ToolCall>([cacheCall("c4", "/tmp/cjh_cache_b.cj", 0)])))
        let agent = cacheBuildAgent(script, read, Some(write))
        let summary = agent.run("写后必须重读")

        @Assert(summary.reply, "CACHE-DONE")
        @Assert(write.calls, 1)
        // 写前一次 + 写后一次 = 2；第 4 次读命中写后缓存
        @Assert(read.calls, 2)
        @Assert(summary.toolCacheHits, 1)
    }

    @TestCase
    public func testDifferentArgsDoNotShareCache() {
        let read = CacheReadTool(false)
        let script = ArrayList<ModelResponse>()
        script.add(ModelResponse("read head", ArrayList<ToolCall>([cacheCall("c1", "/tmp/cjh_cache_c.cj", 0)])))
        script.add(ModelResponse("read tail", ArrayList<ToolCall>([cacheCall("c2", "/tmp/cjh_cache_c.cj", 10)])))
        let agent = cacheBuildAgent(script, read, None)
        let summary = agent.run("不同 offset 是不同读")

        @Assert(summary.reply, "CACHE-DONE")
        @Assert(read.calls, 2)
        @Assert(summary.toolCacheHits, 0)
    }

    @TestCase
    public func testExternalFileChangeInvalidatesCache() {
        let path = "/tmp/cjh_ut_tool_cache_mtime.txt"
        File.writeTo(path, "v1\n".toArray())
        let read = CacheReadTool(false)
        let script = ArrayList<ModelResponse>()
        script.add(ModelResponse("read v1", ArrayList<ToolCall>([cacheCall("c1", path, 0)])))
        script.add(ModelResponse("read after external edit",
            ArrayList<ToolCall>([cacheCall("c2", path, 0)])))
        script.add(ModelResponse("read unchanged",
            ArrayList<ToolCall>([cacheCall("c3", path, 0)])))
        let provider = CacheScriptProvider(script)
        // 第 2 次请求前（首轮工具已执行并缓存）模拟外部进程改文件
        provider.onChat = { n =>
            if (n == 2) {
                sleep(Duration.millisecond * 1100)
                File.writeTo(path, "v2\n".toArray())
            }
        }
        let registry = ToolRegistry()
        registry.register(read)
        let agent = Agent(provider, registry, AgentConfig("cache mtime test", 8, Capability()))
        let summary = agent.run("外部改文件必须重读")

        @Assert(summary.reply, "CACHE-DONE")
        // v1 缓存 → 外部改成 v2（mtime 变）→ 重读并缓存 → 第三次未变，命中
        @Assert(read.calls, 2)
        @Assert(summary.toolCacheHits, 1)
    }

    @TestCase
    public func testErrorResultsAreNotCached() {
        let read = CacheReadTool(true)
        let script = ArrayList<ModelResponse>()
        script.add(ModelResponse("fails", ArrayList<ToolCall>([cacheCall("c1", "/tmp/cjh_cache_d.cj", 0)])))
        script.add(ModelResponse("succeeds", ArrayList<ToolCall>([cacheCall("c2", "/tmp/cjh_cache_d.cj", 0)])))
        script.add(ModelResponse("hits success", ArrayList<ToolCall>([cacheCall("c3", "/tmp/cjh_cache_d.cj", 0)])))
        let agent = cacheBuildAgent(script, read, None)
        let summary = agent.run("错误不缓存")

        @Assert(summary.reply, "CACHE-DONE")
        // 第一次错误未缓存 → 第二次重新执行并缓存成功结果 → 第三次命中
        @Assert(read.calls, 2)
        @Assert(summary.toolCacheHits, 1)
        let contents = cacheToolContents(agent)
        @Assert(contents.size, 3)
        @Assert(contents[0], "READ-ERROR")
        @Assert(contents[1], "READ-CONTENT")
        @Assert(contents[2], "READ-CONTENT")
    }
}
