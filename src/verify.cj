package cjh

/**
 * --mock 离线验证模式
 *
 * 从 main.cj 抽出，降低单文件体积。所有符号在 package cjh 内跨文件可见。
 */

import std.fs.*
import cjllm.*
import cjh.agent.*
import cjh.tools.*
import cjcfg.*
import cjutil.*

class VerifyState {
    static var toolCalls: Int64 = 0
}

/**
 * --mock 模式：离线验证 agent 工具调用链（无 API Key 环境）
 */
func runMockVerify(): Int64 {
    let testPath = "/tmp/cjh_verify.txt"
    File.writeTo(testPath, "line1\nline2\nline3\n".toArray())

    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())
    registry.register(AppendFileTool())
    registry.register(GrepTool())
    registry.register(ListDirTool())
    registry.register(HashlineEditTool())
    // 注册 web_search + web_fetch（mock 模式也需验证工具出现在 LLM 工具列表）
    registerWebTools(CjhConfig(), registry)

    let provider = MockProvider(testPath)
    let config = AgentConfig("你是测试代理。", 5)
    let agent = Agent(provider, registry, config)

    VerifyState.toolCalls = 0
    agent.onToolStart = { name, args =>
        VerifyState.toolCalls += 1
        println("  ▶ 工具调用 #${VerifyState.toolCalls}: ${name} ${args.toJsonString()}")
    }
    agent.onToolResult = { name, result =>
        var preview = result.content
        if (preview.size > 60) {
            preview = truncateUtf8(preview, 60) + "…"
        }
        println("  ↳ ${name} 结果: ${preview}")
    }

    println("=== cjh agent 工具调用链验证（4 段）===")
    let summary = agent.run("请读取 /tmp/cjh_verify.txt 并统计行数")
    println("=== 最终答复 ===")
    println(summary.reply)

    if (VerifyState.toolCalls == 4 && summary.reply.contains("验证完成")) {
        // mock 第 1 轮返回 read_file+grep 两个并行调用，全链 = 2+1+1 = 4 次
        println("\n✅ 验证通过：工具调用链完整（read_file+grep 并行 → grep → list_dir → 最终答复）")
        return 0
    } else {
        println("\n❌ 验证失败：工具调用=${VerifyState.toolCalls}（期望 4）")
        return 1
    }
}
