package cjh.web

import std.collection.*
import std.sync.*
import cjlog.*
import cjh.tools.*

/**
 * 后台任务状态广播器（协议 v6 `bg_task` 帧）
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

    public init() {}

    /** 登记一条新连接（握手成功后调用） */
    public func attach(wsId: String, channel: WebChannel): Unit {
        this.lock.lock()
        try {
            this.channels.add(wsId, channel)
        } finally {
            this.lock.unlock()
        }
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

    /**
     * 把任务状态事件派发给所有存活连接
     *
     * 先取快照再发送：发送期间连接可能被 detach（WsHandler 线程），
     * 持锁发送会让「广播」与「连接收尾」互相等待，甚至死锁到 WS 读循环。
     * 单连接发送失败由 WebChannel.sendWs 的 WsSendGuard 自己吞掉，不影响其他连接。
     */
    public func broadcast(info: BgTaskEventInfo): Unit {
        this.lock.lock()
        var snapshot = ArrayList<WebChannel>()
        try {
            for ((_, chan) in this.channels) {
                snapshot.add(chan)
            }
        } finally {
            this.lock.unlock()
        }
        for (chan in snapshot) {
            chan.sendBgTask(info)
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
                reg.onEvent = { info: BgTaskEventInfo => this.broadcast(info) }
            case None =>
                Log.debug("[bg] 无进程级任务表，Web 面板不订阅 bg_task 事件")
        }
    }
}
