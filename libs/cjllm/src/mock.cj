package cjllm

import std.collection.*
import std.time.*
import std.convert.Parsable
import stdx.encoding.json.*

/**
 * Mock LLM Provider：用于离线验证 agent 工具调用链（无 API Key 环境）
 *
 * 行为序列（按调用次数）：
 * 1. 第一次：返回工具调用 read_file → 验证工具执行
 * 2. 第二次：返回工具调用 bash → 验证命令执行
 * 3. 之后：返回最终文本答复
 */
/** 长思考垫片单块（多字节中文 + 换行：同时覆盖折行与中间截断路径） */
const MOCK_PAD_CHUNK: String = "长思考占位内容，用于复现展开态每帧重折整轮的性能路径。\n- 检查碰撞检测与渲染顺序\n"

/** 垫片目标 Rune 数上限（与 ThinkingLog 的 MAX_TOTAL_CHARS 同量级，防误配炸内存） */
const MOCK_MAX_REASONING_RUNES: Int64 = 262144

public class MockProvider <: LlmProvider {
    private var callCount: Int64 = 0
    public let scriptedPath: String

    public init(scriptedPath: String) {
        this.scriptedPath = scriptedPath
    }

    public func chatStream(messages: ArrayList<ChatMessage>, tools: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, onReasoning: (String) -> Unit,
        onTokenEstimate: (Int64) -> Unit, isCancelled: () -> Bool): ModelResponse {
        // 模拟推理模型的思考流（reasoning_content 增量，分帧回调）
        // 用途：TUI 思考块（pi 风格折叠/展开）验证与离线演示
        let frames = mockBaseReasoning()
        for (frame in frames) {
            onReasoning(frame)
        }
        // opt-in 长思考垫片（additive，默认关）：把思考流垫到指定 Rune 数，用于复现
        // "长思考 + 展开态每帧重折整轮"的性能路径，以及单轮上限的中间截断/摊薄逻辑
        // （见 docs/开发文档与踩坑记录.md §3.34）：
        //   CJH_MOCK_REASONING_CHARS=8192 → 垫到 ≥8192 Rune（超过单轮上限即触发截断）
        //   CJH_MOCK_REASONING_DELAY_MS=8 → 每块之间延迟，让"进行中"的长轮持续若干帧
        //                                   （否则各帧瞬时到达，渲染会被 5ms 主循环合并）
        let targetRunes = mockEnvInt("CJH_MOCK_REASONING_CHARS", MOCK_MAX_REASONING_RUNES)
        if (targetRunes > 0) {
            var baseRunes: Int64 = 0
            for (frame in frames) {
                baseRunes += frame.toRuneArray().size
            }
            let padDelayMs = mockEnvInt("CJH_MOCK_REASONING_DELAY_MS", 1000)
            for (chunk in reasoningPadChunks(baseRunes, targetRunes)) {
                onReasoning(chunk)
                if (padDelayMs > 0) {
                    sleep(Duration.millisecond * padDelayMs)
                }
            }
        }
        onTokenEstimate(50)
        // 可配置延迟（CJH_MOCK_DELAY_MS>0）：模拟慢 agent，验证 Ctrl+C 中断等交互
        try {
            let delayStr = mockGetenv("CJH_MOCK_DELAY_MS") ?? ""
            if (delayStr.size > 0) {
                let delay = Int64.parse(delayStr)
                if (delay > 0) {
                    sleep(Duration.millisecond * delay)
                }
            }
        } catch (e: Exception) {
            // 非法延迟配置：忽略
        }
        this.callCount += 1
        // 环境变量门控（additive，默认关闭）：CJH_MOCK_BASH=1 时第 2 轮改发
        // bash 工具调用，让 mock 会话真正 spawn 一个持久 BashSession 子进程——
        // 供退出路径回归（/tmp/cjh_exit_repro.py）验证退出时该会话被回收、
        // 无泄漏 bash/僵尸。默认 4 步链不变（read_file+grep/grep/list_dir/答复），
        // 不影响 runMockVerify 的"恰好 4 次调用"断言（它不设置该变量）。
        let bashStepEnabled: Bool = (mockGetenv("CJH_MOCK_BASH") ?? "").size > 0
        match (this.callCount) {
            case 1 =>
                // 工具调用 1：并发 2 个 read-only 工具（V2d 并发执行引擎验证）
                var args1 = JsonObject()
                args1.put("path", JsonString(this.scriptedPath))
                var args1b = JsonObject()
                args1b.put("pattern", JsonString("line"))
                args1b.put("path", JsonString(this.scriptedPath))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_1a", "read_file", args1))
                calls.add(ToolCall("call_1b", "grep", args1b))
                return ModelResponse("我来先看看文件内容。", calls)
            case 2 =>
                if (bashStepEnabled) {
                    // 退出路径回归：发 bash，真正 spawn 持久 BashSession 子进程
                    var argsB = JsonObject()
                    argsB.put("command", JsonString("echo cjh-mock-bash-marker"))
                    var callsB = ArrayList<ToolCall>()
                    callsB.add(ToolCall("call_2", "bash", argsB))
                    return ModelResponse("再用 bash 执行一下。", callsB)
                }
                // 工具调用 2：grep 搜索
                var args2 = JsonObject()
                args2.put("pattern", JsonString("line"))
                args2.put("path", JsonString(this.scriptedPath))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_2", "grep", args2))
                return ModelResponse("再用 grep 搜索。", calls)
            case 3 =>
                // 工具调用 3：列出目录
                var args3 = JsonObject()
                args3.put("path", JsonString("/tmp"))
                var calls = ArrayList<ToolCall>()
                calls.add(ToolCall("call_3", "list_dir", args3))
                return ModelResponse("再看看目录。", calls)
            case _ =>
                // 最终答复：分帧回调模拟流式
                let finalText = "FINAL-DONE: 验证完成，工具链正常"
                // 整体回调（避免逐字节/码点重建的 mojibake 风险）
                onDelta(finalText)
                onTokenEstimate(100)  // mock 估算值
                return ModelResponse(finalText, ArrayList<ToolCall>())
        }
    }
}

// mock 环境变量读取（零依赖 getenv）
@C
foreign func getenv(name: CString): CPointer<UInt8>

private func mockGetenv(name: String): Option<String> {
    unsafe {
        let p = getenv(LibC.mallocCString(name))
        if (p.isNull()) {
            return None
        }
        return Some(CString(p).toString())
    }
}

/** mock 的基础思考流分帧（单帧内不切分多字节字符，避免 mojibake） */
private func mockBaseReasoning(): ArrayList<String> {
    let frames = ArrayList<String>()
    frames.add("分析用户任务，确")
    frames.add("定执行计划。先读取文件确认结构，再定位目标内容，最后验证修改。")
    frames.add("\n步骤一：梳理需求清单\n- **自动射击**或点击射击\n- 粒子爆炸效果\n步骤二：检查 `src/game.js` 第 42 行碰撞检测\n- 读取 /tmp/shooter.html 结构\n- `maxTokens=16384` 配置\n- 修复 bug_2024 与 gameOver 状态\n步骤三：实现顺序\n先引擎后玩法，测试驱动。")
    return frames
}

/**
 * 计算"把思考流垫到 targetRunes"所需的追加帧（纯函数，便于单测）。
 * - targetRunes <= baseRunes → 空列表（基础流原样不动）
 * - 否则整块重复 MOCK_PAD_CHUNK 直到 baseRunes + 累计 >= targetRunes（允许最后一块超出：
 *   单轮上限的中间截断会兜住，调用方只需"足量"，无需在 Rune 边界上做精确切分）
 */
public func reasoningPadChunks(baseRunes: Int64, targetRunes: Int64): ArrayList<String> {
    let chunks = ArrayList<String>()
    if (targetRunes <= baseRunes) {
        return chunks
    }
    let chunkRunes = MOCK_PAD_CHUNK.toRuneArray().size
    var total = baseRunes
    while (total < targetRunes) {
        chunks.add(MOCK_PAD_CHUNK)
        total += chunkRunes
    }
    return chunks
}

/**
 * 读取整型环境变量（容错：去空白与引号——cmd 的 `set X="8"` 会把引号带进值里）。
 * 缺失/非法/非正 → 0（保持"默认关"语义）；上限 maxValue 防误配炸内存。
 */
private func mockEnvInt(name: String, maxValue: Int64): Int64 {
    let raw = (mockGetenv(name) ?? "").replace("\"", "").replace("'", "")
        .replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
    if (raw.size == 0) {
        return 0
    }
    try {
        let v = Int64.parse(raw)
        if (v <= 0) {
            return 0
        }
        return if (v > maxValue) { maxValue } else { v }
    } catch (e: Exception) {
        return 0
    }
}
