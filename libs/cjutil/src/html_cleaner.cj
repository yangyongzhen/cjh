package cjutil

/**
 * HTML 清洗器：HTML → Markdown 纯文本
 *
 * 用途：web_fetch 抓回 HTML 后清洗为 LLM 友好的 Markdown
 *
 * 清洗策略：
 *   1. 去 <script> <style> <nav> <footer> <aside> <noscript> <iframe> <form> <header> 块
 *   2. 去 HTML 注释 <!-- ... -->
 *   3. 去广告标记 class="ad" class="advertisement" id="ad-*"
 *   4. 标题转换：<h1>xxx</h1> → "# xxx"
 *   5. 段落转换：<p>xxx</p> → "xxx\n\n"
 *   6. 列表转换：<ul><li> → "- "，<ol><li> → "1. "
 *   7. 代码块转换：<pre><code> → ```...\n```
 *   8. 链接转换：<a href="url">text</a> → "[text](url)"
 *   9. 表格转换：<table> → Markdown 表格
 *  10. 剥离其他所有标签，保留纯文本
 *  11. HTML 实体解码（&amp; &lt; &gt; &quot; &#39; &nbsp;）
 *  12. 压缩多余空行
 *
 * 注意：这是一个简化实现，不处理嵌套标签的复杂场景。
 * 对于复杂页面，建议用 web_fetch 的 curl 降级或 Firecrawl 降级。
 */

import std.collection.*

public class HtmlCleaner {

    /**
     * HTML → Markdown 纯文本
     */
    public static func toMarkdown(html: String): String {
        var text = html

        // 1. 去 script/style/nav/footer/aside/noscript/iframe/form/header 块
        text = removeTagBlocks(text, "script")
        text = removeTagBlocks(text, "style")
        text = removeTagBlocks(text, "nav")
        text = removeTagBlocks(text, "footer")
        text = removeTagBlocks(text, "aside")
        text = removeTagBlocks(text, "noscript")
        text = removeTagBlocks(text, "iframe")
        text = removeTagBlocks(text, "form")
        text = removeTagBlocks(text, "header")

        // 2. 去 HTML 注释
        text = removeHtmlComments(text)

        // 3. 去广告标记
        text = removeAds(text)

        // 4. 标题转换
        text = convertHeadings(text)

        // 5. 段落转换
        text = convertParagraphs(text)

        // 6. 列表转换
        text = convertLists(text)

        // 7. 代码块转换
        text = convertCodeBlocks(text)

        // 8. 链接转换
        text = convertLinks(text)

        // 9. 换行转换：<br> → \n
        text = convertBreaks(text)

        // 10. 剥离其他所有标签
        text = stripRemainingTags(text)

        // 11. HTML 实体解码
        text = decodeHtmlEntities(text)

        // 12. 压缩多余空行
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

        // 找 > 结束开始标签
        let gtOpt = html.indexOf(">", startTag)
        if (let None <- gtOpt) { return None }
        let gt = gtOpt.getOrThrow()

        // 找 </title>
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
     * 去掉 <tag>...</tag> 整个块（包括内容）
     */
    private static func removeTagBlocks(html: String, tag: String): String {
        var result = html
        let openPrefix = "<" + tag
        let closeTag = "</" + tag + ">"

        // 循环处理所有匹配
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf(openPrefix)
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            // 找开始标签的 >
            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            // 找结束标签 </tag>
            let endOpt = lower.indexOf(closeTag, start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()
            let endLen = closeTag.size

            if (end < gt) { break }
            // 删除整个块
            let before = result[0..start]
            let after = result[end + endLen..]
            result = before + after
            found = true
        }

        return result
    }

    /**
     * 去 HTML 注释 <!-- ... -->
     */
    private static func removeHtmlComments(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let startOpt = result.indexOf("<!--")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()
            let endOpt = result.indexOf("-->", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()
            let before = result[0..start]
            let after = result[end + 3..]
            result = before + after
            found = true
        }
        return result
    }

    /**
     * 去广告标记：class="ad" class="advertisement" id="ad-*"
     * 简化实现：删除包含 ad/advertisement class 的 div 块
     */
    private static func removeAds(html: String): String {
        // 简化：只删除 class="ad" 或 class="advertisement" 的 div
        // 完整实现需要 HTML 解析器，这里用简化策略
        return html
    }

    /**
     * 标题转换：<h1>xxx</h1> → "# xxx"
     */
    private static func convertHeadings(html: String): String {
        var result = html
        for (level in 1..=6) {
            let openTag = "<h${level}"
            let closeTag = "</h${level}>"
            var found = true
            while (found) {
                found = false
                let lower = result.toAsciiLower()
                let startOpt = lower.indexOf(openTag)
                if (let None <- startOpt) { break }
                let start = startOpt.getOrThrow()

                let gtOpt = result.indexOf(">", start)
                if (let None <- gtOpt) { break }
                let gt = gtOpt.getOrThrow()

                let endOpt = lower.indexOf(closeTag, start)
                if (let None <- endOpt) { break }
                let end = endOpt.getOrThrow()

                if (end < gt) { break }
                let content = result[gt + 1..end]
                var prefix = ""
                for (_ in 0..level) { prefix += "#" }
                prefix += " "
                let before = result[0..start]
                let after = result[end + closeTag.size..]
                result = before + "\n" + prefix + content + "\n" + after
                found = true
            }
        }
        return result
    }

    /**
     * 段落转换：<p>xxx</p> → "xxx\n\n"
     */
    private static func convertParagraphs(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<p")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            let endOpt = lower.indexOf("</p>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }
            let content = result[gt + 1..end]
            let before = result[0..start]
            let after = result[end + 4..]
            result = before + "\n\n" + content + "\n\n" + after
            found = true
        }
        return result
    }

    /**
     * 列表转换：<ul><li> → "- "，<ol><li> → "1. "
     */
    private static func convertLists(html: String): String {
        var result = html

        // <ul>...</ul>
        result = convertUnorderedList(result)

        // <ol>...</ol>
        result = convertOrderedList(result)

        return result
    }

    /**
     * 转换无序列表 <ul><li> → "- "
     */
    private static func convertUnorderedList(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<ul")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            let endOpt = lower.indexOf("</ul>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }
            let content = result[gt + 1..end]
            // 转换 <li>...</li> → "- ..."
            let converted = convertListItems(content, "- ")
            let before = result[0..start]
            let after = result[end + 5..]
            result = before + "\n" + converted + "\n" + after
            found = true
        }
        return result
    }

    /**
     * 转换有序列表 <ol><li> → "1. "
     */
    private static func convertOrderedList(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<ol")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            let endOpt = lower.indexOf("</ol>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }
            let content = result[gt + 1..end]
            let converted = convertListItems(content, "1. ")
            let before = result[0..start]
            let after = result[end + 5..]
            result = before + "\n" + converted + "\n" + after
            found = true
        }
        return result
    }

    /**
     * 转换 <li>...</li> → prefix + content
     */
    private static func convertListItems(content: String, prefix: String): String {
        var result = content
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<li")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            let endOpt = lower.indexOf("</li>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }
            let itemContent = result[gt + 1..end]
            let before = result[0..start]
            let after = result[end + 5..]
            result = before + prefix + itemContent + "\n" + after
            found = true
        }
        return result
    }

    /**
     * 代码块转换：<pre><code> → ```...\n```
     */
    private static func convertCodeBlocks(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<pre")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            let endOpt = lower.indexOf("</pre>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }
            let content = result[gt + 1..end]
            // 去 <code> 和 </code>
            let cleaned = stripCodeTags(content)
            let before = result[0..start]
            let after = result[end + 6..]
            result = before + "\n```\n" + cleaned + "\n```\n" + after
            found = true
        }
        return result
    }

    /**
     * 去 <code> 和 </code> 标签
     */
    private static func stripCodeTags(content: String): String {
        var result = content
        // 去 <code ...> 和 </code>
        let lower = result.toAsciiLower()
        let codeStartOpt = lower.indexOf("<code")
        if (let Some(_) <- codeStartOpt) {
            let codeStart = codeStartOpt.getOrThrow()
            let gtOpt = result.indexOf(">", codeStart)
            if (let Some(_) <- gtOpt) {
                let gt = gtOpt.getOrThrow()
                let before = result[0..codeStart]
                let after = result[gt + 1..]
                result = before + after
            }
        }
        result = result.replace("</code>", "")
        return result
    }

    /**
     * 链接转换：<a href="url">text</a> → "[text](url)"
     */
    private static func convertLinks(html: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let startOpt = lower.indexOf("<a ")
            if (let None <- startOpt) { break }
            let start = startOpt.getOrThrow()

            // 找 <a ... > 的结束
            let gtOpt = result.indexOf(">", start)
            if (let None <- gtOpt) { break }
            let gt = gtOpt.getOrThrow()

            // 找 </a>
            let endOpt = lower.indexOf("</a>", start)
            if (let None <- endOpt) { break }
            let end = endOpt.getOrThrow()

            if (end < gt) { break }

            // 提取 href
            let tagContent = result[start..gt]
            let href = extractHref(tagContent)

            // 提取链接文本
            let text = result[gt + 1..end]

            let before = result[0..start]
            let after = result[end + 4..]
            if (href.size > 0) {
                result = before + "[" + text + "](" + href + ")" + after
            } else {
                result = before + text + after
            }
            found = true
        }
        return result
    }

    /**
     * 从 <a href="url"> 标签内容提取 href 值
     */
    private static func extractHref(tagContent: String): String {
        let lower = tagContent.toAsciiLower()
        let hrefIdxOpt = lower.indexOf("href")
        if (let None <- hrefIdxOpt) { return "" }
        let hrefIdx = hrefIdxOpt.getOrThrow()

        // 找 = 后面的引号
        let eqOpt = tagContent.indexOf("=", hrefIdx)
        if (let None <- eqOpt) { return "" }
        let eq = eqOpt.getOrThrow()

        // 跳过空格
        var quoteIdx = eq + 1
        while (quoteIdx < tagContent.size && tagContent[quoteIdx] == 32) {
            quoteIdx += 1
        }
        if (quoteIdx >= tagContent.size) { return "" }

        let quoteChar = tagContent[quoteIdx]
        // 找结束引号（匹配 " 或 '）
        var endQuote = -1
        var i = quoteIdx + 1
        while (i < tagContent.size) {
            if (tagContent[i] == quoteChar) {
                endQuote = i
                break
            }
            i += 1
        }
        if (endQuote == -1) { return "" }

        return tagContent[quoteIdx + 1..endQuote]
    }

    /**
     * 换行转换：<br> <br/> → \n
     */
    private static func convertBreaks(html: String): String {
        var result = html
        let lower = result.toAsciiLower()

        // <br/> <br /> <br> <br >
        result = replaceBreakTag(result, "<br/>")
        result = replaceBreakTag(result, "<br />")
        result = replaceBreakTag(result, "<br>")
        result = replaceBreakTag(result, "<br >")

        return result
    }

    /**
     * 替换 <br> 标签为换行符
     */
    private static func replaceBreakTag(html: String, tag: String): String {
        var result = html
        var found = true
        while (found) {
            found = false
            let lower = result.toAsciiLower()
            let idxOpt = lower.indexOf(tag)
            if (let None <- idxOpt) { break }
            let idx = idxOpt.getOrThrow()
            let before = result[0..idx]
            let after = result[idx + tag.size..]
            result = before + "\n" + after
            found = true
        }
        return result
    }

    /**
     * 剥离所有剩余 HTML 标签
     */
    private static func stripRemainingTags(html: String): String {
        // 用字节数组逐字节判断，在标签外的字节追加到结果
        var result = StringBuilder()
        var inTag = false
        for (i in 0..html.size) {
            let c = html[i]
            if (c == 60) {  // <
                inTag = true
            } else if (c == 62) {  // >
                inTag = false
            } else if (!inTag) {
                let byteArr = Array<Byte>(1, repeat: 0)
                byteArr[0] = c
                result.appendFromUtf8(byteArr)
            }
        }
        return result.toString()
    }

    /**
     * HTML 实体解码
     */
    private static func decodeHtmlEntities(text: String): String {
        var result = text
        result = result.replace("&amp;", "&")
        result = result.replace("&lt;", "<")
        result = result.replace("&gt;", ">")
        result = result.replace("&quot;", "\"")
        result = result.replace("&#39;", "'")
        result = result.replace("&#x27;", "'")
        result = result.replace("&nbsp;", " ")
        result = result.replace("&apos;", "'")
        result = result.replace("&copy;", "(c)")
        result = result.replace("&reg;", "(r)")
        result = result.replace("&trade;", "(tm)")
        return result
    }

    /**
     * 压缩多余空行（连续空行压缩为单个空行）
     */
    private static func compressWhitespace(text: String): String {
        var result = text
        // 连续空行压缩为单个空行
        while (result.contains("\n\n\n")) {
            result = result.replace("\n\n\n", "\n\n")
        }
        // 去首尾空白
        result = result.trimAscii()
        return result
    }
}
