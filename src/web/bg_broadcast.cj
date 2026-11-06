package cjh.web

import std.collection.*
import std.sync.*
import cjlog.*
import cjh.tools.*

/**
 * 后台任务状态广播器（协议 v6 `bg_task` + v7 `bg_slots` 帧）
 *
 * 为什么单独一个广播器，而不是走 ChannelGateway 的 chatId 路由：
 * 后台任务表是**进程级全局**的（槽位与 ID 全局唯一，不分会话），而 Channel 的每个方法
 * 都以 chatId 为路由键。为了一个全局面板去改 Channel 接口（及其全部实现与测试桩）
 * 是拿大接口换一个小功能；这里直接持有存活连接、向每条连接广播即可。
 *
 * 连接生命周期与 WsHandler 一致：握手成功 attach，断开 detach。
 * 摘除必须做——否则断开的连接会一直留在表里，广播时对着死 socket 发帧
 * （sendWs 有 WsSendGuard 兜底不抛，但白干活 + 泄漏引用）。
 */
public class BgTaskBroadcaster {
    private let lock: Mutex = Mutex()
    // wsId → 该连接的 Web 通道（wsId 由 WsHandler 分配，唯一且稳定）
    private var channels: HashMap<String, WebChannel> = HashMap<String, WebChannel>()
    // 槽位上限：装配期由 server 注入后只读（低频量，不参与每帧计算）
    private var bgMax: Int64 = 0
    private var agentsMax: Int64 = 0
    /**
     * agents 用量来源（v7 账）：Web 模式不建 `SubagentScheduler`，默认恒 0；
     * 将来 Web 侧接入子代理时由装配层注入真实计数。上限为 0 时客户端不渲染该段。
     */
    public var agentUsedProvider: () -> Int64 = { => 0 }

    public init() {}

    /**
     * 注入槽位上限（server 构造后立即调用一次，之后只读）
     *
     * `agentsMax = 0` 是刻意的"未启用"表达——不要传 config 里的 `max_subagents` 假装
     * 有子代理：Web 入口没有调度器，画一个永不变化的 `agents 0/4` 就是虚报。
     */
    public func setLimits(bgMax: Int64, agentsMax: Int64): Unit {
        this.bgMax = bgMax
        this.agentsMax = agentsMax
    }

    /** 登记一条新连接（握手成功后调用） */
    public func attach(wsId: String, channel: WebChannel): Unit {
        this.lock.lock()
        try {
            this.channels.add(wsId, channel)
        } finally {
            this.lock.unlock()
        }
        // 新连接先补一份当前账：否则要等下一次任务事件才看得到（重连场景最明显）
        channel.sendBgSlots(this.currentBgUsed(), this.bgMax, this.currentAgentsUsed(), this.agentsMax)
    }

    /** 摘除一条断开的连接 */
    public func detach(wsId: String): Unit {
        this.lock.lock()
        try {
            this.channels.remove(wsId)
        } finally {
            this.lock.unlock()
        }
    }

    /** 当前存活连接数（测试与排障用） */
    public func connectionCount(): Int64 {
        this.lock.lock()
        try {
            return this.channels.size
        } finally {
            this.lock.unlock()
        }
    }

    /** 运行中任务数（与 TUI 面板同一数据源：进程级任务表的运行中计数） */
    private func currentBgUsed(): Int64 {
        match (currentBackgroundRegistry()) {
            case Some(reg) => reg.runningTasks().size
            case None => 0
        }
    }

    private func currentAgentsUsed(): Int64 {
        if (this.agentsMax <= 0) {
            return 0
        }
        this.agentUsedProvider()
    }

    /**
     * 取连接快照：发送期间连接可能被 detach（WsHandler 线程），
     * 持锁发送会让「广播」与「连接收尾」互相等待，甚至死锁到 WS 读循环。
     */
    private func channelSnapshot(): ArrayList<WebChannel> {
        this.lock.lock()
        var snapshot = ArrayList<WebChannel>()
        try {
            for ((_, chan) in this.channels) {
                snapshot.add(chan)
            }
        } finally {
            this.lock.unlock()
        }
        snapshot
    }

    /**
     * 把任务状态事件派发给所有存活连接
     *
     * 单连接发送失败由 WebChannel.sendWs 的 WsSendGuard 自己吞掉，不影响其他连接。
     */
    public func broadcast(info: BgTaskEventInfo): Unit {
        let snapshot = this.channelSnapshot()
        for (chan in snapshot) {
            chan.sendBgTask(info)
        }
    }

    /**
     * 推送两本槽位账（v7 `bg_slots`）
     *
     * 只在账可能变化时调用（任务起/停、新连接握手），不要挂到每秒 tick 上：
     * 与 TUI `setSlots` 同一口径——槽位是低频量，无变化就不推。
     */
    public func pushSlots(): Unit {
        let snapshot = this.channelSnapshot()
        if (snapshot.size == 0) {
            return
        }
        let bgUsed: Int64 = this.currentBgUsed()
        let agentsUsed: Int64 = this.currentAgentsUsed()
        for (chan in snapshot) {
            chan.sendBgSlots(bgUsed, this.bgMax, agentsUsed, this.agentsMax)
        }
    }

    /**
     * 订阅进程级后台任务表
     *
     * 没有表（TUI / CLI / 一次性入口）时静默返回：那些入口没有浏览器可推，
     * 也不该为此报错或打日志。
     */
    public func subscribe(): Unit {
        match (currentBackgroundRegistry()) {
            case Some(reg) =>
                reg.onEvent = { info: BgTaskEventInfo =>
                    this.broadcast(info)
                    // 任务起/停都改变 bg 用量，账随之刷新（与 TUI 的 pushBgSlots 同口径）
                    this.pushSlots()
                }
            case None =>
                Log.debug("[bg] 无进程级任务表，Web 面板不订阅 bg_task 事件")
        }
    }
}
