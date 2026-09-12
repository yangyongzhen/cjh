package cjh.tests

import std.collection.*
import cjterm.*

/**
 * 思考交织（锚点交织）单测：每轮思考钉在消息流中自己的位置（本轮回复之前），
 * 多轮不再全堆会话末尾；进行中轮次仍贴底流式可见；折叠态贴底一行摘要。
 *
 * 旧契约"思考固定在回复下方"是流式可见性的妥协，已由思考历史可滚动回看解除，
 * 故此处锁定新契约：先看到"想了什么"，再看到对应的回复（pi transcript 阅读顺序）。
 */

/** 把 OutputView 渲染到测试画布并取回文本 */
private func weaveRenderText(ov: OutputView, rows: Int64, cols: Int64): String {
    let c = TuiCanvas()
    c.begin(rows, cols, true)
    ov.render(c, 0, cols, rows)
    return c.flush()
}

/** 断言各关键字在渲染文本中按给定顺序出现（即锚点交织序） */
private func weaveAssertOrder(text: String, keys: Array<String>): Unit {
    var prev: Int64 = -1
    for (k in keys) {
        let idx = text.indexOf(k)
        @Assert(idx.isSome(), true)
        @Assert(idx.getOrThrow() > prev, true)
        prev = idx.getOrThrow()
    }
}

@Test
public func testWeaveRoundThinkingBeforeItsOwnReply(): Unit {
    let ov = OutputView()
    ov.append("❯ 用户问题")
    ov.append("")
    ov.appendThinking("第一轮推理内容")
    ov.finishThinking()
    ov.append("第一轮回复正文")
    ov.toggleThinking()
    let text = weaveRenderText(ov, 40, 60)
    weaveAssertOrder(text, ["❯ 用户问题", "第一轮推理内容", "第一轮回复正文"])
}

@Test
public func testWeaveMultiRoundInterleavedWithOwnReplies(): Unit {
    let ov = OutputView()
    ov.append("❯ 任务")
    ov.append("")
    ov.appendThinking("第一轮思考")
    ov.finishThinking()
    ov.append("第一轮回复")
    ov.appendThinking("第二轮思考")
    ov.finishThinking()
    ov.append("第二轮回复")
    ov.appendThinking("第三轮思考")
    ov.toggleThinking()
    let text = weaveRenderText(ov, 44, 60)
    weaveAssertOrder(text, ["❯ 任务", "第一轮思考", "第一轮回复", "第二轮思考", "第二轮回复", "第三轮思考"])
}

@Test
public func testWeaveActiveRoundThinkingStreamsAtTail(): Unit {
    let ov = OutputView()
    ov.appendThinking("第一轮思考")
    ov.finishThinking()
    for (i in 0..12) {
        ov.append("回复行" + i.toString())
    }
    ov.appendThinking("进行中思考")
    ov.toggleThinking()
    let text = weaveRenderText(ov, 6, 40)
    // 进行中轮次贴底可见；早期轮次思考已随消息流滚出可视区
    @Assert(text.indexOf("进行中思考").isSome(), true)
    @Assert(text.indexOf("第一轮思考").isNone(), true)
}

@Test
public func testWeaveCollapsedSummaryKeepsThinkingBodyHidden(): Unit {
    let ov = OutputView()
    ov.append("❯ 任务")
    ov.appendThinking("机密推理内容")
    ov.finishThinking()
    let text = weaveRenderText(ov, 20, 60)
    @Assert(text.indexOf("机密推理内容").isNone(), true)
    @Assert(text.contains("思考"), true)
}

@Test
public func testWeaveScrollBackReachesWovenThinking(): Unit {
    let ov = OutputView()
    ov.append("❯ 任务")
    ov.append("")
    ov.appendThinking("早期推理锚点内容")
    ov.finishThinking()
    for (i in 0..20) {
        ov.append("输出行" + i.toString())
    }
    ov.toggleThinking()
    let bottom = weaveRenderText(ov, 8, 60)
    @Assert(bottom.indexOf("早期推理锚点内容").isNone(), true)
    // 向上滚动回看：交织进消息流的早期思考应重新出现在窗口内
    ov.scrollUp(30)
    let scrolled = weaveRenderText(ov, 8, 60)
    @Assert(scrolled.indexOf("早期推理锚点内容").isSome(), true)
}

@Test
public func testWeaveOrderStableAcrossWidthChange(): Unit {
    let ov = OutputView()
    ov.append("❯ 任务")
    ov.append("")
    ov.appendThinking("第一轮思考")
    ov.finishThinking()
    ov.append("第一轮回复")
    ov.appendThinking("第二轮思考")
    ov.finishThinking()
    ov.append("第二轮回复")
    ov.toggleThinking()
    let wide = weaveRenderText(ov, 44, 60)
    weaveAssertOrder(wide, ["❯ 任务", "第一轮思考", "第一轮回复", "第二轮思考", "第二轮回复"])
    // 宽度变化触发冻结缓存重建 + 锚点重排，交织序必须保持
    let narrow = weaveRenderText(ov, 44, 30)
    weaveAssertOrder(narrow, ["❯ 任务", "第一轮思考", "第一轮回复", "第二轮思考", "第二轮回复"])
}
