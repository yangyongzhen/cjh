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
     * 结构化错误：带错误码与可重试标记
     *
     * 与 sendError 的关系：sendError 是 message-only 的旧形状（保留兼容），
     * 新代码一律走本方法，便于客户端区分「后端崩了 / 401 / 上下文超长」
     * 并决定重试还是换模型。
     */
    func sendErrorCode(chatId: String, message: String, code: String,
        retryable: Bool): Unit

    /**
     * 控制帧回执（switch_model / compact 被处理后必须回执）
     *
     * 静默是最贵的形状：客户端发了控制帧必须能确认「服务端收下了且做了什么」。
     */
    func sendAck(chatId: String, ack: AckInfo): Unit

    /**
     * 取消回执（cancel / abort）
     */
    func sendCancelled(chatId: String, info: CancelledInfo): Unit

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
 * 模型覆盖：会话级（switch_model 帧）或单次执行（chat 帧字段）
 *
 * 三字段皆可空：空 = 沿用上一层（会话级覆盖 → 当前配置）。
 */
public class ModelOverride {
    public var model: String = ""
    public var baseUrl: String = ""
    public var apiKey: String = ""

    public init() {}

    public init(model: String, baseUrl: String, apiKey: String) {
        this.model = model
        this.baseUrl = baseUrl
        this.apiKey = apiKey
    }

    /**
     * 是否为空覆盖（空覆盖 = 不改动当前 provider）
     */
    public func isEmpty(): Bool {
        return this.model.size == 0 && this.baseUrl.size == 0 && this.apiKey.size == 0
    }
}

/**
 * 模型目标：解析后的「真正生效」端点信息
 *
 * 由 ProviderFactory.resolve 产出：把「只给了 model」补齐成 model + baseUrl + apiKey，
 * 并回给客户端（ack 里带 base_url），避免客户端发了 model 却不知道打到哪个端点。
 */
public class ModelTarget {
    public var model: String = ""
    public var baseUrl: String = ""
    public var apiKey: String = ""
    // 非空 = 解析失败原因（此时不应 create provider）
    public var error: String = ""

    public init() {}

    public func ok(): Bool {
        return this.error.size == 0 && this.model.size > 0
    }
}

/**
 * Provider 工厂：把「模型名 → provider 实例」的装配知识留在装配层（根包），
 * 网关只通过本接口回调使用。
 *
 * 为什么是回调注入而不是网关直接构造：provider 选择（OpenAI/Anthropic/Ollama）
 * 与协议/环境变量/配置解析属于根包职责，网关（cjh.gateway）不能反向依赖根包，
 * 也不能把装配逻辑塞进网关——依赖方向保持单向（web/gateway ← 根包装配）。
 */
public interface ProviderFactory {
    /**
     * 解析模型目标：baseUrl/apiKey 缺省时按 model 从配置的模型列表补齐
     */
    func resolve(model: String, baseUrl: String, apiKey: String): ModelTarget

    /**
     * 按解析结果构造 provider
     */
    func create(target: ModelTarget): LlmProvider
}

/**
 * 控制帧回执信息（gateway → channel，各渠道自行转成自身协议）
 */
public class AckInfo {
    public var action: String = ""
    public var sessionId: String = ""
    public var model: String = ""
    public var baseUrl: String = ""
    public var compacted: Bool = false
    public var messagesBefore: Int64 = 0
    public var messagesAfter: Int64 = 0

    public init() {}

    public init(action: String) {
        this.action = action
    }
}

/**
 * 取消结果（gateway → channel）
 */
public class CancelledInfo {
    public var sessionId: String = ""
    public var wasRunning: Bool = false

    public init() {}

    public init(sessionId: String, wasRunning: Bool) {
        this.sessionId = sessionId
        this.wasRunning = wasRunning
    }
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
    // 会话级模型覆盖：(channelId, chatId) → ModelOverride（仅内存，不落盘）
    private let modelOverrides: HashMap<String, ModelOverride> = HashMap<String, ModelOverride>()
    // 每会话执行锁：同一会话的 run 串行，但 WS 消息循环保持可读
    // （否则 cancel / switch_model 帧要等整轮跑完才被读到，等于没有）
    private let runLocks: HashMap<String, Mutex> = HashMap<String, Mutex>()
    // 执行中标记：(channelId, chatId) → 是否有回合在跑（cancel 回执要如实报）
    private let runningTurns: HashMap<String, Bool> = HashMap<String, Bool>()
    // provider 工厂（装配层注入）；缺省 = 不支持切模型，此时明确回错而非静默
    private let providerFactory: ?ProviderFactory

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
        this.providerFactory = None
    }

    /**
     * @param providerFactory 模型覆盖用的 provider 工厂（装配层注入，可为 None）
     */
    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry,
        providerFactory: ?ProviderFactory) {
        this.config = config
        this.provider = provider
        this.registry = registry
        this.providerFactory = providerFactory
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
            case Some(channel) => this.doHandleUserMessage(channel, channelId, chatId, text, None)
            case None => ()  // 渠道未注册，忽略
        }
    }

    /**
     * 处理用户消息（带单次执行的模型覆盖）
     *
     * @param override 本回合生效的模型覆盖；None/空 = 帧未指定，
     *                 回落到会话级覆盖（switch_model）或当前配置
     */
    public func handleUserMessage(channelId: String, chatId: String, text: String,
        override: ?ModelOverride): Unit {
        match (this.channels.get(channelId)) {
            case Some(channel) => this.doHandleUserMessage(channel, channelId, chatId, text, override)
            case None => ()  // 渠道未注册，忽略
        }
    }

    /**
     * 处理 switch_model 帧：会话级切换模型
     *
     * 语义（与客户端约定一致）：
     *   - 只影响本会话后续执行，**不写 settings.json**（不是全局改配置）
     *   - base_url / api_key 可缺省：缺省时按 model 从配置模型列表补齐
     *   - 无论成功失败都回 ack / error：静默是最贵的形状
     */
    public func handleSwitchModel(channelId: String, chatId: String, model: String,
        baseUrl: String, apiKey: String): Unit {
        match (this.channels.get(channelId)) {
            case Some(ch) =>
                let key = this.sessionKey(channelId, chatId)
                match (this.providerFactory) {
                    case Some(f) =>
                        let target = f.resolve(model, baseUrl, apiKey)
                        if (!target.ok()) {
                            ch.sendErrorCode(chatId, target.error, "switch_model_failed", false)
                            return
                        }
                        // 改的是本会话 agent 的 provider；历史保留（Agent.setProvider 不动 messages）
                        let agent = this.ensureAgent(channelId, chatId)
                        agent.setProvider(f.create(target))
                        this.setModelOverride(key, ModelOverride(target.model, target.baseUrl, target.apiKey))
                        var ack = AckInfo("switch_model")
                        ack.sessionId = this.sessionIdOf(key)
                        ack.model = target.model
                        ack.baseUrl = target.baseUrl
                        ch.sendAck(chatId, ack)
                    case None =>
                        ch.sendErrorCode(chatId,
                            "服务端未注入模型工厂，无法切换模型；请改配置后重启，或在 chat 帧里直接带 model/base_url",
                            "switch_model_unsupported", false)
                }
            case None => ()
        }
    }

    /**
     * 处理 compact 帧：强制压缩历史，回 ack（含压缩前后消息数）
     *
     * 没有会话时也回 ack（compacted=false）而不是静默——客户端能据此区分「压了没压」。
     */
    public func handleCompact(channelId: String, chatId: String): Unit {
        match (this.channels.get(channelId)) {
            case Some(ch) =>
                let key = this.sessionKey(channelId, chatId)
                match (this.getAgent(channelId, chatId)) {
                    case Some(agent) =>
                        try {
                            let (did, before, after) = agent.compact(true)
                            var ack = AckInfo("compact")
                            ack.sessionId = this.sessionIdOf(key)
                            ack.compacted = did
                            ack.messagesBefore = before
                            ack.messagesAfter = after
                            ch.sendAck(chatId, ack)
                        } catch (e: Exception) {
                            ch.sendErrorCode(chatId, "压缩历史失败：${e}", "compact_failed", true)
                        }
                    case None =>
                        var ack = AckInfo("compact")
                        ack.sessionId = this.sessionIdOf(key)
                        ch.sendAck(chatId, ack)
                }
            case None => ()
        }
    }

    /**
     * 处理 cancel / abort 帧：请求中断当前执行，回 cancelled
     *
     * was_running 如实反映「这一帧到达时是否真有回合在跑」：
     * 无回合在跑时 interrupt 是空动作，但客户端仍需一条确定回执。
     */
    public func handleCancel(channelId: String, chatId: String, sessionId: String): Unit {
        match (this.channels.get(channelId)) {
            case Some(ch) =>
                let key = this.sessionKey(channelId, chatId)
                let wasRunning = this.isRunning(key)
                if (wasRunning) {
                    match (this.getAgent(channelId, chatId)) {
                        case Some(agent) => agent.interrupt()
                        case None => ()
                    }
                }
                let sid = if (sessionId.size > 0) { sessionId } else { this.sessionIdOf(key) }
                ch.sendCancelled(chatId, CancelledInfo(sid, wasRunning))
            case None => ()
        }
    }

    /**
     * 中断指定会话的执行（WS 断连时调用：连接没了就不该留孤儿回合继续跑）
     */
    public func interruptSession(channelId: String, chatId: String): Unit {
        match (this.getAgent(channelId, chatId)) {
            case Some(agent) => agent.interrupt()
            case None => ()
        }
    }

    /**
     * 内部：执行 agent.run + 事件分发
     *
     * 在独立协程里跑：agent.run 会阻塞整轮，若直接在 WS 消息循环里调用，
     * cancel / switch_model / compact 帧要等回合结束才被读到（等于失效）。
     */
    private func doHandleUserMessage(channel: Channel, channelId: String,
        chatId: String, text: String, override: ?ModelOverride): Unit {
        let key = this.sessionKey(channelId, chatId)
        let runLock = this.runLockFor(key)
        this.setRunning(key, true)
        spawn {
            runLock.lock()
            try {
                this.runTurn(channel, channelId, chatId, text, override)
            } finally {
                runLock.unlock()
                this.setRunning(key, false)
            }
        }
    }

    /**
     * 执行一个回合：挂回调 → 应用模型覆盖 → agent.run → 推 done
     *
     * 单次覆盖（chat 帧字段）用完即还原，不粘连；会话级覆盖（switch_model）常驻内存。
     */
    private func runTurn(channel: Channel, channelId: String, chatId: String,
        text: String, override: ?ModelOverride): Unit {
        let key = this.sessionKey(channelId, chatId)
        let agent = this.ensureAgent(channelId, chatId)

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

        // 模型覆盖：帧字段优先，其次会话级覆盖
        let effective = this.effectiveOverride(key, override)
        let prevProvider = agent.getProvider()
        var overridden = false
        var overrideError = ""
        match (effective) {
            case Some(ov) =>
                match (this.buildProvider(ov)) {
                    case Some(p) =>
                        agent.setProvider(p)
                        overridden = true
                    case None =>
                        let label = if (ov.model.size > 0) { ov.model } else { ov.baseUrl }
                        overrideError = "请求指定的模型不可用：${label}（模型解析失败或服务端未注入模型工厂）"
                }
            case None => ()
        }
        if (overrideError.size > 0) {
            // 不静默降级到别的模型：宁可如实报错，也不让用户以为换了模型
            channel.sendErrorCode(chatId, overrideError, "model_unavailable", false)
            return
        }

        try {
            let summary = agent.run(text)

            // 推送 DoneEvent
            var summaryObj = JsonObject()
            summaryObj.put("rounds", JsonInt(summary.rounds))
            summaryObj.put("tools", JsonInt(summary.toolCalls))
            summaryObj.put("duration_ms", JsonInt(summary.durationMs))
            summaryObj.put("tokens", JsonInt(summary.totalTokens()))
            summaryObj.put("cached", JsonInt(summary.cachedTokens))
            channel.sendDone(chatId, summaryObj)
        } catch (e: Exception) {
            channel.sendErrorCode(chatId, "执行失败：${e}", "run_failed", true)
        } finally {
            // 还原 provider：chat 帧的覆盖只对这一回合有效
            if (overridden) {
                agent.setProvider(prevProvider)
            }
        }
    }

    /**
     * 解析本回合生效的模型覆盖：帧字段非空则用之，否则会话级覆盖
     */
    private func effectiveOverride(key: String, override: ?ModelOverride): ?ModelOverride {
        match (override) {
            case Some(ov) =>
                if (!ov.isEmpty()) {
                    return Some(ov)
                }
            case None => ()
        }
        return this.getModelOverride(key)
    }

    /**
     * 取会话 Agent（不存在则新建会话）
     */
    private func ensureAgent(channelId: String, chatId: String): Agent {
        let key = this.sessionKey(channelId, chatId)
        this.mutex.lock()
        let agentOpt: ?Agent = this.agents.get(key)
        this.mutex.unlock()
        return match (agentOpt) {
            case Some(a) => a
            case None => this.createSession(channelId, chatId)
        }
    }

    /**
     * 按覆盖构造 provider（无工厂 / 解析失败 → None）
     */
    private func buildProvider(ov: ModelOverride): ?LlmProvider {
        match (this.providerFactory) {
            case Some(f) =>
                let target = f.resolve(ov.model, ov.baseUrl, ov.apiKey)
                if (!target.ok()) {
                    return None
                }
                return Some(f.create(target))
            case None => return None
        }
    }

    /**
     * 取会话 ID（无会话 → 空串）
     */
    private func sessionIdOf(key: String): String {
        this.mutex.lock()
        try {
            return this.sessionIds.get(key) ?? ""
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 取每会话执行锁（不存在则创建）
     */
    private func runLockFor(key: String): Mutex {
        this.mutex.lock()
        try {
            match (this.runLocks.get(key)) {
                case Some(m) => return m
                case None =>
                    let m = Mutex()
                    this.runLocks.add(key, m)
                    return m
            }
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 标记/清除「有回合在跑」
     */
    private func setRunning(key: String, running: Bool): Unit {
        this.mutex.lock()
        try {
            this.runningTurns.add(key, running)
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 是否有回合在跑（缺省 false）
     */
    private func isRunning(key: String): Bool {
        this.mutex.lock()
        try {
            return this.runningTurns.get(key) ?? false
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 记录会话级模型覆盖
     */
    private func setModelOverride(key: String, ov: ModelOverride): Unit {
        this.mutex.lock()
        try {
            this.modelOverrides.add(key, ov)
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 读取会话级模型覆盖
     */
    private func getModelOverride(key: String): ?ModelOverride {
        this.mutex.lock()
        try {
            return this.modelOverrides.get(key)
        } finally {
            this.mutex.unlock()
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
                let _ = this.resumeSession(channelId, chatId, sessionId)

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
     * 构建 Agent 实例
     */
    private func buildAgent(sessionId: String, _: String, _: String): Agent {
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
