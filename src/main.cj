package cjh

import std.collection.*
import std.env.*
import std.fs.*
import cjh.llm.*
import cjh.agent.*
import cjh.tools.*
import cjh.model.*
import cjh.tui.*
import cjterm.*
import cjh.config.*

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

main(args: Array<String>): Int64 {
    if (args.size > 0 && args[0] == "--mock") {
        return runMockVerify()
    }
    if (args.size > 0 && args[0] == "--cli") {
        return runCli()
    }
    if (args.size > 1 && args[0] == "--resume") {
        return runTui(args[1])
    }
    if (args.size > 0 && args[0] == "--list") {
        return listSessions()
    }
    return runTui("")
}

class CliSession {
    static var id: String = ""
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

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()

    let config = AgentConfig(
        cjhCfg.systemPrompt,
        cjhCfg.maxIterations)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = cjhCfg.provider()
        }
        let agent = Agent(provider, registry, config)
        let store = SessionStore(cjhCfg.sessionsDir)
        CliSession.id = ""

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
                // 保存会话
                if (CliSession.id.size == 0) {
                    CliSession.id = store.save(agent.history())
                    eprintln("[会话已保存: ${CliSession.id}，--resume ${CliSession.id} 恢复]")
                } else {
                    let _ = store.save(agent.history())
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
func runTui(sessionId: String): Int64 {
    let registry = ToolRegistry()
    registry.register(BashTool())
    registry.register(ReadTool())
    registry.register(WriteTool())

    // 配置加载
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()

    let config = AgentConfig(
        cjhCfg.systemPrompt,
        cjhCfg.maxIterations)

    try {
        let provider: LlmProvider
        if ((readEnv("CJH_MOCK") ?? "") == "1") {
            provider = MockProvider("/tmp/cjh_verify.txt")
        } else {
            provider = cjhCfg.provider()
        }
        let agent = Agent(provider, registry, config)

        // 线程安全的输出队列（agent 在调用线程运行，输出经队列到 TUI）
        let tui = TuiApp()

        // 会话：恢复历史 / 新会话
        let store = SessionStore(cjhCfg.sessionsDir)
        var curSessionId = sessionId
        if (curSessionId.size > 0) {
            let history = store.load(curSessionId)
            if (history.size > 0) {
                agent.loadHistory(history)
                tui.appendOutput(Ansi.fg(Ansi.COLOR_BLUE) + "已恢复会话 ${curSessionId}（${history.size} 条消息）" + Ansi.reset())
            } else {
                tui.appendOutput(Ansi.fg(Ansi.COLOR_YELLOW) + "会话 ${curSessionId} 不存在，开始新会话" + Ansi.reset())
                curSessionId = ""
            }
        }

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

        SessionState.current = curSessionId
        tui.onSubmit = { input =>
            try {
                let answer = agent.run(input)
                if (answer.size > 0) {
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_GREEN) + answer + Ansi.reset())
                }
                // 保存会话（含首轮时创建 ID）
                if (SessionState.current.size == 0) {
                    SessionState.current = store.save(agent.history())
                    tui.appendOutput(Ansi.fg(Ansi.COLOR_DARK) + "会话已保存: ${SessionState.current}（--resume ${SessionState.current} 可恢复）" + Ansi.reset())
                } else {
                    let _ = store.save(agent.history())
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

class SessionState {
    static var current: String = ""
}

/**
 * 列出已保存的会话
 */
func listSessions(): Int64 {
    let cjhCfg = CjhConfig()
    cjhCfg.ensureDirs()
    let store = SessionStore(cjhCfg.sessionsDir)
    let sessions = store.list()
    if (sessions.size == 0) {
        println("暂无会话。运行 cjh 开始新会话，退出后自动保存。")
        return 0
    }
    println("已保存的会话（${sessions.size} 个）：")
    println("--------------------------------")
    for ((id, summary) in sessions) {
        println("  ${id}  |  ${summary}")
    }
    println("--------------------------------")
    println("恢复: cjh --resume <会话ID>")
    return 0
}
