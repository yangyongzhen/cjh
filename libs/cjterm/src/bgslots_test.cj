package cjterm

/**
 * BgSlots 槽位账单元测试
 *
 * 覆盖历史：这些用例原本住在 BgTaskPanelTest（底部紧凑条面板）里，与面板的
 * 渲染/淡出/签名用例混在一起。面板退役后（后台任务改走会话流条目），账本身
 * 仍然显示在状态行心跳，于是用例随账一起搬到这里，只留纯函数契约。
 */

@Test
public class BgSlotsTest {

    @TestCase
    public func testFmtSlotLedger(): Unit {
        @Assert(fmtSlotLedger(3, 8, 2, 4), "bg 3/8  agents 2/4")
        // 上限 <= 0 = 不限（settings 四键 0 的语义）：只写用量
        @Assert(fmtSlotLedger(3, 0, 2, 0), "bg 3  agents 2")
        // 子代理未启用（上限 0 且用量 0）：整段省略，不留恒为 0 的尾巴
        @Assert(fmtSlotLedger(1, 8, 0, 0), "bg 1/8")
        @Assert(fmtSlotLedger(0, 8, 0, 4), "bg 0/8  agents 0/4")
    }

    @TestCase
    public func testFmtAgentLedger(): Unit {
        // 回合总结条用："N/4 agents (x✓ y✗)"——上限可见才知道 4 是天花板
        @Assert(fmtAgentLedger(3, 4), "3/4 agents")
        // 上限 <= 0 = 不限：只写用量
        @Assert(fmtAgentLedger(3, 0), "3 agents")
        @Assert(fmtAgentLedger(2, -1), "2 agents")
    }

    @TestCase
    public func testSameAs(): Unit {
        // sameAs 是"要不要 markDirty"的判据：同值必须相等，任一字段变都要不等
        @Assert(BgSlots(1, 8, 0, 4).sameAs(BgSlots(1, 8, 0, 4)), true)
        @Assert(BgSlots(1, 8, 0, 4).sameAs(BgSlots(2, 8, 0, 4)), false)
        @Assert(BgSlots(1, 8, 0, 4).sameAs(BgSlots(1, 8, 1, 4)), false)
        @Assert(BgSlots(1, 8, 0, 4).sameAs(BgSlots(1, 4, 0, 4)), false)
        @Assert(BgSlots(1, 8, 0, 4).sameAs(BgSlots(1, 8, 0, 2)), false)
    }
}
