package cjutil

/**
 * HTML 清洗器：HTML → 纯文本
 *
 * 参照 atomcode web_fetch 的 html_to_text 算法（5 阶段管线）：
 *   1. removeTagContent 删除整块 <script> <style> <head> <nav> <footer> <aside> <form> <noscript> <iframe>
 *      —— 带标签名边界检查，防止 <header 误匹配 <head
 *   2. replaceTagWith 把块级开标签替换为 \n
 *   3. 逐 Rune 循环剥离所有剩余标签（< 进 tag，> 出 tag）
 *   4. 解码 HTML 实体
 *   5. 压缩多余空行
 *
 * 不提取"正文容器"——侧边栏/评论区在 Phase 1 删 nav/footer 时已清理，
 * 剩余 <div> 在 Phase 2 变换行，Phase 3 剥标签后即为纯文本。
 * 这套管线通用且健壮，无需针对每个站点写 selector。
 *
 * 注意：这是简化实现，不处理嵌套同名标签的复杂场景。
 * 对于复杂页面，建议用 web_fetch 的 curl 降级或 Firecrawl 降级。
 */

import std.collection.*

public class HtmlCleaner {

    /**
     * HTML → 纯文本
     */
    public static func toMarkdown(html: String): String {
        // Phase 1: 删除整块标签内容
        var text = html
        text = removeTagContent(text, "script")
        text = removeTagContent(text, "style")
        text = removeTagContent(text, "head")
        text = removeTagContent(text, "nav")
        text = removeTagContent(text, "footer")
        text = removeTagContent(text, "aside")
        text = removeTagContent(text, "form")
        text = removeTagContent(text, "noscript")
        text = removeTagContent(text, "iframe")

        // Phase 2: 块级开标签 → \n
        let blockTags = [
            "p", "div", "br", "li", "tr",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "article", "section", "blockquote", "pre", "dd", "dt"
        ]
        for (tag in blockTags) {
            text = replaceTagWith(text, tag, "\n")
        }

        // Phase 3: 逐 Rune 剥离剩余所有标签
        text = stripRemainingTags(text)

        // Phase 4: 解码 HTML 实体
        text = decodeHtmlEntities(text)

        // Phase 5: 压缩多余空行
        text = compressWhitespace(text)

        return text
    }

    /**
     * 提取 <title> 标签内容
     */
    public static func extractTitle(html: String): ?String {
        let lower = html.toAsciiLower()
        let startTagOpt = lower.indexOf("<title")
        if (let None <- startTagOpt) { return None }
        let startTag = startTagOpt.getOrThrow()

        let gtOpt = html.indexOf(">", startTag)
        if (let None <- gtOpt) { return None }
        let gt = gtOpt.getOrThrow()

        let endOpt = lower.indexOf("</title", startTag)
        if (let None <- endOpt) { return None }
        let end = endOpt.getOrThrow()

        if (end <= gt + 1) { return None }
        let title = html[gt + 1..end]
        let cleaned = compressWhitespace(decodeHtmlEntities(stripRemainingTags(title)))
        if (cleaned.size == 0) { return None }
        return cleaned
    }

    /**
     * 删除 <tag>...</tag> 整块内容（包括标签本身）
     *
     * 带标签名边界检查：<tag 后面必须是 > / 空格 tab 换行，
     * 否则不匹配。防止 <header 误匹配 <head 导致删掉整个页面。
     *
     * 未闭合的标签（找不到 </tag>）从该位置丢弃到 EOF。
     */
    private static func removeTagContent(html: String, tag: String): String {
        let open = "<${tag}"
        let close = "</${tag}>"
        var result = StringBuilder()
        var pos = 0
        let lower = html.toAsciiLower()

        while (pos <= html.size) {
            let searchFrom = pos
            let relOpt = lower.indexOf(open, searchFrom)
            if (let None <- relOpt) {
                result.append(html[pos..])
                break
            }
            let absStart = relOpt.getOrThrow()

            // 边界检查：<tag 后一个字节必须是标签名终止符
            let after = absStart + open.size
            let isBoundary = if (after >= lower.size) {
                true
            } else {
                let ch = lower[after]
                ch == 62 || ch == 47 || ch == 32 || ch == 9 || ch == 10 || ch == 13
            }
            if (!isBoundary) {
                // 前缀冲突（如 <header 匹配 <head），输出 < 并继续
                result.append(html[pos..absStart + 1])
                pos = absStart + 1
                continue
            }

            // 输出匹配位置之前的内容
            result.append(html[pos..absStart])

            // 找闭标签
            let closeOpt = lower.indexOf(close, absStart)
            if (let None <- closeOpt) {
                // 未闭合，丢弃到 EOF
                break
            }
            let closeStart = closeOpt.getOrThrow()
            pos = closeStart + close.size
        }

        return result.toString()
    }

    /**
     * 把 <tag ...> 开标签替换为 replacement
     *
     * 同样带标签名边界检查。
     * 只替换开标签，不处理闭标签（闭标签在 Phase 3 被剥离）。
     */
    private static func replaceTagWith(html: String, tag: String, replacement: String): String {
        let open = "<${tag}"
        var result = StringBuilder()
        var pos = 0
        let lower = html.toAsciiLower()

        while (pos <= html.size) {
            let searchFrom = pos
            let relOpt = lower.indexOf(open, searchFrom)
            if (let None <- relOpt) {
                result.append(html[pos..])
                break
            }
            let absStart = relOpt.getOrThrow()

            // 边界检查
            let after = absStart + open.size
            let isBoundary = if (after >= lower.size) {
                true
            } else {
                let ch = lower[after]
                ch == 62 || ch == 47 || ch == 32 || ch == 9 || ch == 10 || ch == 13
            }
            if (!isBoundary) {
                result.append(html[pos..absStart + 1])
                pos = absStart + 1
                continue
            }

            // 输出匹配位置之前的内容
            result.append(html[pos..absStart])

            // 找开标签的 >
            let gtOpt = html.indexOf(">", absStart)
            if (let None <- gtOpt) {
                // 没有闭合 >，跳过开标签
                pos = absStart + open.size
            } else {
                let gt = gtOpt.getOrThrow()
                result.append(replacement)
                pos = gt + 1
            }
        }

        return result.toString()
    }

    /**
     * 剥离所有剩余 HTML 标签
     * 按 Rune（完整字符）遍历，避免逐字节 appendFromUtf8 破坏多字节 UTF-8
     */
    private static func stripRemainingTags(html: String): String {
        var result = StringBuilder()
        var inTag = false
        let runes = html.toRuneArray()
        for (i in 0..runes.size) {
            let r = runes[i]
            if (r == Rune(60)) {  // <
                inTag = true
            } else if (r == Rune(62)) {  // >
                inTag = false
            } else if (!inTag) {
                result.append(String(r))
            }
        }
        return result.toString()
    }

    /**
     * HTML 实体解码
     *
     * 处理三类实体：
     *   1. 命名实体：&amp; &lt; &gt; &quot; &apos; &nbsp;
     *   2. 十六进制数字字符引用：&#xff0c; &#x1f331; &#x2192;
     *   3. 十进制数字字符引用：&#65292; &#39; &#8217;
     */
    private static func decodeHtmlEntities(text: String): String {
        var result = text
        // 命名实体
        result = result.replace("&amp;", "&")
        result = result.replace("&lt;", "<")
        result = result.replace("&gt;", ">")
        result = result.replace("&quot;", "\"")
        result = result.replace("&apos;", "'")
        result = result.replace("&nbsp;", " ")

        // 数字字符引用（十六进制 &#xHHHH; 和十进制 &#NNNN;）
        result = decodeNumericEntities(result)

        return result
    }

    /**
     * 解码数字字符引用
     *
     * 支持两种格式：
     *   - &#xHHHH;  十六进制（如 &#xff0c; → ，）
     *   - &#NNNN;   十进制（如 &#65292; → ，）
     *
     * 用 Rune 数组遍历，避免按字节切片破坏多字节 UTF-8。
     * 扫描到 & 后检查是否为 &# 或 &#x 开头的数字字符引用，
     * 成功则替换为对应 Unicode 字符，失败则原样保留 &。
     */
    private static func decodeNumericEntities(text: String): String {
        var result = StringBuilder()
        let runes = text.toRuneArray()
        let n = runes.size
        var i = 0
        while (i < n) {
            // 检测 & 开始的实体
            if (runes[i] == Rune(38)) {  // '&'
                // 尝试解析数字字符引用
                let (decoded, consumed) = tryParseNumericEntity(runes, i, n)
                if (consumed > 0) {
                    result.append(decoded)
                    i += consumed
                    continue
                }
            }
            // 普通字符，直接追加
            result.append(String(runes[i]))
            i += 1
        }
        return result.toString()
    }

    /**
     * 尝试从位置 pos 解析数字字符引用
     *
     * 返回 (解码后的字符, 消耗的字节数)。
     * 解析失败返回 ("", 0)，调用方原样保留。
     */
    /**
     * 尝试从 Rune 数组位置 pos 解析数字字符引用
     *
     * 返回 (解码后的字符, 消耗的 Rune 数)。
     * 解析失败返回 ("", 0)，调用方原样保留 &。
     *
     * 格式：
     *   &#xHHHH;  十六进制（如 &#xff0c; → ，）
     *   &#NNNN;   十进制（如 &#65292; → ，）
     */
    private static func tryParseNumericEntity(runes: Array<Rune>, pos: Int64, n: Int64): (String, Int64) {
        // 最小长度：&#x1; = 5 Rune，&#1; = 4 Rune
        if (pos + 4 > n) { return ("", 0) }

        // 检查 &# 前缀
        if (runes[pos] != Rune(38) || runes[pos + 1] != Rune(35)) { return ("", 0) }  // &#

        var isHex = false
        var digitStart = pos + 2

        // 检查是否为十六进制 &#x 或 &#X
        if (runes[pos + 2] == Rune(120) || runes[pos + 2] == Rune(88)) {  // 'x' 或 'X'
            isHex = true
            digitStart = pos + 3
        }

        // 收集数字字符
        var digits = StringBuilder()
        var j = digitStart
        while (j < n) {
            let r = runes[j]
            let rv = Int64(UInt32(r))
            // 分号或字符串结束则停止
            if (r == Rune(59)) { break }  // ';'
            // 验证是否为合法数字字符
            if (isHex) {
                if (!((rv >= 48 && rv <= 57) ||   // 0-9
                      (rv >= 97 && rv <= 102) ||   // a-f
                      (rv >= 65 && rv <= 70))) {   // A-F
                    return ("", 0)  // 非法十六进制字符
                }
            } else {
                if (!(rv >= 48 && rv <= 57)) {   // 0-9
                    return ("", 0)  // 非法十进制字符
                }
            }
            digits.append(String(r))
            j += 1
        }

        // 必须以分号结尾
        if (j >= n || runes[j] != Rune(59)) { return ("", 0) }  // ';'

        let digitStr = digits.toString()
        if (digitStr.size == 0) { return ("", 0) }

        // 解析数字（手动进制转换，避免 Int64.parse API 差异）
        var codePoint = 0
        let digitRunes = digitStr.toRuneArray()
        if (isHex) {
            for (i in 0..digitRunes.size) {
                let r = digitRunes[i]
                let rv = Int64(UInt32(r))
                let v = if (rv >= 48 && rv <= 57) {
                    rv - 48      // '0'-'9' → 0-9
                } else if (rv >= 97 && rv <= 102) {
                    rv - 87      // 'a'-'f' → 10-15
                } else {
                    rv - 55      // 'A'-'F' → 10-15
                }
                codePoint = codePoint * 16 + v
            }
        } else {
            for (i in 0..digitRunes.size) {
                let r = digitRunes[i]
                let rv = Int64(UInt32(r))
                codePoint = codePoint * 10 + (rv - 48)
            }
        }

        // 转换为 Unicode 字符
        if (codePoint < 0 || codePoint > 0x10FFFF) {
            return ("", 0)  // 无效码点
        }
        let rune = Rune(codePoint)
        let consumed = j + 1 - pos  // 从 & 到 ; 之后
        return (String(rune), consumed)
    }

    /**
     * 压缩空白：去除每行首尾空白，删除所有空行，非空行之间只保留单个 \n
     * web_fetch 场景下 HTML 标签产生的空行没有语义价值，全部删除
     */
    private static func compressWhitespace(text: String): String {
        let lines = text.split("\n")
        var result = StringBuilder()
        var first = true
        for (line in lines) {
            // 手动 trim：找首尾非空白字节
            let runes = line.toRuneArray()
            var start = 0
            var end = runes.size
            while (start < end && isWhitespaceRune(runes[start])) { start += 1 }
            while (end > start && isWhitespaceRune(runes[end - 1])) { end -= 1 }
            if (start >= end) { continue }  // 空行，跳过
            // 追加 trim 后的内容
            if (!first) { result.append("\n") }
            for (i in start..end) {
                result.append(String(runes[i]))
            }
            first = false
        }
        return result.toString()
    }

    /**
     * 判断 Rune 是否为空白字符（空格、tab、回车、换行等）
     */
    private static func isWhitespaceRune(r: Rune): Bool {
        let v = Int64(UInt32(r))
        return v == 32 || v == 9 || v == 10 || v == 13 || v == 12 || v == 11
    }
}
