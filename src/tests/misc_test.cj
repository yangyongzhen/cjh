package cjh.tests

import std.collection.*
import cjutil.*
import cjh.tools.*

/**
 * WebBudget / BM25 单元测试（skills/tool_format/TaskTool 在 src/core_funcs_test.cj，根包内）
 */
@Test
public class MiscToolsTest {

    // ---------- WebBudget ----------

    @TestCase
    public func testWebBudgetLimits(): Unit {
        let budget = WebBudget(2, 3, 100)
        @Assert(budget.tryFetch(10).isSome(), false)
        @Assert(budget.tryFetch(10).isSome(), false)
        // 第 3 次超出 fetch 次数上限
        let denied = budget.tryFetch(10)
        @Assert(denied.isSome(), true)
        @Assert(denied.getOrThrow().contains("budget exceeded"), true)
        // search 独立计数
        @Assert(budget.trySearch().isSome(), false)
        @Assert(budget.trySearch().isSome(), false)
        @Assert(budget.trySearch().isSome(), false)
        @Assert(budget.trySearch().isSome(), true)
    }

    @TestCase
    public func testWebBudgetByteLimit(): Unit {
        let budget = WebBudget(10, 10, 100)
        @Assert(budget.tryFetch(60).isSome(), false)
        @Assert(budget.tryFetch(40).isSome(), false)
        // 累计 100 字节已达上限
        let denied = budget.tryFetch(1)
        @Assert(denied.isSome(), true)
        @Assert(denied.getOrThrow().contains("byte"), true)
    }

    @TestCase
    public func testWebBudgetZeroMeansUnlimited(): Unit {
        let budget = WebBudget(0, 0, 0)
        for (i in 0..100) {
            @Assert(budget.tryFetch(1000000).isSome(), false)
            @Assert(budget.trySearch().isSome(), false)
        }
    }

    @TestCase
    public func testWebBudgetStats(): Unit {
        let budget = WebBudget(5, 5, 500)
        budget.tryFetch(30)
        budget.trySearch()
        let stats = budget.stats()
        @Assert(stats.contains("fetches=1/5"), true)
        @Assert(stats.contains("bytes=30/500"), true)
        @Assert(stats.contains("searches=1/5"), true)
    }

    // ---------- BM25 ----------

    @TestCase
    public func testCharBigramsChinese(): Unit {
        let bigrams = charBigrams("你好世界")
        @Assert(bigrams.size, 3)
        @Assert(bigrams[0], "你好")
        @Assert(bigrams[1], "好世")
        @Assert(bigrams[2], "世界")
    }

    @TestCase
    public func testCharBigramsSkipsWhitespace(): Unit {
        // "hello world"：含空格的 bigram 被跳过
        let bigrams = charBigrams("a b")
        // "a " 和 " b" 含空白被跳过 → 空
        @Assert(bigrams.size, 0)
    }

    @TestCase
    public func testCharBigramsShortText(): Unit {
        @Assert(charBigrams("单").size, 0)
        @Assert(charBigrams("").size, 0)
    }

    @TestCase
    public func testBM25TopKRelevant(): Unit {
        var chunks = ArrayList<String>()
        chunks.add("苹果种植技术 苹果 苹果")       // 与"苹果"最相关
        chunks.add("香蕉种植技术")
        chunks.add("苹果的营养价值")              // 相关但词频低
        let bm25 = BM25(chunks)
        let top1 = bm25.search("苹果", 1)
        @Assert(top1.size, 1)
        @Assert(top1[0][0], 0)  // 最相关是第 0 块
    }

    @TestCase
    public func testBM25EmptyInputs(): Unit {
        let bm25 = BM25(ArrayList<String>())
        @Assert(bm25.search("q", 3).size, 0)
        var chunks = ArrayList<String>()
        chunks.add("内容")
        let bm252 = BM25(chunks)
        @Assert(bm252.search("", 3).size, 0)
    }
}
