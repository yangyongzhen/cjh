package cjh.gateway

/**
 * V2e IM 网关：Channel 抽象 + Web 渠道
 *
 * 设计目标（docs/方案与架构设计-v2.md § Channel 接口）：
 *   - 一套 agent 逻辑，多端触达：TUI/Web/IM 都是 Channel，agent 核心零改动
 *   - 远程协同：审批、通知、会话管理全部可远程
 *   - 与插件系统协同：渠道本身可以是插件（注册 Channel 实现），核心网关内置
 *
 * 架构：
 *   ┌─────────────────────────────────────────┐
 *   │              ChannelGateway              │
 *   │  (会话路由 + Agent 生命周期 + 事件分发)   │
 *   └──────┬─────────┬─────────┬──────────────┘
 *          │         │         │
 *      ┌───▼──┐ ┌───▼──┐ ┌───▼──┐
 *      │ TUI  │ │ Web  │ │ IM   │  ← Channel 适配器（可插拔）
 *      └──────┘ └──────┘ └──────┘
 *
 * Channel 接口（最小契约）：
 *   - sendDelta(chatId, text)         LLM 增量输出
 *   - sendToolStart(chatId, name, args)  工具调用开始
 *   - sendToolResult(chatId, name, result, isError)  工具调用结果
 *   - sendDone(chatId, summary)       回合结束
 *   - sendError(chatId, message)      错误
 *   - sendHistory(chatId, messages)   历史消息（切换会话）
 *
 * ChannelGateway 负责：
 *   - chatId → Agent 映射（会话隔离）
 *   - Agent 回调 → Channel 事件分发
 *   - 会话持久化（SessionStore）
 *   - 新建/恢复/销毁会话
 */

import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*
import cjllm.*
import cjcfg.*
import cjh.agent.*
import cjh.tools.*

/**
 * Channel 接口：抽象一个消息渠道（Web/IM/TUI）
 *
 * 每个渠道实现此接口，ChannelGateway 通过它推送事件。
 * 渠道负责把事件转换为自身协议（WebSocket 帧 / IM 消息卡片 / TUI 渲染）。
 */
public interface Channel {
    /**
     * 渠道标识（如 "web" / "im" / "tui"）
     */
    func channelId(): String

    /**
     * LLM 增量输出
     */
    func sendDelta(chatId: String, text: String): Unit

    /**
     * 工具调用开始
     * args: 工具参数 JsonObject
     */
    func sendToolStart(chatId: String, name: String, args: JsonObject): Unit

    /**
     * 工具调用结果
     */
    func sendToolResult(chatId: String, name: String, result: String, isError: Bool): Unit

    /**
     * 回合结束（summary 包含轮数/工具数/耗时/token 用量）
     */
    func sendDone(chatId: String, summary: JsonObject): Unit

    /**
     * 错误
     */
    func sendError(chatId: String, message: String): Unit

    /**
     * 历史消息（切换会话时推送）
     * messages: [{role, content, tool_call_id?, name?}, ...]
     */
    func sendHistory(chatId: String, sessionId: String, messages: JsonArray): Unit

    /**
     * 任务列表更新
     */
    func sendTasks(chatId: String, tasks: JsonArray): Unit
}

/**
 * ChannelGateway：渠道网关
 *
 * 职责：
 *   1. 会话路由：chatId → Agent 映射（每个 chatId 独立 agent 会话）
 *   2. Agent 生命周期：新建/恢复/销毁会话
 *   3. 事件分发：Agent 回调 → Channel.sendXxx
 *   4. 会话持久化：SessionStore save/load
 *
 * 用法：
 *   let gateway = ChannelGateway(config, provider, registry)
 *   let webChannel = WebChannel(wsHandler)
 *   gateway.registerChannel("web", webChannel)
 *   gateway.handleUserMessage("web", chatId, "你好")  // → agent.run + 事件推送
 */
public class ChannelGateway {
    private let config: CjhConfig
    private let provider: LlmProvider
    private let registry: ToolRegistry

    // 渠道注册表：channelId → Channel
    private let channels: HashMap<String, Channel> = HashMap<String, Channel>()

    // 会话映射：(channelId, chatId) → Agent
    private let agents: HashMap<String, Agent> = HashMap<String, Agent>()
    // 会话 ID 映射：(channelId, chatId) → sessionId
    private let sessionIds: HashMap<String, String> = HashMap<String, String>()
    // Agent 锁（保护 agents/sessionIds 并发访问）
    private let mutex: Mutex = Mutex()

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
    }

    /**
     * 注册渠道
     */
    public func registerChannel(channelId: String, channel: Channel): Unit {
        this.channels.add(channelId, channel)
    }

    /**
     * 注销渠道（断开时清理）
     */
    public func unregisterChannel(channelId: String): Unit {
        this.channels.remove(channelId)
    }

    /**
     * 创建新会话
     * @param channelId  渠道标识（"web" / "im"）
     * @param chatId     渠道内会话标识（WS 连接 ID / IM 群 ID）
     * @return 创建的 Agent 实例
     */
    public func createSession(channelId: String, chatId: String): Agent {
        let key = this.sessionKey(channelId, chatId)
        let store = SessionStore(this.config.sessionsDir)
        let sessionId = store.newSessionId()

        let agent = this.buildAgent(sessionId, channelId, chatId)
        this.mutex.lock()
        try {
            this.agents.add(key, agent)
            this.sessionIds.add(key, sessionId)
        } finally {
            this.mutex.unlock()
        }
        return agent
    }

    /**
     * 恢复历史会话
     * @param channelId  渠道标识
     * @param chatId     渠道内会话标识
     * @param sessionId  历史会话 ID
     * @return 恢复的 Agent 实例
     */
    public func resumeSession(channelId: String, chatId: String, sessionId: String): Agent {
        let key = this.sessionKey(channelId, chatId)
        let agent = this.buildAgent(sessionId, channelId, chatId)

        // 加载历史消息
        let store = SessionStore(this.config.sessionsDir)
        let history = store.load(sessionId)
        if (history.size > 0) {
            agent.loadHistory(history)
        }

        this.mutex.lock()
        try {
            this.agents.add(key, agent)
            this.sessionIds.add(key, sessionId)
        } finally {
            this.mutex.unlock()
        }
        return agent
    }

    /**
     * 获取会话对应的 Agent
     */
    public func getAgent(channelId: String, chatId: String): ?Agent {
        let key = this.sessionKey(channelId, chatId)
        this.mutex.lock()
        try {
            return this.agents.get(key)
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 销毁会话（渠道断开时调用）
     */
    public func destroySession(channelId: String, chatId: String): Unit {
        let key = this.sessionKey(channelId, chatId)
        this.mutex.lock()
        try {
            // 保存会话历史
            match (this.agents.get(key)) {
                case Some(agent) =>
                    let store = SessionStore(this.config.sessionsDir)
                    store.save(agent.history())
                case None => ()
            }
            this.agents.remove(key)
            this.sessionIds.remove(key)
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 处理用户消息：调 agent.run，Agent 回调 → Channel 事件推送
     *
     * 这是渠道网关的核心方法：所有渠道（Web/IM）收到用户消息后，
     * 统一调此方法，由网关负责 agent 执行 + 事件分发。
     *
     * @param channelId  渠道标识
     * @param chatId     渠道内会话标识
     * @param text       用户消息文本
     */
    public func handleUserMessage(channelId: String, chatId: String, text: String): Unit {
        // 获取渠道
        match (this.channels.get(channelId)) {
            case Some(channel) => this.doHandleUserMessage(channel, channelId, chatId, text)
            case None => ()  // 渠道未注册，忽略
        }
    }

    /**
     * 处理 resume_session：加载历史消息推回渠道
     */
    public func handleResumeSession(channelId: String, chatId: String, sessionId: String): Unit {
        match (this.channels.get(channelId)) {
            case Some(channel) =>
                // 销毁当前会话，恢复历史会话
                this.destroySession(channelId, chatId)
                let agent = this.resumeSession(channelId, chatId, sessionId)

                // 加载历史消息
                let store = SessionStore(this.config.sessionsDir)
                let messages = store.load(sessionId)

                // 序列化为 JsonArray
                var msgArr = JsonArray()
                for (i in 0..messages.size) {
                    let m = messages[i]
                    var msgObj = JsonObject()
                    msgObj.put("role", JsonString(m.role))
                    msgObj.put("content", JsonString(m.content))
                    if (m.toolCallId.size > 0) {
                        msgObj.put("tool_call_id", JsonString(m.toolCallId))
                    }
                    if (m.name.size > 0) {
                        msgObj.put("name", JsonString(m.name))
                    }
                    msgArr.add(msgObj)
                }

                channel.sendHistory(chatId, sessionId, msgArr)
            case None => ()
        }
    }

    /**
     * 推送任务列表
     */
    public func handleTasksUpdate(channelId: String, chatId: String, tasks: JsonArray): Unit {
        match (this.channels.get(channelId)) {
            case Some(channel) => channel.sendTasks(chatId, tasks)
            case None => ()
        }
    }

    /**
     * 内部：执行 agent.run + 事件分发
     */
    private func doHandleUserMessage(channel: Channel, channelId: String,
        chatId: String, text: String): Unit {
        let key = this.sessionKey(channelId, chatId)

        // 获取或创建 Agent
        this.mutex.lock()
        let agentOpt: ?Agent = this.agents.get(key)
        this.mutex.unlock()

        let agent = match (agentOpt) {
            case Some(a) => a
            case None => this.createSession(channelId, chatId)
        }

        // 挂接 Agent 回调 → Channel 事件分发
        agent.onDelta = { delta: String =>
            channel.sendDelta(chatId, delta)
        }
        agent.onToolStart = { name: String, args: JsonObject =>
            channel.sendToolStart(chatId, name, args)
        }
        agent.onToolResult = { name: String, result: ToolResult =>
            channel.sendToolResult(chatId, name, result.content, result.isError)
        }

        // 执行 Agent 循环
        let summary = agent.run(text)

        // 推送 DoneEvent
        var summaryObj = JsonObject()
        summaryObj.put("rounds", JsonInt(summary.rounds))
        summaryObj.put("tools", JsonInt(summary.toolCalls))
        summaryObj.put("duration_ms", JsonInt(summary.durationMs))
        summaryObj.put("tokens", JsonInt(summary.totalTokens()))
        summaryObj.put("cached", JsonInt(summary.cachedTokens))
        channel.sendDone(chatId, summaryObj)
    }

    /**
     * 构建 Agent 实例
     */
    private func buildAgent(sessionId: String, channelId: String, chatId: String): Agent {
        let agentConfig = AgentConfig(
            this.config.systemPrompt,
            this.config.maxIterations,
            this.config.capability,
            this.config.compactThreshold,
            this.config.compactKeep,
            this.config.toolResultMaxChars,
            this.config.spillDir,
            sessionId
        )

        let agent = Agent(this.provider, this.registry, agentConfig)
        return agent
    }

    /**
     * 生成会话映射 key
     */
    private func sessionKey(channelId: String, chatId: String): String {
        return channelId + ":" + chatId
    }
}
