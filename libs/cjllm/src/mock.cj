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
        onReasoning("分析用户任务，确")
        onReasoning("定执行计划。先读取文件确认结构，再定位目标内容，最后验证修改。")
        onReasoning("\n步骤一：梳理需求清单\n- 自动射击或点击射击\n- 敌机多种类型、波次\n- 粒子爆炸效果、星空背景\n- 分数、生命、难度递增\n- 开始界面、暂停、游戏结束界面\n- 移动端触摸支持\n- 音效与背景音乐\n- 双人模式与排行榜\n步骤二：模块划分\n- 渲染引擎\n- 碰撞检测\n- 状态机\n- 输入系统\n- 存档系统\n步骤三：实现顺序\n先引擎后玩法，测试驱动。")
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
