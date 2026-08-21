package cjh

import std.collection.*
import std.env.*
import std.fs.*
import cjh.llm.*
import cjh.agent.*
import cjh.tools.*
import cjh.model.*
import cjh.tui.*

@C
foreign func getenv(name: CString): CPointer<UInt8>

/**
 * 读取环境变量（FFI getenv，返回空指针表示未设置）
 */
func readEnv(name: String): Option<String> {
    unsafe {
        let p = getenv(LibC.mallocCString(name))
        if (p.isNull()) {
            return None
        }
        let cs = CString(p)
        return Some(cs.toString())
    }
}


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
            preview = preview[0..60] + "…"
        }
        println("  ↳ ${name} 结果: ${preview}")
    }

    println("=== cjh agent 工具调用链验证 ===")
    let answer = agent.run("请读取 /tmp/cjh_verify.txt 并统计行数")
    println("=== 最终答复 ===")
    println(answer)

    if (VerifyState.toolCalls == 2 && answer.contains("验证完成")) {
        println("\n✅ 验证通过：工具调用链完整（read_file → bash → 最终答复）")
        return 0
    } else {
        println("\n❌ 验证失败：工具调用=${VerifyState.toolCalls}（期望 2）")
        return 1
    }
}

/**
 * 从标准输入读取一行（基于 getStdIn 流）
 */
func readLineFromStdIn(): Option<String> {
    try {
        let stdin = getStdIn()
        var buf = Array<Byte>(1024, repeat: 0)
        let n = stdin.read(buf)
        if (n <= 0) {
            return None
        }
        var line = String.fromUtf8(buf[0..n])
        // 去尾部换行
        while (line.size > 0 && (line[line.size - 1] == 10u8 || line[line.size - 1] == 13u8)) {
            line = line[0..line.size - 1]
        }
        return Some(line)
    } catch (e: Exception) {
        return None
    }
}

/**
 * 配置解析：从环境变量读取 LLM 配置
 */
public class CliConfig {
    public static func provider(): LlmProvider {
        // 兼容常见环境变量：OPENAI_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY
        let apiKey = readEnv("OPENAI_API_KEY") ?? readEnv("DEEPSEEK_API_KEY") ??
            readEnv("DASHSCOPE_API_KEY") ?? readEnv("CJH_API_KEY") ?? ""
        if (apiKey.size == 0) {
            throw LlmException("未设置 API Key。请设置 OPENAI_API_KEY / DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY 之一")
        }
        let baseUrl = readEnv("CJH_BASE_URL") ?? readEnv("OPENAI_BASE_URL") ?? "https://api.openai.com/v1/chat/completions"
        let model = readEnv("CJH_MODEL") ?? readEnv("OPENAI_MODEL") ?? "gpt-4o-mini"
        return OpenAiProvider(baseUrl, apiKey, model)
    }
}

main(args: Array<String>): Int64 {
    if (args.size > 0 && args[0] == "--mock") {
        return runMockVerify()
    }
    if (args.size > 0 && args[0] == "--cli") {
        return runCli()
    }
    return runTui()
}

/**
 * 纯文本 CLI 模式（无 TUI）
 */
func runCli(): Int64 {
    println("cjh — 仓颉 Coding Agent")
    println("========================")

    // 注册工具
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())

    // Agent 装配
    let config = AgentConfig(
        "你是一个运行在终端里的编码代理（cjh）。你可以使用工具完成任务：bash 执行命令、read_file 读文件、write_file 写文件。" +
            "任务通常需要多步：先读代码理解现状，再修改，再用 bash 验证。保持简洁，用中文回答。",
        10)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = CliConfig.provider()
        }
        let agent = Agent(provider, registry, config)

        // 事件 → 终端输出
        agent.onDelta = { d => () }  // 流式增量暂不输出（避免刷屏）
        agent.onToolStart = { name, args =>
            println("")
            println("▶ 调用工具: ${name} ${args.toJsonString()}")
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            if (preview.size > 800) {
                preview = preview[0..800] + "\n…（截断）"
            }
            println("  ↳ ${name} → ${preview}")
            println("")
        }
        agent.onAssistantText = { text =>
            println("── 最终答复 ──")
            println(text)
        }

        // 交互循环
        while (true) {
            print("\ncjh> ")
            let line = readLineFromStdIn()
            if (line.isNone()) {
                break
            }
            let input = line.getOrThrow()
            if (input == "exit" || input == "quit" || input == ":q") {
                break
            }
            if (input.size == 0) {
                continue
            }
            try {
                let answer = agent.run(input)
                if (answer.size > 0) {
                    println("")
                    println(answer)
                }
            } catch (e: Exception) {
                println("错误: ${e}")
            }
        }
        println("再见")
        return 0
    } catch (e: Exception) {
        eprintln("启动失败: ${e}")
        return 1
    }
}

/**
 * TUI 交互模式（默认）
 */
func runTui(): Int64 {
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())

    let config = AgentConfig(
        "你是一个运行在终端里的编码代理（cjh）。你可以使用工具完成任务：bash 执行命令、read_file 读文件、write_file 写文件。" +
            "任务通常需要多步：先读代码理解现状，再修改，再用 bash 验证。保持简洁，用中文回答。",
        10)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = CliConfig.provider()
        }
        let agent = Agent(provider, registry, config)

        // 线程安全的输出队列（agent 在调用线程运行，输出经队列到 TUI）
        let tui = TuiApp()

        agent.onDelta = { d => () }
        agent.onToolStart = { name, args =>
            tui.appendOutput(Ansi.fg(Ansi.COLOR_YELLOW) + "▶ 工具: ${name} ${args.toJsonString()}" + Ansi.reset())
        }
        agent.onToolResult = { name, result =>
            var preview = result.content
            if (preview.size > 200) {
                preview = preview[0..200] + "…"
            }
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GRAY) + "  ↳ ${name}: ${preview}" + Ansi.reset())
        }
        agent.onAssistantText = { text =>
            tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + text + Ansi.reset())
        }

        tui.onSubmit = { input =>
            try {
                let answer = agent.run(input)
                if (answer.size > 0) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + answer + Ansi.reset())
                }
            } catch (e: Exception) {
                tui.appendOutput(Ansi.fg(Ansi.COLOR_RED) + "错误: ${e}" + Ansi.reset())
            }
        }

        tui.run()
        return 0
    } catch (e: Exception) {
        eprintln("启动失败: ${e}")
        return 1
    }
}
