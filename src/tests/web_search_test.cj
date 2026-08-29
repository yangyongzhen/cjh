package cjh.tests

import std.collection.*
import cjh.tools.*

/**
 * web_search 路由逻辑测试：
 * - KeyRotator：CSV 解析、多 key 轮换、耗尽
 * - SearchRouter：enabled 过滤、命中即回、空结果引擎链降级、全失败返回空
 */
@Test
public class WebSearchRouteTest {

    // ---------- KeyRotator ----------

    @TestCase
    public func testKeyRotatorParsesCsv(): Unit {
        let r = KeyRotator("key1, key2 ,key3")
        @Assert(r.hasKeys(), true)
        @Assert(r.current(), "key1")
        @Assert(r.isExhausted(), false)
    }

    @TestCase
    public func testKeyRotatorTrimsAndSkipsEmpty(): Unit {
        let r = KeyRotator("k1, ,k2,,,  k3  ")
        @Assert(r.current(), "k1")
        @Assert(r.rotate(), true)
        @Assert(r.current(), "k2")
        @Assert(r.rotate(), true)
        @Assert(r.current(), "k3")
    }

    @TestCase
    public func testKeyRotatorEmptyCsv(): Unit {
        let r = KeyRotator("")
        @Assert(r.hasKeys(), false)
        @Assert(r.current(), "")
        @Assert(r.rotate(), false)  // 无 key 立即耗尽
        @Assert(r.isExhausted(), true)
    }

    @TestCase
    public func testKeyRotatorRotationFlow(): Unit {
        let r = KeyRotator("a,b,c")
        @Assert(r.current(), "a")
        @Assert(r.rotate(), true)   // → b
        @Assert(r.current(), "b")
        @Assert(r.rotate(), true)   // → c
        @Assert(r.current(), "c")
        @Assert(r.rotate(), false)  // 耗尽
        @Assert(r.isExhausted(), true)
        @Assert(r.current(), "")    // 耗尽后 current 为空
    }

    // ---------- SearchRouter ----------

    @TestCase
    public func testRouterSkipsDisabledProvider(): Unit {
        var providers = ArrayList<SearchProvider>()
        let p1 = StubSearchProvider(false, ArrayList<SearchHit>())
        let p2 = StubSearchProvider(true, this.makeHits("h2"))
        providers.add(p1)
        providers.add(p2)
        let router = SearchRouter(providers)
        let hits = router.search("q", 5)
        @Assert(p1.callCount, 0)   // disabled 不调用
        @Assert(p2.callCount, 1)
        @Assert(hits.size, 1)
        @Assert(hits[0].title, "h2")
    }

    @TestCase
    public func testRouterReturnsFirstHit(): Unit {
        var providers = ArrayList<SearchProvider>()
        let p1 = StubSearchProvider(true, this.makeHits("h1"))
        let p2 = StubSearchProvider(true, this.makeHits("h2"))
        providers.add(p1)
        providers.add(p2)
        let router = SearchRouter(providers)
        let hits = router.search("q", 5)
        @Assert(hits.size, 1)
        @Assert(hits[0].title, "h1")
        @Assert(p2.callCount, 0)   // 命中即回，不再调下一个
    }

    @TestCase
    public func testRouterFallsBackOnEmpty(): Unit {
        // 引擎链降级：第一个引擎空结果 → 跳下一个
        var providers = ArrayList<SearchProvider>()
        let p1 = StubSearchProvider(true, ArrayList<SearchHit>())
        let p2 = StubSearchProvider(true, this.makeHits("fallback"))
        providers.add(p1)
        providers.add(p2)
        let router = SearchRouter(providers)
        let hits = router.search("q", 5)
        @Assert(p1.callCount, 1)
        @Assert(p2.callCount, 1)
        @Assert(hits.size, 1)
        @Assert(hits[0].title, "fallback")
    }

    @TestCase
    public func testRouterAllFailEmpty(): Unit {
        var providers = ArrayList<SearchProvider>()
        providers.add(StubSearchProvider(true, ArrayList<SearchHit>()))
        providers.add(StubSearchProvider(true, ArrayList<SearchHit>()))
        let router = SearchRouter(providers)
        let hits = router.search("q", 5)
        @Assert(hits.size, 0)
    }

    @TestCase
    public func testRouterNoProviders(): Unit {
        let router = SearchRouter(ArrayList<SearchProvider>())
        @Assert(router.search("q", 5).size, 0)
    }

    private func makeHits(title: String): ArrayList<SearchHit> {
        var hits = ArrayList<SearchHit>()
        hits.add(SearchHit(title, "https://example.com/" + title, "snippet"))
        return hits
    }
}

/**
 * 可配置的 stub SearchProvider（测试 SearchRouter 降级链）
 */
class StubSearchProvider <: SearchProvider {
    public var enabledFlag: Bool
    public var hits: ArrayList<SearchHit>
    public var callCount: Int64 = 0

    public init(enabled: Bool, hits: ArrayList<SearchHit>) {
        this.enabledFlag = enabled
        this.hits = hits
    }

    public func name(): String {
        return "stub"
    }

    public func enabled(): Bool {
        return this.enabledFlag
    }

    public func search(query: String, maxResults: Int64): ArrayList<SearchHit> {
        callCount += 1
        return this.hits
    }
}
