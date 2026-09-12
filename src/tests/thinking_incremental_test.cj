package cjh.tests

import std.collection.*
import cjterm.*

/**
 * 展开态"活跃轮"折行的增量等价性测试（第四十三轮 #2）。
 *
 * 背景：展开态每帧都要折"进行中"的那一轮，旧实现整轮重折（实测平均 4.5ms、峰值 17.3ms/帧，
 * 每帧折出最多 475 行而内容区仅约 30 行）。改法是把已完成行缓存复用、只增量折未完成行 + 新片段。
 *
 * 本文件锁两条不变式：
 * 1. **等价**：分片喂入（每片渲染一次）与一次性喂入，渲染结果逐行一致——覆盖多字节、
 *    显式换行、显示宽度折行、渲染宽度变化（重置）、超单轮上限截断后重折；
 * 2. **增量**：追加一小段后，活跃轮折行只重渲染"未完成行 + 本帧新完成行"，
 *    由 `OutputView.foldLineWork`（本次折行真正渲染的行数）断言，防止退化回整轮重折。
 */
private func renderThinking(ov: OutputView, rows: Int64, cols: Int64): String {
    let c = TuiCanvas()
    c.begin(rows, cols, true)
    ov.render(c, 0, cols, rows)
    return c.flush()
}

/** 造一段多行思考文本：每行都足够宽以触发显示宽度折行计算 */
private func paddedChunk(tag: String): String {
    let sb = StringBuilder()
    sb.append(tag + "：中文内容需要占据一定显示宽度，这一段用于折行。\n")
    return sb.toString()
}

/** 抽取"思考内容行"（按内容行专属样式 fg249 + 斜体选行）：绕开轮次头部措辞差异，只比对折出来的内容 */
private func contentSignature(rendered: String): String {
    let sb = StringBuilder()
    // 画布 flush 用 ANSI 光标定位 + clearLine 逐行输出，行间没有换行符，故按 clearLine 切行
    for (row in rendered.split(Ansi.esc() + "[2K", -1)) {
        if (row.contains(Ansi.fg(249) + Ansi.italic())) {
            sb.append(row + "\n")
        }
    }
    return sb.toString()
}

@Test
public class ThinkingIncrementalTest {

    /**
     * 增量不变式：向已成型的长轮追加一小段，本帧只应重渲染未完成行 + 新完成行。
     * 旧实现（整轮重折）下 foldLineWork ≈ 轮内行数 → 本用例先红后绿。
     */
    @TestCase
    public func testAppendOnlyRendersTailOfActiveRound(): Unit {
        let ov = OutputView()
        ov.thinkingExpanded = true
        ov.setThinking(paddedChunk("起始"), false)
        @Assert(renderThinking(ov, 30, 60).size > 0, true)
        for (i in 1..16) {
            ov.appendThinking(paddedChunk("思考行" + i.toString()))
        }
        @Assert(renderThinking(ov, 30, 60).size > 0, true)
        let baseline = ov.foldLineWork
        // 整轮重折时该值随轮长增长（16 段 → 至少 15 行）
        @Assert(baseline >= 15, true)
        // 追加一小段后渲染：增量实现只重渲染未完成行（+ 本帧新完成行）
        ov.appendThinking("再补两个字")
        @Assert(renderThinking(ov, 30, 60).size > 0, true)
        @Assert(ov.foldLineWork <= 3, true)
    }

    /** 等价不变式：分片喂入渲染 == 一次性喂入渲染（含渲染宽度变化后的重置） */
    @TestCase
    public func testChunkedRenderMatchesSingleShot(): Unit {
        let chunks = ArrayList<String>()
        chunks.add(paddedChunk("第一段"))
        chunks.add(paddedChunk("第二段带 `代码` 与 *强调* 标记"))
        chunks.add("第三段没有换行，会与后面的内容连成一行并在宽度处折开")
        chunks.add("，这里继续追加中文内容，直到超过一行的显示宽度。")
        chunks.add(paddedChunk("第四段"))
        chunks.add("短句")
        let whole = StringBuilder()
        for (c in chunks) {
            whole.append(c)
        }

        let oneShot = OutputView()
        oneShot.thinkingExpanded = true
        oneShot.setThinking(whole.toString(), false)

        let chunked = OutputView()
        chunked.thinkingExpanded = true
        chunked.setThinking(chunks[0], false)
        @Assert(renderThinking(chunked, 30, 60).size > 0, true)
        for (i in 1..chunks.size) {
            chunked.appendThinking(chunks[i])
            @Assert(renderThinking(chunked, 30, 60).size > 0, true)
        }

        @Assert(renderThinking(oneShot, 30, 60) == renderThinking(chunked, 30, 60), true)
        // 渲染宽度变化：两侧都在新宽度下重排，结果仍须一致
        @Assert(renderThinking(oneShot, 30, 40) == renderThinking(chunked, 30, 40), true)
        @Assert(renderThinking(oneShot, 30, 100) == renderThinking(chunked, 30, 100), true)
    }

    /**
     * 截断（超单轮上限 → 头 + 省略标记 + 尾）后的等价：分片喂入跨越多次截断，
     * 渲染结果仍须与一次性喂入一致。
     */
    @TestCase
    public func testTruncatedRoundChunkedMatchesSingleShot(): Unit {
        let chunks = ArrayList<String>()
        for (i in 0..20) {
            let sb = StringBuilder()
            sb.append("分片" + i.toString() + "：")
            for (j in 0..22) {
                sb.append("中文内容填充用于接近单轮上限，这一段文字足够长。")
            }
            sb.append("\n")
            chunks.add(sb.toString())
        }
        let whole = StringBuilder()
        for (c in chunks) {
            whole.append(c)
        }

        let oneShot = OutputView()
        oneShot.thinkingExpanded = true
        oneShot.setThinking(whole.toString(), false)

        let chunked = OutputView()
        chunked.thinkingExpanded = true
        chunked.setThinking(chunks[0], false)
        for (i in 1..chunks.size) {
            chunked.appendThinking(chunks[i])
            @Assert(renderThinking(chunked, 30, 60).size > 0, true)
        }
        @Assert(renderThinking(oneShot, 30, 60) == renderThinking(chunked, 30, 60), true)
    }

    /**
     * 交叉等价（防两份断行规则漂移）：同一轮文本，
     * "进行中（增量折行）"的内容行必须与"结束后（整轮重折 + 冻结缓存）"逐行一致。
     * 轮次头部措辞（思考中 / 思考过程）不参与比对，故只取内容行样式（fg249 斜体）的行。
     */
    @TestCase
    public func testActiveIncrementalMatchesFrozenFullFold(): Unit {
        let chunks = ArrayList<String>()
        chunks.add(paddedChunk("第一段"))
        chunks.add(paddedChunk("第二段带 `代码` 与 *强调* 标记"))
        chunks.add("第三段没有换行，会与后面的内容连成一行并在宽度处折开")
        chunks.add("，继续追加中文内容直到超过一行显示宽度为止。")
        chunks.add("短句")

        let active = OutputView()
        active.thinkingExpanded = true
        active.setThinking(chunks[0], false)
        @Assert(renderThinking(active, 30, 60).size > 0, true)
        for (i in 1..chunks.size) {
            active.appendThinking(chunks[i])
            @Assert(renderThinking(active, 30, 60).size > 0, true)
        }
        let activeOut = renderThinking(active, 30, 60)

        let whole = StringBuilder()
        for (c in chunks) {
            whole.append(c)
        }
        let frozen = OutputView()
        frozen.thinkingExpanded = true
        frozen.setThinking(whole.toString(), true)
        let frozenOut = renderThinking(frozen, 30, 60)

        let activeContent = contentSignature(activeOut)
        @Assert(activeContent.size > 0, true)   // 抽取为空会让比对假通过
        @Assert(activeContent == contentSignature(frozenOut), true)
    }

    /**
     * 头段冻结不变式（长轮跨过单轮上限后仍要流式便宜）：
     * 触发过一次中间截断后，再追加一小段（未越过上限 → 不再截断），本帧只应
     * 重渲染"未完成行 + 新完成行"——头部已冻结、尾段增量，不再从 0 折 ~1 万 rune。
     */
    @TestCase
    public func testTruncatedRoundKeepsStreamingCheap(): Unit {
        let ov = OutputView()
        ov.thinkingExpanded = true
        let sb = StringBuilder()
        sb.append("起点：")
        for (j in 0..22) {
            sb.append("中文内容填充用于接近单轮上限，这一段文字足够长。")
        }
        sb.append("\n")
        ov.setThinking(sb.toString(), false)
        @Assert(renderThinking(ov, 30, 60).size > 0, true)
        // 追加到越过单轮上限（触发中间截断 + 头部冻结）
        for (i in 1..18) {
            ov.appendThinking(sb.toString())
            @Assert(renderThinking(ov, 30, 60).size > 0, true)
        }
        // 截断后文本回落至上限附近，此时再追加一小段不会再次截断
        ov.appendThinking("尾巴几个字")
        @Assert(renderThinking(ov, 30, 60).size > 0, true)
        @Assert(ov.foldLineWork <= 3, true)
    }
}
