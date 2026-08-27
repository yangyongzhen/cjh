package cjutil

/**
 * BM25 + 字符 bigram 文章检索压缩
 *
 * 用途：web_fetch 抓回的长文章（>10K 字符）直接塞给 LLM 会导致 token 暴涨，
 * 用 BM25 + 字符 bigram 检索 query 最相关的 top-k 块，压缩比约 10:1。
 *
 * 算法链路：
 *   readability 清洗 → 句子级分块带重叠 → 字符 bigram + 自写 BM25 → top-k 进 prompt
 *
 * 设计原则：
 *   - 纯算法无外部依赖，仓颉标准库够用
 *   - 字符 bigram 对中文/英文/混合文本都有效，不需要分词器
 *   - BM25 参数 k1=1.5, b=0.75（业界默认值）
 *
 * 文件组织：
 *   - bm25.cj：字符 bigram 分词 + 自写 BM25 + top-k 检索（本文件）
 *   - article_reader.cj：readability 清洗 + 句子级分块带重叠
 */

import std.collection.*
import std.math.*

/**
 * BM25 检索器
 *
 * 用法：
 *   let bm25 = BM25(chunks)
 *   let topK = bm25.search(query, 3)
 */
public class BM25 {
    private let chunks: ArrayList<String>
    private let chunkTokens: ArrayList<ArrayList<String>>  // 每块的 bigram 列表
    private let df: HashMap<String, Int64>                  // document frequency
    private let avgDl: Float64                              // 平均块长度
    private let n: Int64                                    // 块总数

    // BM25 参数（业界默认值）
    private static let k1: Float64 = 1.5
    private static let b: Float64 = 0.75

    public init(chunks: ArrayList<String>) {
        this.chunks = chunks
        this.chunkTokens = ArrayList<ArrayList<String>>()
        this.df = HashMap<String, Int64>()
        this.n = Int64(chunks.size)
        var totalLen: Int64 = 0

        // 对每块做字符 bigram 分词
        for (i in 0..chunks.size) {
            let tokens = charBigrams(chunks[i])
            this.chunkTokens.add(tokens)
            totalLen += Int64(tokens.size)

            // 统计 df：每个 term 在多少块中出现
            let seen = HashSet<String>()
            for (t in tokens) {
                if (!seen.contains(t)) {
                    seen.add(t)
                    this.df[t] = (this.df.get(t) ?? 0) + 1
                }
            }
        }

        this.avgDl = if (n > 0) { Float64(totalLen) / Float64(n) } else { 0.0 }
    }

    /**
     * 检索 query 最相关的 top-k 块
     *
     * 返回：(块索引, BM25 分数) 列表，按分数降序
     */
    public func search(query: String, topK: Int64): ArrayList<(Int64, Float64)> {
        let queryTokens = charBigrams(query)
        if (queryTokens.size == 0 || n == 0) {
            return ArrayList<(Int64, Float64)>()
        }

        // 计算每块的 BM25 分数
        var scores = ArrayList<(Int64, Float64)>()
        for (i in 0..n) {
            let score = bm25Score(i, queryTokens)
            scores.add((i, score))
        }

        // 按分数降序排序，取 top-k
        sortDescending(scores)
        var result = ArrayList<(Int64, Float64)>()
        let limit = if (topK < n) { topK } else { n }
        for (i in 0..limit) {
            result.add(scores[i])
        }
        return result
    }

    /**
     * 计算单块的 BM25 分数
     *
     * BM25(q, d) = Σ_t IDF(t) * (f(t,d) * (k1+1)) / (f(t,d) + k1*(1 - b + b*|d|/avgDl))
     * IDF(t) = ln((N - df(t) + 0.5) / (df(t) + 0.5) + 1)
     */
    private func bm25Score(chunkIdx: Int64, queryTokens: ArrayList<String>): Float64 {
        let tokens = chunkTokens[chunkIdx]
        let dl = Float64(tokens.size)
        var score: Float64 = 0.0

        // 统计 query 中每个 term 的 tf（在当前块中的频率）
        let queryTermFreq = HashMap<String, Int64>()
        for (t in queryTokens) {
            queryTermFreq[t] = (queryTermFreq.get(t) ?? 0) + 1
        }

        // 对每个 query term 累加 BM25 分数
        for ((term, qtf) in queryTermFreq) {
            // 统计 term 在当前块中的 tf
            var tf: Int64 = 0
            for (t in tokens) {
                if (t == term) { tf += 1 }
            }
            if (tf == 0) { continue }  // term 不在当前块中，跳过

            // IDF
            let dfVal: Int64 = this.df.get(term) ?? 0
            let idf = log((Float64(n) - Float64(dfVal) + 0.5) / (Float64(dfVal) + 0.5) + 1.0)

            // tf 归一化
            let tfNorm = (Float64(tf) * (BM25.k1 + 1.0)) /
                         (Float64(tf) + BM25.k1 * (1.0 - BM25.b + BM25.b * dl / this.avgDl))

            score += idf * tfNorm
        }

        return score
    }

    /**
     * 按分数降序排序（简单冒泡，块数通常 <100）
     */
    private func sortDescending(scores: ArrayList<(Int64, Float64)>): Unit {
        let n = scores.size
        for (i in 0..n) {
            for (j in 0..n - i - 1) {
                let (idx1, sc1) = scores[j]
                let (idx2, sc2) = scores[j + 1]
                if (sc1 < sc2) {
                    scores[j] = (idx2, sc2)
                    scores[j + 1] = (idx1, sc1)
                }
            }
        }
    }
}

/**
 * 字符 bigram 分词
 *
 * 把文本按相邻两字符切分，作为 term。
 * 例如 "你好世界" → ["你好", "好世", "世界"]
 *
 * 对中文/英文/混合文本都有效，不需要分词器。
 * 单字符文本返回空列表。
 */
public func charBigrams(text: String): ArrayList<String> {
    let runes = text.toRuneArray()
    let n = runes.size
    var result = ArrayList<String>()
    if (n < 2) { return result }

    for (i in 0..n - 1) {
        // 跳过包含空白字符的 bigram（空白不携带语义信息）
        let r1 = runes[i]
        let r2 = runes[i + 1]
        if (isWhitespaceRune(r1) || isWhitespaceRune(r2)) { continue }
        result.add(String(r1) + String(r2))
    }
    return result
}

/**
 * 判断 Rune 是否为空白字符
 */
private func isWhitespaceRune(r: Rune): Bool {
    let v = Int64(UInt32(r))
    return v == 32 || v == 9 || v == 10 || v == 13 || v == 12 || v == 11
}
