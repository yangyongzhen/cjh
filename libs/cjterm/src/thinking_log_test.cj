package cjterm

/**
 * ThinkingLog（多轮思考历史缓冲）测试。
 *
 * 复现的缺口（用户反馈"思考(thinking) 内容无法滚动查看历史"）：
 * 旧实现把思考存在 TuiApp 的单个字符串里，**新一轮思考开始时清空上一轮**，
 * 超限又按尾部截断（开头被丢弃）——历史无从回看，回看也看不到开头。
 *
 * 本测试钉住新契约：
 * 1. 逐轮累积，上一轮不再被清空（主路径，旧实现在此丢历史）；
 * 2. 单轮超限做"头 + 省略标记 + 尾"的中间截断，且按 Rune 边界切分（中文不截半）；
 * 3. 轮数/总量上限淘汰最旧，但当前（末）轮永不被淘汰；
 * 4. 边界：空增量不造轮、setCurrent 同轮覆盖、clear 归零。
 */
@Test
public class ThinkingLogTest {

    /** 主路径：逐轮累积，上一轮不再被清空 */
    @TestCase
    public func testRoundsAccumulate(): Unit {
        let log = ThinkingLog()
        log.append("第一轮思考")
        @Assert(log.roundCount(), 1)
        @Assert(log.isActive(), true)
        log.finishCurrent()
        @Assert(log.isActive(), false)
        log.append("第二轮思考")
        @Assert(log.roundCount(), 2)
        let blocks = log.blocksView()
        @Assert(blocks[0].text, "第一轮思考")
        @Assert(blocks[0].done, true)
        @Assert(blocks[1].text, "第二轮思考")
        @Assert(blocks[1].done, false)
        @Assert(blocks[0].round, 1)
        @Assert(blocks[1].round, 2)
    }

    /** 边界：空增量不产生轮次；无轮次时 setTokens 不凭空造轮 */
    @TestCase
    public func testEmptyInputsKeepRoundCount(): Unit {
        let log = ThinkingLog()
        log.append("")
        @Assert(log.roundCount(), 0)
        @Assert(log.isActive(), false)
        log.setTokens(50)
        @Assert(log.roundCount(), 0)
        log.finishCurrent()
        @Assert(log.roundCount(), 0)
    }

    /** 单轮上限：中间截断保留头尾（旧实现只留尾部，开头丢失） */
    @TestCase
    public func testRoundMiddleTruncation(): Unit {
        // 上限 10 字、输入 20 字（全是 3 字节中文，Rune 边界安全才有意义）。
        // 用单字列表拼装，避免手写字面量的字数歧义
        let marks = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九",
            "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let sb = StringBuilder()
        for (m in marks) {
            sb.append(m)
        }
        let input = sb.toString()
        let log = ThinkingLog(10, 32, 100000)
        log.append(input)
        let b = log.blocksView()[0]
        @Assert(input.toRuneArray().size, 20)
        @Assert(b.omitted, 10)   // 20 - 10
        @Assert(b.runes, 10)
        @Assert(b.text.indexOf(ThinkingLog.omittedMarker(10)).isSome(), true)
        let headIdx = b.text.indexOf("零一二三四")   // 头 5 字
        let tailIdx = b.text.indexOf("己庚辛壬癸")   // 尾 5 字
        @Assert(headIdx.isSome(), true)
        @Assert(tailIdx.isSome(), true)
        let markIdx = b.text.indexOf(ThinkingLog.omittedMarker(10))
        @Assert(headIdx.getOrThrow() < markIdx.getOrThrow(), true)
        @Assert(markIdx.getOrThrow() < tailIdx.getOrThrow(), true)
        // 未越界的中间内容确实被省略（不是只截尾也不是只截头）
        @Assert(b.text.indexOf("九十甲乙").isNone(), true)
    }

    /** 边界：上限 1 字时只留尾字 + 标记 */
    @TestCase
    public func testTinyCapBoundary(): Unit {
        let log = ThinkingLog(1, 32, 100000)
        log.append("甲乙丙")
        let b = log.blocksView()[0]
        @Assert(b.omitted, 2)
        @Assert(b.runes, 1)
        @Assert(b.text.indexOf("丙").isSome(), true)
        @Assert(b.text.indexOf("甲").isNone(), true)
    }

    /** 轮数上限：淘汰最旧，轮次编号单调不回退 */
    @TestCase
    public func testRoundEviction(): Unit {
        let log = ThinkingLog(1000, 3, 100000)
        for (i in 1..=6) {
            log.append("轮次" + i.toString())
            log.finishCurrent()
        }
        @Assert(log.roundCount(), 3)
        let blocks = log.blocksView()
        @Assert(blocks[0].round, 4)   // 第 1~3 轮已淘汰
        @Assert(blocks[2].round, 6)
        @Assert(blocks[2].text, "轮次6")
    }

    /** 总量上限：淘汰最旧，但当前轮永不被淘汰 */
    @TestCase
    public func testTotalEvictionKeepsCurrent(): Unit {
        let log = ThinkingLog(1000, 100, 12)
        log.append("第一轮思考内容")   // 7 字
        log.finishCurrent()
        log.append("第二轮思考内容")   // 累计 14 > 12 → 淘汰最旧
        @Assert(log.roundCount(), 1)
        @Assert(log.blocksView()[0].text, "第二轮思考内容")
        @Assert(log.totalRunes() <= 12, true)
        // 当前轮自己超总量上限时也不淘汰（正在流式的思考不能丢）
        log.append("追加内容继续增长超过上限很多字")
        @Assert(log.roundCount(), 1)
        @Assert(log.blocksView()[0].text, "第二轮思考内容追加内容继续增长超过上限很多字")
    }

    /** setCurrent 同轮覆盖 / clear 归零 */
    @TestCase
    public func testSetCurrentAndClear(): Unit {
        let log = ThinkingLog()
        log.setCurrent("整体替换", false)
        @Assert(log.roundCount(), 1)
        @Assert(log.isActive(), true)
        log.setCurrent("整体替换并结束", true)
        @Assert(log.roundCount(), 1)   // 同一活动轮内覆盖，不另开轮
        @Assert(log.blocksView()[0].text, "整体替换并结束")
        @Assert(log.isActive(), false)
        log.append("新轮")
        @Assert(log.roundCount(), 2)
        log.clear()
        @Assert(log.roundCount(), 0)
        @Assert(log.isActive(), false)
        @Assert(log.totalRunes(), 0)
    }

    /** token 计数落在当前轮（折叠行显示用） */
    @TestCase
    public func testTokensOnCurrentRound(): Unit {
        let log = ThinkingLog()
        log.append("第一轮")
        log.setTokens(123)
        log.finishCurrent()
        log.append("第二轮")
        log.setTokens(456)
        let blocks = log.blocksView()
        @Assert(blocks[0].tokens, 123)
        @Assert(blocks[1].tokens, 456)
        @Assert(log.isActive(), true)
    }

    /** 生成重复字符（避免手数长字面量，断言可读） */
    private func repeatChar(c: String, n: Int64): String {
        let sb = StringBuilder()
        for (i in 1..=n) {
            sb.append(c)
        }
        return sb.toString()
    }

    /**
     * 截断摊薄的边界：未越过「上限 + 余量(上限/4)」不截断；
     * 越过则**一次截回上限**，头/尾/省略计数语义与旧实现完全一致。
     */
    @TestCase
    public func testRoundCapSlackAmortizes(): Unit {
        let log = ThinkingLog(100, 32, 100000)   // 余量 = 100/4 = 25 → 阈值 125
        log.append(this.repeatChar("A", 120))
        var b = log.blocksView()[0]
        // 120 ≤ 125：不触发截断——这正是摊薄省掉的那次全量重截
        @Assert(b.runes, 120)
        @Assert(b.omitted, 0)
        @Assert(b.text.size, 120)
        // 130 > 125：触发截断，一次截回上限（头 50 + 标记 + 尾 50）
        log.append(this.repeatChar("B", 10))
        b = log.blocksView()[0]
        @Assert(b.runes, 100)
        @Assert(b.omitted, 30)
        @Assert(b.text.indexOf(ThinkingLog.omittedMarker(30)).isSome(), true)
        @Assert(b.text.indexOf(this.repeatChar("A", 10)).isSome(), true)   // 头仍在
        @Assert(b.text.indexOf(this.repeatChar("B", 10)).isSome(), true)   // 尾仍在
        @Assert(b.text.indexOf(this.repeatChar("A", 51)).isNone(), true)   // 头只留 50 字
    }

    /** 小上限：余量按上限/4 取整（4 → 1），且截断仍按 Rune 边界（中文不截半） */
    @TestCase
    public func testRoundCapSlackSmallCapBoundary(): Unit {
        let log = ThinkingLog(4, 32, 100000)   // 余量 = 1 → 阈值 5
        log.append("甲乙丙丁戊")               // 5 ≤ 5：不截断
        var b = log.blocksView()[0]
        @Assert(b.runes, 5)
        @Assert(b.omitted, 0)
        log.append("己")                       // 6 > 5：截回 4（头 2 字 + 尾 2 字）
        b = log.blocksView()[0]
        @Assert(b.runes, 4)
        @Assert(b.omitted, 2)
        @Assert(b.text.indexOf("甲乙").isSome(), true)
        @Assert(b.text.indexOf("戊己").isSome(), true)
        @Assert(b.text.indexOf("丙").isNone(), true)
    }

    /** 折行缓存：命中后文本再变必须失效重建（陈旧缓存会让折行按旧文本排版） */
    @TestCase
    public func testRuneArrayCacheInvalidatedOnAppend(): Unit {
        let log = ThinkingLog(1000, 32, 100000)
        log.append("甲乙丙")
        var b = log.blocksView()[0]
        @Assert(b.hasRuneCache(), false)      // 首次访问前无缓存
        @Assert(b.runeArray().size, 3)        // 访问填充缓存
        @Assert(b.hasRuneCache(), true)
        log.append("丁")
        b = log.blocksView()[0]
        @Assert(b.hasRuneCache(), false)      // 追加即失效
        @Assert(b.runeArray().size, 4)        // 重建后是新长度（陈旧缓存会得到 3）
    }

    /** 折行缓存：轮结束即释放（冻结轮只折一次，内存上界保持单轮） */
    @TestCase
    public func testRuneArrayCacheReleasedOnFinish(): Unit {
        let log = ThinkingLog(1000, 32, 100000)
        log.append("甲乙丙")
        let b = log.blocksView()[0]
        @Assert(b.runeArray().size, 3)
        @Assert(b.hasRuneCache(), true)
        log.finishCurrent()
        @Assert(b.hasRuneCache(), false)
    }

    /** 折行缓存：截断重写整串后失效（否则会按截断前的旧文本折行） */
    @TestCase
    public func testRuneArrayCacheInvalidatedOnTruncation(): Unit {
        let log = ThinkingLog(10, 32, 100000)   // 余量 = 2 → 阈值 12
        log.append("甲")
        let b = log.blocksView()[0]
        @Assert(b.runeArray().size, 1)
        @Assert(b.hasRuneCache(), true)
        log.append(this.repeatChar("乙", 20))   // 21 > 12：触发截断
        @Assert(b.hasRuneCache(), false)
        @Assert(b.runes, 10)
        // 缓存重建后与当前 text 完全一致（含省略标记行）
        @Assert(b.runeArray().size, b.text.toRuneArray().size)
    }
}
