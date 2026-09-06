package cjh.tests

import std.collection.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import cjllm.*
import cjh.tools.*
import cjh.agent.*
import cjcfg.*

/**
 * V2d DAG 并发引擎 · 计时基准测试
 *
 * 模拟真实场景：LLM 单轮发出 N 个"慢工具"调用（各 sleep 300ms，模拟
 * web_fetch / bash 长命令等 IO 型工具的真实耗时），实测加速比：
 *   无依赖批：总耗时 ≈ max(单工具耗时)   而非 N × 单工具耗时
 *   同资源批：总耗时 ≈ N × 单工具耗时    （DAG 正确串行，抑制竞态）
 *
 * 实现说明：慢工具注册名为 "write_file"（execute 只睡不写）——
 * 引擎的资源识别 extractResourceAccess 按工具名提取 args.path 作为资源键，
 * 用内置工具名才能让 path 参数参与依赖分析；未知工具名走保守分支不建边。
 */

/** 模拟慢工具：睡 ms 毫秒后返回完成标记（注册为 write_file 以参与 DAG 资源识别） */
public class SimulatedSlowTool <: CjhTool {
    private let ms: Int64
    public init(ms: Int64) {
        this.ms = ms
    }

    public func spec(): ToolSpec {
        var props = JsonObject()
        props.put("path", JsonObject())
        var schema = JsonObject()
        schema.put("type", JsonString("object"))
        schema.put("properties", props)
        return ToolSpec("write_file", "slow io probe for benchmark", schema)
    }

    public func execute(args: JsonObject): ToolResult {
        sleep(Duration.millisecond * this.ms)
        return ToolResult("slow-probe-done-${this.ms}ms", false)
    }

    public func isReadOnly(): Bool {
        return true
    }
}

/**
 * 脚本化 provider：按轮次发预设的工具调用批
 * 记录每轮 chatStream 的毫秒时间戳：相邻两轮开始时间之差 ≈ 其间那批工具的总耗时
 */
public class DagBenchProvider <: LlmProvider {
    public var callCount: Int64 = 0
    public let ms: Int64
    public var roundStartMs: ArrayList<Int64> = ArrayList<Int64>()
    private let epoch: DateTime

    public init(ms: Int64) {
        this.ms = ms
        this.epoch = DateTime.now()
    }

    private func nowMs(): Int64 {
        return (DateTime.now() - this.epoch).toMilliseconds()
    }

    /** 构造一个慢 probe 调用；工具名 write_file → 引擎按 path 参数识别资源 */
    static func probe(id: String, resource: String, ms: Int64): ToolCall {
        var args = JsonObject()
        args.put("path", JsonString(resource))
        return ToolCall(id, "write_file", args)
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        roundStartMs.add(this.nowMs())
        callCount += 1
        var calls = ArrayList<ToolCall>()
        match (callCount) {
            case 1 =>
                // 并发实验批：4 个不同 path 的"写" → 规则"不同 path 可并发（即使都是写）" → 全并发
                calls.add(DagBenchProvider.probe("b1", "/tmp/cjh_bench/r1", this.ms))
                calls.add(DagBenchProvider.probe("b2", "/tmp/cjh_bench/r2", this.ms))
                calls.add(DagBenchProvider.probe("b3", "/tmp/cjh_bench/r3", this.ms))
                calls.add(DagBenchProvider.probe("b4", "/tmp/cjh_bench/r4", this.ms))
            case 2 =>
                // 串行对照组批：4 个"写"全落同一 path → 规则"同 path 且含写 → 串行" → 链式依赖
                calls.add(DagBenchProvider.probe("s1", "/tmp/cjh_bench/same", this.ms))
                calls.add(DagBenchProvider.probe("s2", "/tmp/cjh_bench/same", this.ms))
                calls.add(DagBenchProvider.probe("s3", "/tmp/cjh_bench/same", this.ms))
                calls.add(DagBenchProvider.probe("s4", "/tmp/cjh_bench/same", this.ms))
            case _ =>
                return ModelResponse("BENCH-DONE", ArrayList<ToolCall>())
        }
        return ModelResponse("thinking", calls)
    }
}

@Test
public class DagBenchTest {
    @TestCase
    public func testDagParallelSpeedupTiming(): Unit {
        let ms: Int64 = 300  // 模拟每个工具 300ms 的 IO 耗时
        let provider = DagBenchProvider(ms)
        let registry = ToolRegistry()
        registry.register(SimulatedSlowTool(ms))
        let spillDir = testTempDir("dagbench")
        let config = AgentConfig("dag bench", 10, Capability(),
            0, 0, 6, 2000, spillDir, "sess-bench")
        let agent = Agent(provider, registry, config)

        let t0 = DateTime.now()
        let summary = agent.run("dag benchmark")
        let totalMs = (DateTime.now() - t0).toMilliseconds()

        // 相邻轮开始时间之差 ≈ 其间那批工具的执行总耗时
        var batch1Ms: Int64 = -1
        var batch2Ms: Int64 = -1
        if (provider.roundStartMs.size >= 3) {
            batch1Ms = provider.roundStartMs[1] - provider.roundStartMs[0]
            batch2Ms = provider.roundStartMs[2] - provider.roundStartMs[1]
        }

        // 预期：批1（4 个不同 path）= max(300) ≈ 300ms 并发；批2（4 个同 path）= 4×300 = 1200ms 串行
        var report = StringBuilder()
        report.append("=== V2d DAG 并发引擎基准（单工具 ${ms}ms）===\n")
        report.append("批1 4 个不同 path：实测 ${batch1Ms}ms（理论并发 ≈${ms}ms，串行则 ${ms * 4}ms）\n")
        report.append("批2 4 个同 path 写：实测 ${batch2Ms}ms（理论串行 ≈${ms * 4}ms）\n")
        report.append("实测总耗时=${totalMs}ms（理论 ≈${ms + ms * 4}ms；若全串行则 ${ms * 8}ms）\n")
        report.append("parallelBatches=${summary.parallelBatches} maxParallelism=${summary.maxParallelism} parallelSavedMs=${summary.parallelSavedMs}\n")
        report.append("reply=${summary.reply}\n")
        let reportStr = report.toString()
        println(reportStr)
        writeTextFile("/tmp/cjh_dag_bench_report.txt", reportStr)

        // 断言：并发生效（远快于全串行 2400ms）且串行对照组未被错误并行
        @Assert(summary.reply.contains("BENCH-DONE"), true)
        @Assert(summary.maxParallelism, 4)
        @Assert(batch1Ms < ms * 4, true)              // 批1 必须并发（< 1200ms）
        @Assert(batch2Ms >= ms * 4 - 50, true)        // 批2 必须串行（≈ 1200ms，允许小误差）
        @Assert(totalMs < ms * 8, true)
    }
}
