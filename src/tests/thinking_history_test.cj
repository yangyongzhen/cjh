package cjh.tests

import std.collection.*
import cjterm.*

/**
 * 思考历史（多轮）渲染与回看测试。
 *
 * 用户反馈"思考内容无法滚动查看历史"。根因两处（实现见
 * libs/cjterm/src/thinking_log.cj 与 OutputView 的思考块渲染）：
 * 1. 新一轮思考开始时上一轮被清空（历史根本不存在）；
 * 2. 超限只留尾部（开头被丢弃）。
 *
 * 本用例锁死修复后的 observable 契约：
 * - 折叠态：单轮沿用原文案；多轮显示轮数
 * - 展开态：逐轮 "💭 思考 #n" 标题 + "› " 内容行，多轮全部可见
 * - 回看：思考块计入输出区滚动范围，scrollUp 后能看到更早轮次（复用既有 PageUp 语义，未加新键位）
 */

/** 渲染到 canvas 取可见行（照 tui_test / outputview_linecache_test 模式） */
private func renderThink(ov: OutputView, rows: Int64, cols: Int64): String {
    let c = TuiCanvas()
    c.begin(rows, cols, true)
    ov.render(c, 0, cols, rows)
    return c.flush()
}

@Test
public class ThinkingHistoryTest {

    /** 单轮：折叠/展开文案与既有契约一致（回归保护） */
    @TestCase
    public func testSingleRoundTextUnchanged(): Unit {
        let ov = OutputView()
        ov.append("回复文本")
        ov.setThinking("一轮思考", true)
        let folded = renderThink(ov, 12, 40)
        @Assert(folded.contains("思考过程 · Ctrl+T 查看"), true)
        ov.toggleThinking()
        let expanded = renderThink(ov, 12, 40)
        @Assert(expanded.contains("思考过程 · Ctrl+T 折叠"), true)
        @Assert(expanded.contains("一轮思考"), true)
    }

    /** 多轮：折叠态显示轮数（历史不再被清空） */
    @TestCase
    public func testMultiRoundCollapsedShowsRounds(): Unit {
        let ov = OutputView()
        ov.append("回复文本")
        ov.appendThinking("第一轮思考内容")
        ov.finishThinking()
        ov.appendThinking("第二轮思考内容")
        ov.finishThinking()
        @Assert(ov.thinkingRounds(), 2)
        @Assert(ov.thinkingActive(), false)
        let folded = renderThink(ov, 12, 60)
        @Assert(folded.contains("思考过程（2 轮）"), true)
    }

    /** 多轮展开：逐轮标题 + 内容行全部可见 */
    @TestCase
    public func testMultiRoundExpandedShowsAllRounds(): Unit {
        let ov = OutputView()
        ov.append("回复文本")
        ov.appendThinking("第一轮思考内容")
        ov.finishThinking()
        ov.appendThinking("第二轮思考内容")
        ov.finishThinking()
        ov.toggleThinking()
        let expanded = renderThink(ov, 20, 60)
        @Assert(expanded.contains("思考 #1"), true)
        @Assert(expanded.contains("思考 #2"), true)
        @Assert(expanded.contains("第一轮思考内容"), true)
        @Assert(expanded.contains("第二轮思考内容"), true)
    }

    /** 回看历史：早期轮次滚出窗口后，scrollUp 仍能看到（核心诉求） */
    @TestCase
    public func testScrollBackRevealsEarlierRounds(): Unit {
        let ov = OutputView()
        // 只留 2 行前置消息：滚到最顶时（窗口 = 前 8 行）第一轮开头仍在窗口内，
        // 断言不依赖精确行号计算
        for (i in 0..2) {
            ov.append("历史消息-" + i.toString())
        }
        // 第一轮做长（21 行），使开头远在底部窗口之外
        let long = StringBuilder()
        long.append("早轮标记：第一轮开头")
        for (i in 0..20) {
            long.append("\n第一轮第" + i.toString() + "行")
        }
        ov.appendThinking(long.toString())
        ov.finishThinking()
        ov.appendThinking("晚轮标记：第二轮")
        ov.finishThinking()
        ov.toggleThinking()
        let bottom = renderThink(ov, 8, 60)
        @Assert(bottom.contains("晚轮标记：第二轮"), true)
        @Assert(!bottom.contains("早轮标记：第一轮开头"), true)   // 早期内容在窗口之外
        ov.scrollUp(100)                                        // 滚到顶部（越界自动收敛）
        let scrolled = renderThink(ov, 8, 60)
        @Assert(scrolled.contains("早轮标记：第一轮开头"), true) // 回看得到历史思考
        @Assert(!scrolled.contains("晚轮标记：第二轮"), true)    // 晚轮已被滚出窗口
    }

    /** 展开态缓存：轮数变化后重排，不残留旧文案（同一宽度下头部编号一致） */
    @TestCase
    public func testFrozenCacheRebuildsOnRoundCountChange(): Unit {
        let ov = OutputView()
        ov.appendThinking("第一轮")
        ov.finishThinking()
        ov.toggleThinking()
        // 先按单轮渲染一次（缓存铺满"单轮文案"）
        let single = renderThink(ov, 12, 60)
        @Assert(single.contains("思考过程 · Ctrl+T 折叠"), true)
        // 出现第二轮：缓存应整体重建，第一轮标题换成带编号的多轮文案
        ov.appendThinking("第二轮")
        ov.finishThinking()
        let multi = renderThink(ov, 12, 60)
        @Assert(multi.contains("思考 #1"), true)
        @Assert(multi.contains("思考 #2"), true)
        @Assert(!multi.contains("思考过程 · Ctrl+T 折叠"), true)
    }
}
