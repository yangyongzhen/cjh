package cjutil

/**
 * 文章读取器：readability 清洗 → 句子级分块带重叠
 *
 * 用途：web_fetch 抓回的 HTML 经 HtmlCleaner 清洗后得到纯文本，
 * 但纯文本可能很长（>10K 字符），直接塞给 LLM 会导致 token 暴涨。
 * 本模块把长文本按句子分块（带重叠），配合 BM25 检索压缩到 top-k 块。
 *
 * 算法链路：
 *   readability 清洗（HtmlCleaner.toMarkdown）→ 句子级分块带重叠 → BM25 top-k
 *
 * 分块策略：
 *   - 按句子边界（。！？.!?\n）切句
 *   - 每块包含 chunkSize 个句子，相邻块重叠 overlap 个句子
 *   - 重叠确保跨块的语义不被切断
 *
 * 文件组织：
 *   - article_reader.cj：分块逻辑（本文件）
 *   - bm25.cj：BM25 检索
 *   - html_cleaner.cj：HTML 清洗
 */

import std.collection.*

/**
 * 文章分块器
 *
 * 用法：
 *   let chunks = ArticleReader.chunkBySentence(text, 5, 2)
 */
public class ArticleReader {

    /**
     * 按句子分块（带重叠）
     *
     * 参数：
     *   - text: 输入文本（已清洗）
     *   - chunkSize: 每块包含的句子数（默认 5）
     *   - overlap: 相邻块重叠的句子数（默认 2）
     *
     * 返回：块列表，每块是一个字符串
     *
     * 策略：
     *   1. 按句子边界切句
     *   2. 每块取 chunkSize 个句子，下一块从 chunkSize - overlap 开始
     *   3. 不足 chunkSize 的尾部句子单独成块
     */
    /**
     * 按字符数分块（带重叠）
     *
     * 比 chunkBySentence 更适合 web 页面：页面噪音（短句）和正文（长段落）
     * 混在一起，句子级分块会产生大量碎块。按字符数分块保证块大小均匀，
     * BM25 检索更稳定。
     *
     * 参数：
     *   - text: 输入文本（已清洗）
     *   - chunkChars: 每块字符数（默认 800）
     *   - overlapChars: 相邻块重叠字符数（默认 200）
     */
    public static func chunkBySize(text: String, chunkChars: Int64, overlapChars: Int64): ArrayList<String> {
        let runes = text.toRuneArray()
        let n = Int64(runes.size)
        if (n == 0) { return ArrayList<String>() }

        let safeChunk = if (chunkChars > 0) { chunkChars } else { 800 }
        let safeOverlap = if (overlapChars >= 0 && overlapChars < safeChunk) { overlapChars } else { 200 }

        var chunks = ArrayList<String>()
        var pos: Int64 = 0
        while (pos < n) {
            let end = if (pos + safeChunk < n) { pos + safeChunk } else { n }
            var sb = StringBuilder()
            for (i in pos..end) {
                sb.append(String(runes[i]))
            }
            chunks.add(sb.toString())
            let advance = safeChunk - safeOverlap
            pos += if (advance > 0) { advance } else { safeChunk }
        }
        return chunks
    }

    /**
     * 按句子分块（带重叠）
     *
     * 参数：
     *   - text: 输入文本（已清洗）
     *   - chunkSize: 每块包含的句子数（默认 5）
     *   - overlap: 相邻块重叠的句子数（默认 2）
     *
     * 返回：块列表，每块是一个字符串
     *
     * 策略：
     *   1. 按句子边界切句
     *   2. 每块取 chunkSize 个句子，下一块从 chunkSize - overlap 开始
     *   3. 不足 chunkSize 的尾部句子单独成块
     */
    public static func chunkBySentence(text: String, chunkSize: Int64, overlap: Int64): ArrayList<String> {
        let sentences = splitSentences(text)
        let n = Int64(sentences.size)
        if (n == 0) { return ArrayList<String>() }

        // 防御性参数校正
        let safeChunk = if (chunkSize > 0) { chunkSize } else { 5 }
        let safeOverlap = if (overlap >= 0 && overlap < safeChunk) { overlap } else { 2 }

        var chunks = ArrayList<String>()
        var pos: Int64 = 0
        while (pos < n) {
            let end = if (pos + safeChunk < n) { pos + safeChunk } else { n }
            var sb = StringBuilder()
            for (i in pos..end) {
                if (i > pos) { sb.append(" ") }
                sb.append(sentences[i])
            }
            chunks.add(sb.toString())
            // 下一块从 chunkSize - overlap 开始（确保前进）
            let advance = safeChunk - safeOverlap
            pos += if (advance > 0) { advance } else { safeChunk }
        }
        return chunks
    }

    /**
     * 按句子边界切句
     *
     * 句子边界：。！？.!?\n
     * 保留句子末尾的标点符号
     *
     * 策略：
     *   1. 逐 Rune 遍历
     *   2. 遇到句子边界标点，切一句
     *   3. 跳过空句（只有空白或标点）
     */
    public static func splitSentences(text: String): ArrayList<String> {
        let runes = text.toRuneArray()
        let n = runes.size
        var sentences = ArrayList<String>()
        var sb = StringBuilder()

        for (i in 0..n) {
            let r = runes[i]
            sb.append(String(r))

            // 检测句子边界
            if (isSentenceBoundary(r)) {
                let s = trimString(sb.toString())
                if (s.size > 0) {
                    sentences.add(s)
                }
                sb = StringBuilder()
            }
        }

        // 处理最后一句（无句子边界标点结尾）
        let last = trimString(sb.toString())
        if (last.size > 0) {
            sentences.add(last)
        }

        return sentences
    }

    /**
     * 判断 Rune 是否为句子边界
     *
     * 中文：。！？
     * 英文：. ! ?
     * 通用：换行 \n
     */
    private static func isSentenceBoundary(r: Rune): Bool {
        let v = Int64(UInt32(r))
        // 。 U+3002, ！ U+FF01, ？ U+FF1A
        return v == 46 || v == 33 || v == 63 ||   // . ! ?
               v == 10 ||                          // \n
               v == 0x3002 || v == 0xFF01 || v == 0xFF1A  // 。！？
    }
}

/**
 * 手动 trim：去除首尾空白字符
 * 仓颉 String 没有 trim() 方法，手动实现
 */
public func trimString(s: String): String {
    let runes = s.toRuneArray()
    var start = 0
    var end = runes.size
    while (start < end && isWsRune(runes[start])) { start += 1 }
    while (end > start && isWsRune(runes[end - 1])) { end -= 1 }
    if (start >= end) { return "" }
    var sb = StringBuilder()
    for (i in start..end) { sb.append(String(runes[i])) }
    return sb.toString()
}

private func isWsRune(r: Rune): Bool {
    let v = Int64(UInt32(r))
    return v == 32 || v == 9 || v == 10 || v == 13 || v == 12 || v == 11
}

/**
 * 文章压缩器：readability 清洗 → 分块 → BM25 top-k
 *
 * 用法：
 *   let compressed = ArticleCompressor.compress(html, query, 3, 10000)
 *   // compressed 是 top-3 块拼接的字符串，<= 10000 字符
 */
public class ArticleCompressor {

    /**
     * 压缩长文章
     *
     * 参数：
     *   - html: 原始 HTML
     *   - query: 检索 query（通常是用户的原始问题）
     *   - topK: BM25 检索返回的块数（默认 3）
     *   - maxChars: 压缩后最大字符数（默认 10000）
     *
     * 返回：压缩后的文本（top-k 块拼接）
     *
     * 流程：
     *   1. HtmlCleaner.toMarkdown(html) 清洗 HTML
     *   2. ArticleReader.chunkBySentence 分块（5 句/块，重叠 2 句）
     *   3. BM25(query) 检索 top-k 块
     *   4. 拼接 top-k 块，截断到 maxChars
     */
    public static func compress(html: String, query: String, topK: Int64, maxChars: Int64): String {
        // 1. 清洗 HTML
        let text = HtmlCleaner.toMarkdown(html)

        // 2. 分块（按字符数，800 字符/块，重叠 200）
        let chunks = ArticleReader.chunkBySize(text, 800, 200)
        if (chunks.size == 0) { return text }

        // 3. BM25 检索
        let bm25 = BM25(chunks)
        let topResults = bm25.search(query, topK)

        // 4. 拼接 top-k 块（按原始顺序，而非 BM25 分数顺序）
        // 收集 top-k 块的索引
        var topIndices = ArrayList<Int64>()
        for ((idx, score) in topResults) {
            topIndices.add(idx)
        }
        // 排序索引，保持原文顺序
        sortIndices(topIndices)

        var sb = StringBuilder()
        var totalChars: Int64 = 0
        for (i in 0..topIndices.size) {
            let chunk = chunks[topIndices[i]]
            let chunkRunes = chunk.toRuneArray()
            let chunkCharCount = Int64(chunkRunes.size)

            if (totalChars + chunkCharCount > maxChars) {
                // 当前块加进来会超限，截断到剩余额度
                let remaining = maxChars - totalChars
                if (remaining > 0) {
                    for (j in 0..remaining) {
                        sb.append(String(chunkRunes[j]))
                    }
                    totalChars = maxChars
                }
                break
            }
            if (totalChars > 0) { sb.append("\n\n") }
            sb.append(chunk)
            totalChars += chunkCharCount
        }

        return sb.toString()
    }

    /**
     * 对索引列表升序排序（简单冒泡，索引数通常 <100）
     */
    private static func sortIndices(indices: ArrayList<Int64>): Unit {
        let n = indices.size
        for (i in 0..n) {
            for (j in 0..n - i - 1) {
                if (indices[j] > indices[j + 1]) {
                    let tmp = indices[j]
                    indices[j] = indices[j + 1]
                    indices[j + 1] = tmp
                }
            }
        }
    }
}
