package cjh.tools

import std.collection.*
import std.convert.*
import std.fs.*
import stdx.encoding.json.*
import cjllm.ToolSpec
import cjutil.*

/**
 * cangjie_ref 工具（仓颉知识层二期）：本地语料只读检索
 *
 * 背景与定位：
 * - 一期的技能入口只把"描述 + 全文绝对路径"放进 system prompt（常驻最小化），
 *   正文躺在 `~/.cjh/cangjie-ref/skills/<name>/SKILL.md` 等 Markdown 里；
 * - 模型要在几万字节语料里找"ArrayList 排序怎么写""编译报类型推断错怎么办"，
 *   靠 read_file 逐篇读太贵、靠 grep 全仓搜会跑到无关文件；
 * - 本工具把这层语料当作**一个只读知识库**检索，返回带文件 / 行号 / 小节标题的
 *   片段，模型再 `read_file(path, offset=行号)` 精读命中那一段。
 *
 * 设计决策（与 docs/设计-仓颉内置知识层.md 对应）：
 * - **零依赖、纯离线**：只用仓颉标准库 + cjutil，不联网、不引第三方、不调外部进程；
 * - **不持久化索引**：语料是几十 KB 级 Markdown（实测 39 MB 全量扫描也仅 35 ms），
 *   持久化倒排索引只会引入文件格式、版本、失效检测的复杂度，收益为零。
 *   这里"每次查询在内存里建行级索引"＝同一算法的无状态实现；
 * - **不缓存、无共享可变状态**：本工具声明 isReadOnly()=true，会被并发执行引擎并行调用，
 *   任何进程级缓存都要加锁；几十 KB 的扫描成本远低于锁竞争与陈旧缓存的代价；
 * - **只收 `.md`**：语料目录里混有 8.9 MB 的 `knowledge.sqlite3` 二进制，
 *   按扩展名白名单收文件，从根上避免把二进制当文本读。
 */

/**
 * 语料文件递归收集状态（仓颉闭包不能捕获可变局部变量，用状态类承载）
 */
class RefScanState {
    public let files: ArrayList<String> = ArrayList<String>()

    /**
     * 递归收集 dir 下的 Markdown 文件绝对路径。
     * Directory.walk 只遍历直接子项（非递归），子目录须显式下钻；
     * 隐藏目录（如安装脚本的 .backup、.git）整棵跳过。
     */
    public func collect(dir: String): Unit {
        let subdirs = ArrayList<String>()
        try {
            Directory.walk(dir, { fi =>
                if (fi.isDirectory()) {
                    if (!fi.name.startsWith(".")) {
                        subdirs.add(fi.name)
                    }
                } else if (fi.name.endsWith(".md")) {
                    this.files.add(dir + "/" + fi.name)
                }
                return true
            })
        } catch (e: Exception) {
            // 目录不可读（权限等）：跳过该目录，不中断整轮检索
            return
        }
        for (sub in subdirs) {
            this.collect(dir + "/" + sub)
        }
    }
}

/**
 * 查询分词状态：ASCII 词与 CJK 连续段分别累积，遇分隔符落袋
 */
class RefTokenState {
    // 主 token：ASCII 词（≥2 字符）与 CJK 2-gram
    public let tokens: ArrayList<String> = ArrayList<String>()
    // 兜底单字符：查询整体只有单字符时才用（否则噪音太大）
    public let singles: ArrayList<String> = ArrayList<String>()
    public var asciiWord: String = ""
    public let cjkChars: ArrayList<String> = ArrayList<String>()

    public func flushAscii(): Unit {
        if (this.asciiWord.size >= 2) {
            this.tokens.add(lowerAsciiStr(this.asciiWord))
        } else if (this.asciiWord.size == 1) {
            this.singles.add(lowerAsciiStr(this.asciiWord))
        }
        this.asciiWord = ""
    }

    public func flushCjk(): Unit {
        let n = this.cjkChars.size
        if (n >= 2) {
            var k: Int64 = 0
            while (k + 1 < n) {
                this.tokens.add(this.cjkChars[k] + this.cjkChars[k + 1])
                k += 1
            }
        } else if (n == 1) {
            this.singles.add(this.cjkChars[0])
        }
        this.cjkChars.clear()
    }

    public func flushAll(): Unit {
        this.flushAscii()
        this.flushCjk()
    }
}

// UTF-8 前导字节 → 字符字节数：直接复用同包 edit.cj 的 utf8CharLen（同类工具函数不重复实现）

/**
 * ASCII 词字符（字母 / 数字 / 下划线）；其余按分隔符处理
 */
private func isWordByte(b: UInt8): Bool {
    if (b >= 48u8 && b <= 57u8) {
        return true
    }
    if (b >= 65u8 && b <= 90u8) {
        return true
    }
    if (b >= 97u8 && b <= 122u8) {
        return true
    }
    return b == 95u8
}

private let ASCII_LOWER: String = "abcdefghijklmnopqrstuvwxyz"

/**
 * ASCII 大写转小写（多字节字符原样保留，故同一结果可直接用于 CJK token 匹配）
 */
public func lowerAsciiStr(s: String): String {
    var out = ""
    var i: Int64 = 0
    let n = s.size
    while (i < n) {
        let b = s[i]
        if (b >= 65u8 && b <= 90u8) {
            let idx = Int64(b) - 65
            out += ASCII_LOWER[idx..idx + 1]
            i += 1
        } else if (b < 0x80u8) {
            out += s[i..i + 1]
            i += 1
        } else {
            // 多字节字符必须整字符切片：按字节切会切碎 UTF-8 序列，
            // 运行时抛 "IllegalArgumentException: Invalid utf8 byte sequence"
            let len = utf8CharLen(b)
            if (i + len > n) {
                break  // 末尾残缺序列：丢弃
            }
            out += s[i..i + len]
            i += len
        }
    }
    return out
}

/**
 * 查询分词（纯函数，可直接单测）：
 * - ASCII 连续字母/数字/下划线 → 小写词（长度 ≥2 保留，单字符只在兜底时用）
 * - CJK 等非 ASCII 连续段 → 逐字符切分后取相邻 2-gram（"编译报错" → 编译/译报/报错）
 * - 主 token 为空时回退单字符（保证"查单字"仍可用）
 */
public func refTokens(query: String): ArrayList<String> {
    let st = RefTokenState()
    var i: Int64 = 0
    let n = query.size
    while (i < n) {
        let b = query[i]
        if (isWordByte(b)) {
            st.flushCjk()
            st.asciiWord += query[i..i + 1]
            i += 1
        } else if (b >= 0x80u8) {
            st.flushAscii()
            let len = utf8CharLen(b)
            if (i + len > n) {
                // 末尾残缺多字节序列：丢弃该字节
                i += 1
                continue
            }
            st.cjkChars.add(query[i..i + len])
            i += len
        } else {
            st.flushAll()
            i += 1
        }
    }
    st.flushAll()
    if (st.tokens.size == 0) {
        return dedupTokens(st.singles)
    }
    return dedupTokens(st.tokens)
}

private func dedupTokens(src: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (t in src) {
        if (!out.contains(t)) {
            out.add(t)
        }
    }
    return out
}

/**
 * 单行打分（纯函数，可直接单测）：
 *   命中 token 数 * 10 + 全覆盖再 +25 + 标题行再 +8；零命中为 0
 * 计分口径刻意保守：只奖励"命中面"（多少查询词都出现了），不猜语义。
 */
public func scoreRefLine(line: String, isHeading: Bool, tokens: ArrayList<String>): Int64 {
    let low = lowerAsciiStr(line)
    var matched: Int64 = 0
    for (t in tokens) {
        if (low.contains(t)) {
            matched += 1
        }
    }
    if (matched == 0) {
        return 0
    }
    var score = matched * 10
    if (matched == tokens.size) {
        score += 25
    }
    if (isHeading) {
        score += 8
    }
    return score
}

/**
 * 一条命中（行级）
 */
class RefHit {
    public let path: String
    public let lineNo: Int64
    public let heading: String
    public let text: String
    public let score: Int64

    public init(path: String, lineNo: Int64, heading: String, text: String, score: Int64) {
        this.path = path
        this.lineNo = lineNo
        this.heading = heading
        this.text = text
        this.score = score
    }
}

/**
 * cangjie_ref：仓颉知识层语料检索（只读）
 */
public class CangjieRefTool <: CjhTool {
    // 语料根目录（~/.cjh/cangjie-ref），由 CjhConfig 注入
    private let refDir: String
    // 同一文件最多返回几条，避免一篇文档刷屏
    private let maxPerFile: Int64 = 2
    // 输出总字节上限（片段级检索，够用即可）
    private let maxOutBytes: Int64 = 4096

    public init(refDir: String) {
        var d = refDir
        while (d.size > 1 && d.endsWith("/")) {
            d = d[0..d.size - 1]
        }
        this.refDir = d
    }

    public func isReadOnly(): Bool {
        return true  // 纯读：V2d 并发执行引擎分类
    }

    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("query", JsonSchema.str("Keywords: a Cangjie symbol or a Chinese topic, e.g. \"ArrayList sortBy\", \"编译报错 类型推断\""))
        props.add("max_results", JsonSchema.str("Max snippets to return (default 5, cap 20)"))
        props.add("path", JsonSchema.str("Optional: restrict search to a file path or subdirectory under the corpus root"))
        let schema = JsonSchema.object(props, ArrayList<String>(["query"]))
        return ToolSpec("cangjie_ref",
            "Search the locally installed Cangjie knowledge corpus offline (API quickref, gotcha list, " +
            "ecosystem resources, PR/README templates). Returns ranked file:line snippets with the section " +
            "heading; then read_file that path/offset to read the full section. Prefer this over grepping " +
            "the repository when the question is about Cangjie itself.",
            schema)
    }

    public func execute(args: JsonObject): ToolResult {
        // 1. 参数校验
        if (!args.containsKey("query")) {
            return ToolResult("缺少参数: query", true)
        }
        let query = args.get("query").getOrThrow().asString().getValue()
        let tokens = refTokens(query)
        if (tokens.size == 0) {
            return ToolResult("query 为空或不含可检索字符：给中文关键词（≥2 字）或仓颉符号名（如 ArrayList）", true)
        }
        var maxResults: Int64 = 5
        if (let Some(v) <- args.get("max_results")) {
            let parsed = jsonIntOf(v)
            if (parsed > 0) {
                maxResults = parsed
            }
        }
        if (maxResults > 20) {
            maxResults = 20
        }
        var pathFilter = ""
        if (let Some(v) <- args.get("path")) {
            pathFilter = v.asString().getValue()
        }

        // 2. 语料目录自检（未安装知识层时给出可操作提示，而不是空结果）
        if (!exists(this.refDir)) {
            return ToolResult(
                "仓颉知识层语料目录不存在：${this.refDir}\n" +
                "安装：scripts/install-cangjie-knowledge.sh（加 --with-cangjie-skills 可额外收录外部技能）",
                true)
        }

        // 3. 收集语料文件（只收 Markdown）
        let scan = RefScanState()
        scan.collect(this.refDir)
        var files = ArrayList<String>()
        for (f in scan.files) {
            if (pathFilter.size == 0 || f.contains(pathFilter)) {
                files.add(f)
            }
        }
        if (files.size == 0) {
            return ToolResult("语料中无可检索的 Markdown 文件（语料根 ${this.refDir}，路径过滤「${pathFilter}」）", true)
        }

        // 4. 行级检索（内存建索引：语料是几十 KB 级，扫描成本远低于持久化索引的复杂度）
        let hits = ArrayList<RefHit>()
        for (f in files) {
            let text = tryReadTextFile(f)
            if (text.size == 0) {
                continue
            }
            let lines = text.split("\n", -1)
            var heading = ""
            var no: Int64 = 0
            for (raw in lines) {
                no += 1
                let line = raw.trimAscii()
                if (line.size == 0) {
                    continue
                }
                let isHeading = line.startsWith("#")
                if (isHeading) {
                    heading = line
                }
                let score = scoreRefLine(line, isHeading, tokens)
                if (score > 0) {
                    hits.add(RefHit(f, no, heading, line, score))
                }
            }
        }
        if (hits.size == 0) {
            return ToolResult(
                "未命中（扫描 ${files.size} 个 Markdown，语料根 ${this.refDir}）\n" +
                "建议：换更短的关键词、或改用仓颉精确符号名（如 ArrayList、Directory.walk、cjpm）；" +
                "也可以直接 read_file 技能入口里给出的全文路径。",
                false)
        }

        // 5. 排序取前 N（手写插入排序，避免依赖集合排序 API 的细节差异）
        var sorted = hits.toArray()
        var i: Int64 = 1
        while (i < sorted.size) {
            let cur = sorted[i]
            var j = i - 1
            while (j >= 0 && sorted[j].score < cur.score) {
                sorted[j + 1] = sorted[j]
                j -= 1
            }
            sorted[j + 1] = cur
            i += 1
        }

        // 6. 渲染（同文件限量 + 输出字节上限）
        var sb = StringBuilder()
        var outBytes: Int64 = 0
        var header = "仓颉知识层检索「${query}」：命中 ${hits.size} 处，扫描 ${files.size} 个 Markdown\n"
        sb.append(header)
        outBytes += header.size
        let accepted = ArrayList<RefHit>()
        var truncated = false
        for (h in sorted) {
            if (accepted.size >= maxResults) {
                break
            }
            var sameFile: Int64 = 0
            for (a in accepted) {
                if (a.path == h.path) {
                    sameFile += 1
                }
            }
            if (sameFile >= this.maxPerFile) {
                continue
            }
            var title = h.heading
            if (title.size == 0) {
                title = "(无小节标题)"
            }
            var block = "[${accepted.size + 1}] score=${h.score} ${truncateUtf8(title, 60)}\n"
            block += "    ${h.path}:${h.lineNo}\n"
            block += "    ${truncateUtf8(h.text, 200)}\n"
            if (outBytes + block.size > this.maxOutBytes) {
                truncated = true
                break
            }
            sb.append(block)
            outBytes += block.size
            accepted.add(h)
        }
        if (accepted.size == 0) {
            return ToolResult("命中 ${hits.size} 处，但输出上限内无可展示片段（调大 max_results 或收窄 query）", false)
        }
        if (truncated || accepted.size < maxResults) {
            sb.append("…（共命中 ${hits.size} 处，本次展示 ${accepted.size} 处；可调大 max_results 或收窄 query）\n")
        }
        sb.append("提示：用 read_file(path, offset=<行号>, limit=…) 精读命中段落；本工具只返回片段，不含全文。")
        return ToolResult(sb.toString(), false)
    }
}

/**
 * JSON 数值参数取值（字符串 / 整数两种写法都接受，其他按 0）
 */
private func jsonIntOf(v: JsonValue): Int64 {
    match (v.kind()) {
        case JsonKind.JsInt => return v.asInt().getValue()
        case JsonKind.JsString =>
            try {
                return Int64.parse(v.asString().getValue())
            } catch (e: Exception) {
                return 0
            }
        case _ => return 0
    }
}

/**
 * 读文本文件（失败或空文件返回空串；不抛异常打断整轮检索）
 */
private func tryReadTextFile(path: String): String {
    try {
        return safeFromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        return ""
    }
}
