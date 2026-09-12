package cjterm

import std.collection.*

/**
 * 思考块折行：把原始 Rune 序列按"显示宽度"切成行。
 *
 * 断行规则（与整轮折行 foldThinkingBlock 的循环一一对应）：
 * - `\n` 硬断行，断点字符本身不入行；
 * - 其余字符按 `TuiCanvas.displayWidth` 累计列宽，累计超过 contentW 即断行，**溢出字符起新行**；
 * - 行首单字符就超宽时，先落一个空行再起新行（与旧实现一致，保证逐行等价）；
 * - 末尾尚有未满一行且非空 → 作为最后一行产出（这一行可能**尚未完成**，下一帧还可能被追加）。
 *
 * 为什么单独成模块：展开态每帧都要折"进行中"的那一轮，整轮重折是渲染热点（实测平均 4.5ms、
 * 峰值 17.3ms/帧）。增量做法需要"已完成行 / 未完成行"的边界，而边界必须由**同一份断行规则**
 * 得出；这里把规则抽成纯函数，行渲染仍归 OutputView（行内 Markdown 与卡片补白是本包私有的）。
 *
 * 与 foldThinkingBlock（整轮折行，现用于已完成轮次的冻结缓存）的关系：规则同源，
 * 逐行等价由 src/tests/thinking_incremental_test.cj 锁定（含"进行中增量 vs 结束后整轮"用例）。
 */

/** 折行内容宽度：与旧实现一致（宽度 > 4 时留 4 列给卡片前缀，否则退化为 10） */
func thinkingContentWidth(width: Int64): Int64 {
    if (width > 4) {
        return width - 4
    }
    return 10
}

/** 折行结果：各行原文 + 各行 Rune 起点 + 最后一行起点（增量推进锚点） */
class ThinkingFoldResult {
    /** 行原文（未渲染；渲染需 OutputView 的行内 Markdown 与卡片包装） */
    public var lines: ArrayList<String> = ArrayList<String>()
    /** 与 lines 一一对应的行首 Rune 下标（用于按 Rune 区间切分"已冻结头部"） */
    public var starts: ArrayList<Int64> = ArrayList<Int64>()
    /** 最后一行的 Rune 起点：下一帧从这里重折（该行可能尚未完成） */
    public var lastStart: Int64 = 0
}

/** 取前 n 个 Rune 的文本快照：用于校验"冻结头部"是否仍然有效（文本被整体改写时会变） */
func thinkingHeadText(runes: Array<Rune>, n: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < n && i < runes.size) {
        sb.append(runes[i].toString())
        i += 1
    }
    return sb.toString()
}

/**
 * 从 Rune 序列的 `from` 起折行（要求 `from` 落在行首，即上一帧产出的 lastStart）。
 * 纯函数：不读全局状态、不做渲染，便于单测与等价性比对。
 */
func foldThinkingSpans(runes: Array<Rune>, from: Int64, contentW: Int64): ThinkingFoldResult {
    let res = ThinkingFoldResult()
    if (from >= runes.size) {
        res.lastStart = from
        return res
    }
    var buf = StringBuilder()
    var bufLen: Int64 = 0
    var bufW: Int64 = 0
    var lineStart = from
    var i = from
    while (i < runes.size) {
        let ch = runes[i].toString()
        if (ch == "\n") {
            res.lines.add(buf.toString())
            res.starts.add(lineStart)
            res.lastStart = lineStart
            i += 1
            lineStart = i
            buf = StringBuilder()
            bufLen = 0
            bufW = 0
            continue
        }
        let chW = TuiCanvas.displayWidth(ch)
        if (bufW + chW > contentW) {
            res.lines.add(buf.toString())
            res.starts.add(lineStart)
            res.lastStart = lineStart
            lineStart = i
            buf = StringBuilder()
            buf.append(ch)
            bufLen = 1
            bufW = chW
        } else {
            buf.append(ch)
            bufLen += 1
            bufW += chW
        }
        i += 1
    }
    if (bufLen > 0) {
        res.lines.add(buf.toString())
        res.starts.add(lineStart)
        res.lastStart = lineStart
    }
    return res
}

/**
 * 展开态"进行中轮次"的增量折行状态（只放数据；已完成行的渲染结果缓存在 OutputView）。
 *
 * 失效条件（任一不满足即整体重置）：
 * - `roundGen`：轮次身份（ThinkingLog 每开新轮 +1）；
 * - `textEpoch`：文本代数（截断重写 / setCurrent 整体改写 +1；纯追加不变——正是增量生效的场景）；
 * - `width`：渲染宽度变化（宽度变了所有行的断点都变）；
 * - `tailStart > 当前 Rune 数`：文本变短（兜底）。
 */
class ThinkingActiveFoldCache {
    public var roundGen: Int64 = -1
    public var textEpoch: Int64 = -1
    public var width: Int64 = 0
    public var tailStart: Int64 = 0
    /** 已完成的渲染行（复用，不再重折） */
    public var lines: ArrayList<String> = ArrayList<String>()
    /** 已冻结头部覆盖的 Rune 数（0 = 未进入截断态，无头部可冻结） */
    public var headRunes: Int64 = 0
    /** 冻结头部当时的文本快照：与当前头部不一致 = 文本被整体改写，头部缓存作废 */
    public var headText: String = ""
    /** 冻结头部的渲染行（截断后头部永久稳定，只在首次进入截断态时折一次） */
    public var headLines: ArrayList<String> = ArrayList<String>()
}
