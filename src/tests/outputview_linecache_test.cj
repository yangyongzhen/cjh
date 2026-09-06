package cjh.tests

import std.collection.*
import cjterm.*

/**
 * OutputView 增量行缓存等价性测试（P2/G4）
 *
 * 核心不变式：cachedLines() 恒等于 content().split("\n", -1)，
 * 覆盖 append / appendDelta / ensureNewline / endStream 全路径，
 * 重点锁死 split -1 的尾空串（结尾 \n）与首空串（开头 \n）边界语义。
 *
 * render 可见窗口语义不变（虚拟拼接 vs 整段 split）：
 * 与"手工 split + 窗口计算"的参考实现逐行比对。
 */

/** 参考实现：独立计算 split 行列表（不复用被测对象内部逻辑） */
private func referenceLines(s: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (l in s.split("\n", -1)) {
        out.add(l)
    }
    return out
}

/** 比较两个行列表是否逐位相等 */
private func sameLines(a: ArrayList<String>, b: ArrayList<String>): Bool {
    if (Int64(a.size) != Int64(b.size)) {
        return false
    }
    for (i in 0..Int64(a.size)) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}

/** 渲染到 canvas 取可见行（参考 tui_test renderText 模式） */
private func renderVisible(ov: OutputView, rows: Int64, cols: Int64): String {
    let c = TuiCanvas()
    c.begin(rows, cols, true)
    ov.render(c, 0, cols, rows)
    return c.flush()
}

@Test
public class OutputViewLineCacheTest {

    @TestCase
    public func testConsecutiveSingleLineAppend(): Unit {
        // 连续单行 append：缓存增量维护，与参考 split 一致
        let ov = OutputView()
        ov.append("first")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        ov.append("second")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        ov.append("中文第三行")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        // 显式断言行数与内容（append 自动补 \n → split -1 尾空串，共 4 项）
        @Assert(ov.cachedLines().size, 4)
        @Assert(ov.cachedLines()[0], "first")
        @Assert(ov.cachedLines()[2], "中文第三行")
        @Assert(ov.cachedLines()[3].size, 0)
    }

    @TestCase
    public func testAppendTrailingNewlineProducesEmptyLine(): Unit {
        // 尾空串语义：append 以 \n 结尾 → 末行空串（split -1 行为）
        let ov = OutputView()
        ov.append("line1\n")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[0], "line1")
        @Assert(ov.cachedLines()[1].size, 0)
        // 再叠加普通行：空行上拼接
        ov.append("line2")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 3)
        @Assert(ov.cachedLines()[1], "line2")
    }

    @TestCase
    public func testAppendMultiLineMiddleNewline(): Unit {
        // 含 \n 在中间的 append：末行 += 首段 + 中间段 add
        let ov = OutputView()
        ov.append("base")
        ov.append("a\nb\nc")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        // 首段拼末行("") → "a"，中间段 b/c，补 \n → 尾空串：共 5 项
        @Assert(ov.cachedLines().size, 5)
        @Assert(ov.cachedLines()[0], "base")
        @Assert(ov.cachedLines()[1], "a")
        @Assert(ov.cachedLines()[2], "b")
        @Assert(ov.cachedLines()[3], "c")
        @Assert(ov.cachedLines()[4].size, 0)
        // 空行 append：补 \n → 再一尾空串
        ov.append("")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 6)
        @Assert(ov.cachedLines()[5].size, 0)
    }

    @TestCase
    public func testAppendDeltaStreamThenEndStream(): Unit {
        // 流式：appendDelta 累积 → endStream 整体替换（截断重写路径）
        let ov = OutputView()
        ov.append("prompt line")
        ov.appendDelta("Hel")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        ov.appendDelta("lo wo")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[1], "Hello wo")
        // endStream 用最终完整文本替换流式段（模拟 markdown 收尾）
        ov.endStream("lo world!")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.content(), "prompt line\nlo world!")
        @Assert(ov.cachedLines()[1], "lo world!")
        // endStream 后无尾 \n：再 append("next") 拼到 "lo world!" 行尾（真实流中
        // 工具行前会先 ensureNewline，此处验证"无换行则同行拼接"语义）
        ov.append("next")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 3)
        @Assert(ov.cachedLines()[1], "lo world!next")
        @Assert(ov.cachedLines()[2].size, 0)
    }

    @TestCase
    public func testAppendDeltaMultiLineThenEndStream(): Unit {
        // 流式段本身含 \n：delta 内多行 + endStream 替换
        let ov = OutputView()
        ov.append("before\n")
        ov.appendDelta("para1\npara2 ")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 3)
        @Assert(ov.cachedLines()[1], "para1")
        @Assert(ov.cachedLines()[2], "para2 ")
        ov.endStream("para1\npara2 final")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.content(), "before\npara1\npara2 final")
        @Assert(ov.cachedLines().size, 3)
    }

    @TestCase
    public func testAppendDeltaEmptyText(): Unit {
        // 边界：appendDelta 空串（无变化，缓存不变）
        let ov = OutputView()
        ov.append("base")
        ov.appendDelta("")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[0], "base")
        @Assert(ov.cachedLines()[1].size, 0)
    }

    @TestCase
    public func testEnsureNewline(): Unit {
        // ensureNewline：非 \n 结尾时补 \n（产生尾空行）；已是 \n 结尾时 no-op
        let ov = OutputView()
        ov.append("no newline yet")
        ov.ensureNewline()
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[1].size, 0)
        ov.ensureNewline()  // 已以 \n 结尾：不再补
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        // 空缓冲 ensureNewline：no-op（content 为空时不追加）
        let ov2 = OutputView()
        ov2.ensureNewline()
        @Assert(sameLines(ov2.cachedLines(), referenceLines(ov2.content())), true)
        @Assert(ov2.cachedLines().size, 0)
    }

    @TestCase
    public func testEndStreamWithoutActiveStream(): Unit {
        // 无活动流式段时 endStream = 直接 append（不触发重建）
        let ov = OutputView()
        ov.append("x")
        ov.endStream("y")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[1], "y")
    }

    @TestCase
    public func testStreamStartAfterLineEnd(): Unit {
        // 前文 append 已补 \n：流式段起点在新行行首，endStream 截断重写正确性
        let ov = OutputView()
        ov.append("前缀行")
        ov.appendDelta("部分流式")
        ov.appendDelta("文本")
        ov.endStream("替换后文本")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        @Assert(ov.content(), "前缀行\n替换后文本")
        @Assert(ov.cachedLines().size, 2)
        @Assert(ov.cachedLines()[1], "替换后文本")
    }

    @TestCase
    public func testMixedSequenceLongSession(): Unit {
        // 长会话混合序列：append / appendDelta / endStream / ensureNewline 交错，
        // 每步后缓存与参考一致（模拟真实流式回合）
        let ov = OutputView()
        let ops = ["a1", "b2\n", "c3\nd4", "e5"]
        for (s in ops) {
            ov.append(s)
            @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        }
        ov.appendDelta("stream-")
        ov.appendDelta("中")
        ov.appendDelta("文\n换")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        ov.endStream("完整\n多行")
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        ov.ensureNewline()
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
        // 行数最终校验：a1/b2/c3/d4/e5/完整/多行 + 尾空串 = 8
        @Assert(ov.cachedLines().size, 8)
    }

    @TestCase
    public func testRenderWindowMatchesReference(): Unit {
        // render 可见窗口：缓存虚拟拼接 vs 参考 split 手工窗口计算，逐行一致。
        // 无思考块：可见窗口 = 末尾 height 行
        let ov = OutputView()
        let n: Int64 = 50
        for (i in 0..n) {
            ov.append("row-${i}")
        }
        let flushed = renderVisible(ov, 10, 60)
        // 参考：末尾 10 行（scrollOffset=0）
        let ref = referenceLines(ov.content())
        @Assert(sameLines(ov.cachedLines(), ref), true)
        // flush 输出含 ANSI 移动序列；窗口 = 缓存索引 41..50（row-41..row-49 + 尾空）
        for (i in n - 9..n) {
            @Assert(flushed.contains("row-" + i.toString()), true)
        }
        // 窗口外行不可见
        @Assert(!flushed.contains("row-40"), true)
        // 行数正确性：ref 与缓存等价（render 后缓存仍一致）
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
    }

    @TestCase
    public func testRenderWindowWithScrollAndThinking(): Unit {
        // 滚动 + 思考块：窗口含思考合成行，与"基础行+思考行"的参考拼接一致
        // （仓颉区间 0..16 右开 → 16 行 m-0..m-15）
        let ov = OutputView()
        for (i in 0..16) {
            ov.append("m-" + i.toString())
        }
        ov.setThinking("思考内容", true)
        // 折叠态：思考 1 行，总 17 行；rows=8 底部窗口 = m-9..m-15 + 思考行
        let flushedBottom = renderVisible(ov, 8, 60)
        @Assert(flushedBottom.contains("m-15"), true)
        @Assert(flushedBottom.contains("思考过程 · Ctrl+T 查看"), true)
        // 向上滚 5 行：窗口后移，m-15 被滚出、m-10 可见
        ov.scrollUp(5)
        let flushedScroll = renderVisible(ov, 8, 60)
        @Assert(!flushedScroll.contains("m-15"), true)
        @Assert(flushedScroll.contains("m-10"), true)
        // 展开态：思考块 2 行（标题 + 内容）
        ov.scrollDown(100)  // 回底部
        ov.toggleThinking()
        @Assert(ov.cachedLines().size, 17)  // 16 行 + 尾空串（不含思考合成行）
        let flushedExp = renderVisible(ov, 8, 60)
        @Assert(flushedExp.contains("💭"), true)
        // 缓存恒等不受 render/滚动影响
        @Assert(sameLines(ov.cachedLines(), referenceLines(ov.content())), true)
    }
}
