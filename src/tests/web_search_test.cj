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

    // ---------- urlDecode（踩坑 §3.15 乱码回归） ----------

    @TestCase
    public func testUrlDecodeAsciiAndPlus(): Unit {
        @Assert(urlDecode("abc+def"), "abc def")
        @Assert(urlDecode("100%25"), "100%")  // % 编码的 %
        @Assert(urlDecode(""), "")
    }

    @TestCase
    public func testUrlDecodeChineseUtf8Bytes(): Unit {
        // 乱码回归：旧实现逐字节 String(Rune(byte))，%E8%AF%BB 被拆成
        // é/è/» 三个 Latin-1 字符；修复后连续 %XX 整段 UTF-8 解码
        @Assert(urlDecode("%E8%AF%BB"), "读")
        @Assert(urlDecode("a%E4%BD%A0%E5%A5%BD"), "a你好")
        @Assert(urlDecode("%E8%AF%BB%E6%87%82%E4%BB%A3%E7%A0%81"), "读懂代码")
        // 无乱码特征：不应出现 U+00E8（"读"首字节被当单字符的产物）
        @Assert(urlDecode("%E8%AF%BB").contains("\u{00e8}"), false)
    }

    @TestCase
    public func testUrlDecodeMixedEncoding(): Unit {
        // 编码段与非编码段交错：ASCII 段 flush 已累积字节
        @Assert(urlDecode("%E8%AF%BBx%E6%87%82"), "读x懂")
        @Assert(urlDecode("hello%20%E4%B8%96%E7%95%8C"), "hello 世界")
        // 末尾是编码段
        @Assert(urlDecode("end%25%E8%AF%BB"), "end%读")
        // 无效 % 序列（%Q）原样保留（含 % 本身）；前置非法字节 E8/AF 各
        // 解码为一个 U+FFFD 替换符
        @Assert(urlDecode("%E8%AF%Q%E8%AF%BB"), "\u{fffd}\u{fffd}%Q读")
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
