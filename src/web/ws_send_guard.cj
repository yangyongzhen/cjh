package cjh.web

/**
 * WebSocket 发送守护
 *
 * **现象**（灵渠迁移台 0.39.7 端到端实测，`m3u8dl-tauri` 全自动迁移）：
 * 客户端（WebView）重连了两次后，cjh 仍往**旧连接**写帧，抛
 *
 * ```
 * SocketException: Failed to write data 10053: An established connection was aborted …
 *   at web_channel.cj:142 ← Agent.run 顶层异常
 * ```
 *
 * 结果是**整轮 agent run 直接结束**：那条正在跑的 build 工具的 `tool_result`
 * 永久丢失，页面永远停在 `tool_start:24 / tool_result:23`，落档监管随后报"AI 在绕圈"。
 * 一次网络抖动就把整轮迁移打水漂，这个代价完全不该付。
 *
 * **处置**：单帧写失败不再抛穿调用栈——记一次日志、把连接判死，后续帧直接跳过；
 * agent 照常把这一轮跑完（结果仍落会话文件 / `.lingqu/` 落档），客户端重连后靠
 * `history_messages` 补看。这里只放**可单测的纯状态机**，真正的 socket 写仍在
 * `WebChannel.sendWs` 里（socket 行为不在单测里模拟，见 AGENTS 门禁第 5 条）。
 */
public class WsSendGuard {
    private var dead: Bool = false
    private var sent: Int64 = 0
    private var failed: Int64 = 0
    private var firstError: String = ""

    public init() {}

    /** 还值不值得尝试写：连接一旦判死就直接跳过，避免每一帧都抛一次异常 */
    public func allowsSend(): Bool {
        return !this.dead
    }

    /** 记一次成功发送 */
    public func onSent(): Unit {
        this.sent += 1
    }

    /**
     * 记一次写失败，并把连接判死。
     *
     * @return true 表示这是**第一次**失败（调用方据此只打一条日志，别刷屏）
     */
    public func onFailed(err: String): Bool {
        this.failed += 1
        this.dead = true
        if (this.firstError.size == 0) {
            this.firstError = err
            return true
        }
        return false
    }

    public func isDead(): Bool { return this.dead }

    public func sentCount(): Int64 { return this.sent }

    public func failedCount(): Int64 { return this.failed }

    public func errorText(): String { return this.firstError }

    /** 一句话诊断摘要（日志 / 排障用） */
    public func summary(): String {
        var err = ""
        if (this.firstError.size > 0) {
            err = " err=" + this.firstError
        }
        return "ws sent=${this.sent} failed=${this.failed} dead=${this.dead}${err}"
    }
}
