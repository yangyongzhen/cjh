// cjutil 最小示例：UTF-8 安全截断 + SHA-256 + HTML→Markdown（纯函数，无需网络）
package util_demo

import cjutil.*
import std.convert.*
import std.collection.*

main(): Int64 {
    // 1. UTF-8 安全截断（不切坏中文）
    let s = "你好世界 hello"
    println("原文: ${s}")
    println("截断(7字节): ${truncateUtf8(s, 7)}")
    println("尾部截断(5字节): ${tailUtf8(s, 5)}")

    // 2. SHA-256
    println("sha256('hello'): ${sha256Hex("hello".toArray())}")
    println("sha256HexStr: ${sha256HexStr("hello")}")

    // 3. HTML → Markdown
    let md = HtmlCleaner.toMarkdown("<h1>标题</h1><p>正文<strong>加粗</strong></p>")
    println("markdown:\n${md}")

    // 4. JSON 修复（截断的 JSON）
    let repaired = repairTruncatedJson("{\"name\": \"cj\", \"items\": [1, 2, 3")
    println("json 修复: ${repaired}")

    // 5. BM25（中文 bigram 检索）
    var docs = ArrayList<String>()
    docs.add("仓颉编程语言")
    docs.add("华为仓颉")
    docs.add("终端界面库")
    let bm = BM25(docs)
    let hits = bm.search("仓颉", 2)
    for (h in hits) {
        let (idx, score) = h
        println("命中块 ${idx} (score=${score})")
    }
    return 0
}
