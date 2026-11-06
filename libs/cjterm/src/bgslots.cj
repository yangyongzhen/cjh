package cjterm

/**
 * 后台任务与子代理的槽位账
 *
 * 历史沿革：这两本账原本住在 BgTaskPanel（底部紧凑条）里，随面板一起画。
 * 面板退役后（后台任务改为**会话流条目**呈现——启动/轮询/终态都落进消息流，
 * 不必再在屏幕底部占行），账本身仍然有用，于是抽成独立的最小单元留在状态行心跳。
 *
 * 为什么要显示账：两个上限分属不同配置键（`max_background_tasks` 默认 8 /
 * `max_subagents` 默认 4）。用户撞到"后台起不动"时，只有账在眼前才分得清
 * 是哪一本满了——否则只会看到一句"槽位已满"，然后去猜是哪个配置。
 */
public class BgSlots {
    public let bgUsed: Int64
    public let bgMax: Int64
    public let agentsUsed: Int64
    public let agentsMax: Int64

    public init(bgUsed: Int64, bgMax: Int64, agentsUsed: Int64, agentsMax: Int64) {
        this.bgUsed = bgUsed
        this.bgMax = bgMax
        this.agentsUsed = agentsUsed
        this.agentsMax = agentsMax
    }

    public func sameAs(o: BgSlots): Bool {
        return this.bgUsed == o.bgUsed && this.bgMax == o.bgMax &&
            this.agentsUsed == o.agentsUsed && this.agentsMax == o.agentsMax
    }
}

/** 账上"用量/上限"；上限 <= 0 表示不限（settings 四键 0 的语义），只显示用量 */
private func slotPair(used: Int64, max: Int64): String {
    if (max <= 0) {
        return "${used}"
    }
    return "${used}/${max}"
}

/**
 * 两本账文本：`bg 3/8  agents 2/4`
 *
 * 子代理未启用（上限 0 且用量 0）时省略该段——否则每一帧都挂一个恒为
 * `agents 0` 的尾巴，白占列宽。
 */
public func fmtSlotLedger(bgUsed: Int64, bgMax: Int64, agentsUsed: Int64, agentsMax: Int64): String {
    let bgPart: String = "bg " + slotPair(bgUsed, bgMax)
    if (agentsMax <= 0 && agentsUsed == 0) {
        return bgPart
    }
    return bgPart + "  agents " + slotPair(agentsUsed, agentsMax)
}

/**
 * 子代理归账文本：`3/4 agents`；上限 <= 0（不限）只写用量
 *
 * 与 fmtSlotLedger 的 agents 段同一口径，差别是这里带单位——回合总结条以
 * "N/4 agents (x✓ y✗)" 出现，让用户知道 4 是天花板而不是随机数。
 */
public func fmtAgentLedger(total: Int64, max: Int64): String {
    if (max <= 0) {
        return "${total} agents"
    }
    return "${total}/${max} agents"
}
