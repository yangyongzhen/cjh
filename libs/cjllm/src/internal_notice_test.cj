package cjllm

import std.collection.*

/**
 * 内部提效提醒（System Notice）的可见性契约：
 * - 新消息用 hiddenFromUser 标记，不落盘、不进可见历史
 * - 旧会话没有标记，按内容前缀识别
 * - 用户排队消息虽然也带 "[System Notice]" 抬头，但含真实用户指令，绝不能隐藏
 * - toOpenAiJson（发往模型 API）不得携带 internal 元数据
 */
@Test
public class InternalNoticeTest {
    @TestCase
    public func testFlaggedMessageIsInternal(): Unit {
        @Assert(ChatMessage("user", "请继续", true).isInternalNotice(), true)
        @Assert(ChatMessage("user", "请继续", false).isInternalNotice(), false)
        @Assert(ChatMessage("user", "普通用户消息").isInternalNotice(), false)
    }

    @TestCase
    public func testLegacyPrefixesAreInternal(): Unit {
        var prefixes = ArrayList<String>()
        prefixes.add("[System Notice] 你已连续 ")
        prefixes.add("[System Notice] 轮次预算已续")
        prefixes.add("[System Notice] 任务已执行 ")
        prefixes.add("[System Notice] 你还没有完成任务")
        prefixes.add("[System Notice] 你上一轮只输出了思考")
        prefixes.add("[System Notice] The previous SSE stream was cut off")
        prefixes.add("[System Notice - ABSOLUTE DIRECTIVE")
        prefixes.add("[System Notice] Your previous response was empty")
        for (p in prefixes) {
            @Assert(ChatMessage("user", p + "（正文）").isInternalNotice(), true)
        }
    }

    @TestCase
    public func testQueuedUserNoticeStaysVisible(): Unit {
        // 排队消息抬头与内部提醒相似，但原文是用户指令，隐藏会丢用户输入
        let queued = "[System Notice] 用户在你执行期间发来一条补充要求（排队消息），原文如下：\n---\n补一条单元测试\n---"
        let m = ChatMessage("user", queued)
        @Assert(m.isInternalNotice(), false)
    }

    @TestCase
    public func testSessionJsonCarriesInternalFlagOnlyWhenHidden(): Unit {
        let hidden = ChatMessage("user", "继续", true).toSessionJson().asObject()
        @Assert(hidden.get("internal").getOrThrow().asBool().getValue(), true)
        let visible = ChatMessage("user", "继续").toSessionJson().asObject()
        @Assert(visible.get("internal").isNone(), true)
    }

    @TestCase
    public func testOpenAiJsonNeverCarriesInternalField(): Unit {
        // 未知字段可能被 OpenAI/Anthropic 拒绝：API 请求体必须保持干净
        let obj = ChatMessage("user", "继续", true).toOpenAiJson().asObject()
        @Assert(obj.get("internal").isNone(), true)
    }
}
