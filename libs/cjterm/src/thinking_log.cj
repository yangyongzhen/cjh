package cjterm

import std.collection.*

/**
 * ThinkingBlock：一轮思考（reasoning_content 的一次连续流）
 */
public class ThinkingBlock {
    /**
     * 轮次序号（从 1 起，单调递增）
     * 淘汰最旧轮次后不回退/不复用，便于回看时对齐日志与渲染标题
     */
    public let round: Int64
    /** 当前文本（超单轮上限时为"头 + 省略标记 + 尾"） */
    public var text: String = ""
    /** 本轮是否已结束（正式 content 开始 / 下一轮开始） */
    public var done: Bool = false
    /** 本轮已消耗 token（流式估算，折叠行显示） */
    public var tokens: Int64 = 0
    /** 被中间截断省略的字符数（0 = 未截断） */
    public var omitted: Int64 = 0
    /** text 的 Rune 数（增量维护：追加时加增量，截断时重算） */
    public var runes: Int64 = 0
    /**
     * 折行用 Rune 数组缓存。
     *
     * 动机：折行需要 Array<Rune>，而 `String.toRuneArray()` 每次都为整轮重新分配
     * （上限轮 8192 rune ≈ 32KB）；展开态每帧都要折"进行中"那一轮，这批分配是
     * 渲染路径的主要抖动来源。缓存只在**活跃轮**上有意义（冻结轮次只折一次），
     * 故轮结束时立即释放，内存上界始终是单轮 ≈ 32KB。
     */
    private var runeCache: Option<Array<Rune>> = None

    init(round: Int64) {
        this.round = round
    }

    /** 折行用 Rune 数组（命中缓存；文本变更/轮结束由 ThinkingLog 负责失效） */
    public func runeArray(): Array<Rune> {
        if (let Some(a) <- this.runeCache) {
            return a
        }
        let a = this.text.toRuneArray()
        this.runeCache = a
        return a
    }

    /** 使折行缓存失效（文本变更 / 轮结束时调用；包内可见） */
    func invalidateRuneCache(): Unit {
        this.runeCache = None
    }

    /** 是否持有折行缓存（测试观察点：验证失效时机与内存释放） */
    public func hasRuneCache(): Bool {
        return this.runeCache.isSome()
    }
}

/**
 * ThinkingLog：多轮思考历史缓冲（保序 + 上限淘汰 + 中间截断）
 *
 * 为什么需要（旧实现的两个缺口，用户反馈"思考内容无法滚动查看历史"）：
 * - TuiApp 只保留"最新一轮"思考：新一轮开始时清空上一轮 → 历史不存在，无从回看；
 * - 超限按尾部截断（`buffer[cut..size]`）→ 开头被丢弃，越想回看越看不到开头。
 *
 * 本类提供：
 * - 保序多轮：每轮独立 text/done/tokens，完成即冻结保留，不再被下一轮冲掉；
 * - 单轮上限：超出保留"头一半 + 省略标记 + 尾一半"，按 Rune 边界切分
 *   （禁止按字节切分——中文会被截成半个字符）；
 * - 轮数 / 总量上限：超出淘汰最旧轮次（既防内存膨胀，也防渲染量无界增长），
 *   但**绝不淘汰当前（末）轮**，正在流式的思考永不丢失。
 *
 * 渲染由 OutputView 负责（本类不含 ANSI）：滚动回看复用输出区既有的
 * PageUp/PageDown 机制——思考块是消息流末尾的合成段，总行数已计入滚动范围。
 */
public class ThinkingLog {
    /** 单轮上限（Rune 数）：超出保留头一半 + 尾一半；触发截断留 1/4 余量摊薄（见 applyRoundCap） */
    public static let MAX_ROUND_CHARS: Int64 = 8192
    /** 保留的最大轮数：超出淘汰最旧 */
    public static let MAX_ROUNDS: Int64 = 32
    /** 全部轮次文本总量上限（Rune 数）：超出淘汰最旧 */
    public static let MAX_TOTAL_CHARS: Int64 = 262144

    private let maxRoundChars: Int64
    private let maxRounds: Int64
    private let maxTotalChars: Int64
    /** 截断摊薄的余量分母：slack = 单轮上限 / 该值（4 → 余量 1/4 上限） */
    private let roundSlackDiv: Int64 = 4
    private var blocks: ArrayList<ThinkingBlock> = ArrayList<ThinkingBlock>()
    private var nextRound: Int64 = 1

    public init() {
        this.maxRoundChars = MAX_ROUND_CHARS
        this.maxRounds = MAX_ROUNDS
        this.maxTotalChars = MAX_TOTAL_CHARS
    }

    /**
     * 测试注入用：可定制上限以覆盖截断/淘汰边界（生产走无参 init）
     */
    public init(maxRoundChars: Int64, maxRounds: Int64, maxTotalChars: Int64) {
        this.maxRoundChars = maxRoundChars
        this.maxRounds = maxRounds
        this.maxTotalChars = maxTotalChars
    }

    /**
     * 省略标记文本（截断与渲染/断言共用，避免多处重复定义）
     */
    public static func omittedMarker(n: Int64): String {
        return "…（已省略 ${n} 字）…"
    }

    /** 已保留的轮数 */
    public func roundCount(): Int64 {
        return this.blocks.size
    }

    /** 按时间顺序的轮次列表（渲染只读遍历用） */
    public func blocksView(): ArrayList<ThinkingBlock> {
        return this.blocks
    }

    /** 末轮是否仍在进行（思考中） */
    public func isActive(): Bool {
        if (this.blocks.size == 0) {
            return false
        }
        return !this.blocks[this.blocks.size - 1].done
    }

    /** 全部轮次文本的 Rune 总量 */
    public func totalRunes(): Int64 {
        var n: Int64 = 0
        for (b in this.blocks) {
            n += b.runes
        }
        return n
    }

    /**
     * 追加思考增量。无活动轮（空 / 末轮已完成）时自动开新轮——
     * 这正是"上一轮不再被清空"的关键：旧实现此处直接丢弃上一轮。
     */
    public func append(delta: String): Unit {
        if (delta.size == 0) {
            return
        }
        if (!this.isActive()) {
            this.startRound()
        }
        let b = this.blocks[this.blocks.size - 1]
        b.text += delta
        b.runes += delta.toRuneArray().size
        b.invalidateRuneCache()
        this.applyRoundCap(b)
        this.evict()
    }

    /**
     * 直接设置当前轮文本（兼容 OutputView.setThinking 语义；
     * 流式增量路径用 append，本方法供整体替换/测试使用）
     */
    public func setCurrent(text: String, done: Bool): Unit {
        if (!this.isActive()) {
            this.startRound()
        }
        let b = this.blocks[this.blocks.size - 1]
        b.text = text
        b.runes = text.toRuneArray().size
        b.done = done
        b.invalidateRuneCache()
        this.applyRoundCap(b)
        this.evict()
    }

    /** 结束当前轮（正式 content 开始 / 新一轮开始前调用） */
    public func finishCurrent(): Unit {
        if (this.isActive()) {
            let b = this.blocks[this.blocks.size - 1]
            b.done = true
            b.invalidateRuneCache()   // 冻结轮次只折一次：此处释放，内存上界保持单轮
        }
    }

    /** 设置当前轮已消耗 token（折叠行显示）；无轮次时忽略，不凭空造轮 */
    public func setTokens(tokens: Int64): Unit {
        if (this.blocks.size == 0) {
            return
        }
        this.blocks[this.blocks.size - 1].tokens = tokens
    }

    /** 清空全部历史 */
    public func clear(): Unit {
        this.blocks = ArrayList<ThinkingBlock>()
    }

    // ===== 内部：上限维护 =====

    private func startRound(): Unit {
        this.blocks.add(ThinkingBlock(this.nextRound))
        this.nextRound += 1
        // 轮数上限：淘汰最旧（刚开的新轮在末位，不受影响）
        while (this.blocks.size > this.maxRounds) {
            this.blocks.remove(at: 0)
        }
    }

    /**
     * 单轮上限：按 Rune 边界做中间截断，保留头尾并插入省略标记。
     *
     * 摊薄（性能点）：超限后**不是每次追加都重截**——留 1/4 上限的 slack，
     * 攒够 slack 才截回上限。截断本身是 O(上限)（重建整串 + 两次切片分配），
     * 若每次追加都做，长思考流式期间这部分开销会与被重截次数同阶；留 slack 后
     * 触发频次降为 1/4，而**语义完全不变**（下次截断仍截回上限，头/尾/省略计数一致）。
     * 不变量：轮长 ≤ 上限 + slack（总量上限 evict 独立生效）。
     */
    private func applyRoundCap(b: ThinkingBlock): Unit {
        let trigger = this.maxRoundChars + this.maxRoundChars / this.roundSlackDiv
        if (this.maxRoundChars <= 0 || b.runes <= trigger) {
            return
        }
        let runes = b.text.toRuneArray()
        let total = runes.size
        let headN = this.maxRoundChars / 2
        let tailN = this.maxRoundChars - headN
        let omitted = total - this.maxRoundChars
        let head = runeSlice(runes, 0, headN)
        let tail = runeSlice(runes, total - tailN, total)
        b.omitted = omitted
        b.text = head + "\n" + ThinkingLog.omittedMarker(omitted) + "\n" + tail
        b.runes = headN + tailN
        b.invalidateRuneCache()   // 截断重写整串：折行缓存必须失效，否则折的是旧文本
    }

    /** 取 Rune 片段并拼回 String（Rune 边界安全，中文不会被切坏） */
    private func runeSlice(runes: Array<Rune>, from: Int64, to: Int64): String {
        let sb = StringBuilder()
        var i = from
        while (i < to) {
            sb.append(runes[i].toString())
            i += 1
        }
        return sb.toString()
    }

    /** 总量淘汰：超出总量上限时淘汰最旧，至少保留当前（末）轮 */
    private func evict(): Unit {
        while (this.totalRunes() > this.maxTotalChars && this.blocks.size > 1) {
            this.blocks.remove(at: 0)
        }
    }
}
