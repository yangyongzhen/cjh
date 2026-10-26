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
 *   - sendToolResult(chatId, name, result, isError, diff)  工具调用结果（文件改动带结构化 diff）
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
     * meta: 帧身份（session_id/turn_id/message_id），渠道自行决定如何呈现
     */
    func sendDelta(chatId: String, meta: FrameMeta, text: String): Unit

    /**
     * 工具调用开始
     * args: 工具参数 JsonObject
     */
    func sendToolStart(chatId: String, meta: FrameMeta, name: String, args: JsonObject): Unit

    /**
     * 工具调用结果
     *
     * diff：文件改动类工具携带的结构化 diff（{path, unified_diff, before_sha, after_sha}），
     * 渠道可据此让客户端渲染 diff 视图；无改动 / 非文件工具为 None。
     */
    func sendToolResult(chatId: String, meta: FrameMeta, name: String, result: String,
        isError: Bool, diff: ?DiffInfo): Unit

    /**
     * 回合结束（summary 包含轮数/工具数/耗时/token 用量/finish_reason）
     */
    func sendDone(chatId: String, meta: FrameMeta, summary: JsonObject): Unit

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
     *
     * meta 为空身份（FrameMeta.isEmpty）= 与回合无关的错误（如帧格式错误）；
     * 回合内错误必须带身份，客户端才能把它归到具体回合。
     */
    func sendErrorCode(chatId: String, meta: FrameMeta, message: String, code: String,
        retryable: Bool): Unit

    /**
     * 审批类错误：带 request_id，客户端按 id 精确关掉对应审批项
     * （approval_timeout / approval_unknown；队列里其余可答复项不受牵连）
     */
    func sendApprovalError(chatId: String, requestId: String, message: String, code: String): Unit

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

    /**
     * 审批请求（危险操作需人工确认）
     *
     * 网关在回合内阻塞等待答复（客户端把 request_id 原样回传）；
     * 超时 / 断连 / 取消一律按拒绝收场，回合继续跑而不是挂死。
     */
    func sendApprovalRequest(chatId: String, info: ApprovalRequestInfo): Unit
}

/**
 * 审批请求描述（sendApprovalRequest 的载体）
 *
 * 做成一个类而不是给 Channel 加一串参数：与 AckInfo / CancelledInfo 同形，
 * 渠道实现只管把它翻译成自己的协议形状（WS 帧 / IM 卡片 / TUI 对话框）。
 */
public class ApprovalRequestInfo {
    public var requestId: String = ""
    public var toolName: String = ""
    public var reason: String = ""
    public var args: JsonObject = JsonObject()
    public var meta: FrameMeta = FrameMeta()
    public var expiresInMs: Int64 = 300000

    public init() {}

    public init(requestId: String, toolName: String, args: JsonObject, reason: String) {
        this.requestId = requestId
        this.toolName = toolName
        this.args = args
        this.reason = reason
    }
}

/**
 * 审批槽位：回合线程等待、响应线程写回的共享位置
 *
 * 用「锁保护的普通字段 + 轮询」而不是条件变量：人工审批的时间尺度（秒级）里，
 * 50ms 轮询完全够用，且不会踩唤醒丢失一类的坑；锁保护保证跨线程可见性。
 * 附带归属信息（channelId / chatId）是为了断连或取消时能批量按拒绝收场——
 * 否则用户已经走了，回合还要空等满 5 分钟才收场。
 */
public class ApprovalSlot {
    public var decided: Bool = false
    public var approved: Bool = false
    public var channelId: String = ""
    public var chatId: String = ""

    public init() {}
}

/**
 * 帧身份：回合级事件的公共元数据（session_id / turn_id / message_id）
 *
 * 为什么需要 id：客户端要能把 delta / tool_start / tool_result / done 归并到
 * 同一回合。没有 id 时，「重连后收到的一串帧属于哪一回合」「两条消息是不是
 * 同一条」只能靠猜——有了 id 才能去重、幂等与断点续接。
 *
 * 约定：
 *   - session_id：会话标识（等同 resume_session 用的 session_id）
 *   - turn_id：一次 chat 帧触发的整轮执行；重试 = 新 turn_id
 *   - message_id：本回合的助手消息 id，回合内恒定（客户端按它聚合成一条消息）
 */
public class FrameMeta {
    public var sessionId: String = ""
    public var turnId: String = ""
    public var messageId: String = ""

    public init() {}

    public init(sessionId: String, turnId: String, messageId: String) {
        this.sessionId = sessionId
        this.turnId = turnId
        this.messageId = messageId
    }

    /**
     * 是否携带了身份（空身份用于"非回合级"事件，如帧解析错误）
     */
    public func isEmpty(): Bool {
        return this.sessionId.size == 0 && this.turnId.size == 0 && this.messageId.size == 0
    }
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
    // 回合序号：生成 turn_id / message_id（进程内自增，唯一）
    private var turnSeq: Int64 = 0
    // 被中断的会话 key：cancel/断连时置位，回合收尾读取并清除（→ finish_reason=cancelled）
    private let cancelledKeys: HashMap<String, Bool> = HashMap<String, Bool>()
    // 未决审批：requestId → 槽位（回合线程阻塞读，approval_response / 超时 / 断连写）
    private let pendingApprovals: HashMap<String, ApprovalSlot> = HashMap<String, ApprovalSlot>()
    // 审批请求序号（requestId 进程内唯一）
    private var approvalSeq: Int64 = 0
    /**
     * 审批等待上限（毫秒）：超时按拒绝收场，避免回合永久挂住
     *
     * 默认 5 分钟——够用户离开一下回来点，又不至于让回合永远醒不过来。
     * TUI 那条链是无期限等待（人在终端前），Web 这条必须有上限（人可能不在）。
     */
    public var approvalTimeoutMs: Int64 = 300000
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
        // 渠道没了就没有人能答复审批：全部按拒绝收场，免得回合空等超时
        this.denyApprovals(channelId, "")
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
        // 会话都要没了：等审批的回合立刻按拒绝收场（不留悬空等待）
        this.denyApprovals(channelId, chatId)
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
                            ch.sendErrorCode(chatId, FrameMeta(this.sessionIdOf(key), "", ""),
                                target.error, "switch_model_failed", false)
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
                        // 与回合无关的错误：只带 session_id，不带回合身份
                        ch.sendErrorCode(chatId, FrameMeta(this.sessionIdOf(key), "", ""),
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
                            ch.sendErrorCode(chatId, FrameMeta(this.sessionIdOf(key), "", ""),
                                "压缩历史失败：${e}", "compact_failed", true)
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
                    // 先标记再 interrupt：回合收尾据此把 finish_reason 报成 cancelled
                    this.markCancelled(key)
                    // 正在等审批的回合要立刻醒：用户已经说"停"了，别再等满超时
                    this.denyApprovals(channelId, chatId)
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
     * 处理 approval_response 帧：把结果写回等待中的审批槽位
     *
     * 三种情况都必须有回音（静默是最贵的形状）：
     *   - request_id 为空 → error(approval_bad_request)
     *   - 无对应未决请求（未知 / 已超时 / 已答复）→ error(approval_unknown)
     *   - 命中 → 写回即收场；不额外回帧，随后的工具结果就是回执
     */
    public func handleApprovalResponse(channelId: String, chatId: String,
        requestId: String, approved: Bool): Unit {
        match (this.channels.get(channelId)) {
            case Some(ch) =>
                if (requestId.size == 0) {
                    ch.sendErrorCode(chatId, FrameMeta(), "审批响应缺少 request_id",
                        "approval_bad_request", false)
                    return
                }
                if (!this.decideApproval(requestId, approved)) {
                    ch.sendApprovalError(chatId, requestId,
                        "审批请求不存在或已结束：${requestId}（可能已超时 / 已答复 / 回合已中断）",
                        "approval_unknown")
                }
            case None => ()
        }
    }

    /**
     * 写回审批结果（返回 true=有未决槽位；false=未知或已结束）
     */
    private func decideApproval(requestId: String, approved: Bool): Bool {
        this.mutex.lock()
        try {
            match (this.pendingApprovals.get(requestId)) {
                case Some(slot) =>
                    slot.approved = approved
                    slot.decided = true
                    return true
                case None => return false
            }
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 把未决审批按「拒绝」收场
     *
     * @param chatId 空串 = 该渠道下全部会话（断连 / 渠道注销）；否则只清该会话
     *
     * 不做这一步，用户取消或断开后回合仍会卡在审批等待里直到超时。
     * 先收集 id 再逐个写回：不在持锁时改动被遍历的 map。
     */
    private func denyApprovals(channelId: String, chatId: String): Unit {
        let ids = ArrayList<String>()
        this.mutex.lock()
        try {
            for ((id, slot) in this.pendingApprovals) {
                if (slot.channelId != channelId) {
                    continue
                }
                if (chatId.size > 0 && slot.chatId != chatId) {
                    continue
                }
                if (!slot.decided) {
                    ids.add(id)
                }
            }
        } finally {
            this.mutex.unlock()
        }
        for (i in 0..ids.size) {
            this.decideApproval(ids[i], false)
        }
    }

    /**
     * 中断指定会话的执行（WS 断连时调用：连接没了就不该留孤儿回合继续跑）
     */
    public func interruptSession(channelId: String, chatId: String): Unit {
        let key = this.sessionKey(channelId, chatId)
        if (this.isRunning(key)) {
            // 连接已断：本轮按 cancelled 收尾（不是故障，是用户那头没了）
            this.markCancelled(key)
        }
        // 连接没了：等审批的回合立刻按拒绝收场（否则要空等到超时）
        this.denyApprovals(channelId, chatId)
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
     * 回合内请求人工审批：发帧 → 阻塞等答复（超时 / 断连 / 取消一律按拒绝）
     *
     * 返回 true=同意执行。本方法跑在回合协程里（不是 WS 读循环），所以阻塞是安全的：
     * 读循环仍在读帧，approval_response 才收得到——这也是回合必须 spawn 的原因之一。
     */
    private func requestApproval(channel: Channel, channelId: String, chatId: String,
        meta: FrameMeta, toolName: String, args: JsonObject, reason: String): Bool {
        let requestId = this.nextApprovalId(meta)
        let slot = ApprovalSlot()
        slot.channelId = channelId
        slot.chatId = chatId
        // 先登记再发帧：客户端答得再快也不会撞上「还没登记」
        this.mutex.lock()
        try {
            this.pendingApprovals.add(requestId, slot)
        } finally {
            this.mutex.unlock()
        }

        let info = ApprovalRequestInfo(requestId, toolName, args, reason)
        info.meta = meta
        info.expiresInMs = this.approvalTimeoutMs
        channel.sendApprovalRequest(chatId, info)

        var approved = false
        var decided = false
        var elapsed: Int64 = 0
        while (elapsed < this.approvalTimeoutMs && !decided) {
            match (this.approvalState(requestId)) {
                case Some(v) =>
                    approved = v
                    decided = true
                case None =>
                    sleep(Duration.millisecond * 50)
                    elapsed += 50
            }
        }
        // 真的超时（不是被答复）才报超时；无论如何都摘掉槽位，不留永不清理的登记
        let timedOut = !decided
        this.removeApproval(requestId)
        if (timedOut) {
            // 超时不静默：告诉客户端"这次没人批"，随后工具返回拒绝结果，回合继续。
            // 带 request_id：并发审批队列下客户端按 id 关掉对应项，不错杀其余可答复项
            channel.sendApprovalError(chatId, requestId,
                "操作审批超时（${this.approvalTimeoutMs}ms 未确认），已按拒绝处理",
                "approval_timeout")
        }
        return approved
    }

    /**
     * 生成审批请求 id：与回合身份同源，客户端可据此把请求归到具体回合
     */
    private func nextApprovalId(meta: FrameMeta): String {
        this.mutex.lock()
        var seq: Int64 = 0
        try {
            this.approvalSeq += 1
            seq = this.approvalSeq
        } finally {
            this.mutex.unlock()
        }
        let base = if (meta.turnId.size > 0) { meta.turnId } else { meta.sessionId }
        return "${base}#a${seq}"
    }

    /**
     * 读审批状态：Some(true)=同意，Some(false)=拒绝，None=仍未决（或已摘除）
     */
    private func approvalState(requestId: String): ?Bool {
        this.mutex.lock()
        try {
            match (this.pendingApprovals.get(requestId)) {
                case Some(slot) =>
                    if (slot.decided) {
                        return Some(slot.approved)
                    }
                    return None
                case None => return None
            }
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 摘除审批槽位（答复/超时收场后调用）
     */
    private func removeApproval(requestId: String): Unit {
        this.mutex.lock()
        try {
            this.pendingApprovals.remove(requestId)
        } finally {
            this.mutex.unlock()
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
        // 回合身份：本回合所有事件（delta/tool_start/tool_result/error/done）共用同一组 id
        let meta = this.newFrameMeta(key)

        // 挂接 Agent 回调 → Channel 事件分发
        agent.onDelta = { delta: String =>
            channel.sendDelta(chatId, meta, delta)
        }
        agent.onToolStart = { name: String, args: JsonObject =>
            channel.sendToolStart(chatId, meta, name, args)
        }
        agent.onToolResult = { name: String, result: ToolResult =>
            channel.sendToolResult(chatId, meta, name, result.content, result.isError, result.diff)
        }
        // 审批链：危险操作经渠道请人工确认（阻塞本回合，不阻塞 WS 读循环）
        agent.onApproval = { name: String, args: JsonObject, reason: String =>
            this.requestApproval(channel, channelId, chatId, meta, name, args, reason)
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
            channel.sendErrorCode(chatId, meta, overrideError, "model_unavailable", false)
            // done 照发：客户端只认「done = 本回合结束」，不必在 error 分支里自己收尾
            this.sendDone(channel, chatId, meta, RunSummary(), "error")
            return
        }

        try {
            let summary = agent.run(text)

            // 上游失败不静默：agent 已在 summary 上留下结构化失败信号 → 先推 error 帧，再收尾。
            // 顺序要紧：先算 finish_reason（它会取走 cancelled 标记）——用户按停止引发的异常
            // 不是故障，此时 reason=cancelled，不当故障报。
            let hadError = summary.errorCode.size > 0
            let reason = this.finishReasonOf(key, hadError)
            if (reason == "error") {
                channel.sendErrorCode(chatId, meta, summary.errorMessage, summary.errorCode,
                    summary.errorRetryable)
            }
            // 推送 DoneEvent（三条终局路径形状一致）
            this.sendDone(channel, chatId, meta, summary, reason)
        } catch (e: Exception) {
            channel.sendErrorCode(chatId, meta, "执行失败：${e}", "run_failed", true)
            // 异常也发 done：三条终局路径（stop/cancelled/error）形状一致
            this.sendDone(channel, chatId, meta, RunSummary(), this.finishReasonOf(key, true))
        } finally {
            // 还原 provider：chat 帧的覆盖只对这一回合有效
            if (overridden) {
                agent.setProvider(prevProvider)
            }
        }
    }

    /**
     * 生成回合身份：turn_id / message_id 自增，带会话前缀
     *
     * 形如 s1787665309.605#t3 / s1787665309.605#m3：可读、可排序、进程内唯一。
     * turn 与 message 目前 1:1（一次 chat 帧 = 一轮执行 + 一条助手消息），
     * 分开命名是给「一个回合产出多条消息」留位。
     */
    private func newFrameMeta(key: String): FrameMeta {
        // 先取 sessionId（sessionIdOf 内部自行加锁，避免锁中再取锁）
        let sid = this.sessionIdOf(key)
        this.mutex.lock()
        var seq: Int64 = 0
        try {
            this.turnSeq += 1
            seq = this.turnSeq
        } finally {
            this.mutex.unlock()
        }
        return FrameMeta(sid, "${sid}#t${seq}", "${sid}#m${seq}")
    }

    /**
     * 标记会话被中断（cancel 帧 / WS 断连）
     */
    private func markCancelled(key: String): Unit {
        this.mutex.lock()
        try {
            this.cancelledKeys.add(key, true)
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 读取并清除中断标记（回合收尾调用一次）
     */
    private func takeCancelled(key: String): Bool {
        this.mutex.lock()
        try {
            let hit = match (this.cancelledKeys.get(key)) {
                case Some(v) => v
                case None => false
            }
            if (hit) {
                this.cancelledKeys.remove(key)
            }
            return hit
        } finally {
            this.mutex.unlock()
        }
    }

    /**
     * 回合结束原因：cancelled > error > stop
     *
     * 中断优先于异常：用户按停止导致的中断也可能抛异常，
     * 此时「被取消」才是真故事，报 error 会把用户的主动操作说成故障。
     */
    private func finishReasonOf(key: String, hadError: Bool): String {
        if (this.takeCancelled(key)) {
            return "cancelled"
        }
        return if (hadError) { "error" } else { "stop" }
    }

    /**
     * 发送 done（回合终帧）
     *
     * 契约：done 是本回合结束的**唯一**信号——stop / cancelled / error 三条路径都发。
     * 客户端据此统一收尾（复位执行态、关闭流式块），不必在 error 分支里再写一遍。
     */
    private func sendDone(channel: Channel, chatId: String, meta: FrameMeta,
        summary: RunSummary, finishReason: String): Unit {
        var obj = JsonObject()
        obj.put("rounds", JsonInt(summary.rounds))
        obj.put("tools", JsonInt(summary.toolCalls))
        obj.put("duration_ms", JsonInt(summary.durationMs))
        obj.put("tokens", JsonInt(summary.totalTokens()))
        obj.put("cached", JsonInt(summary.cachedTokens))
        obj.put("finish_reason", JsonString(finishReason))
        // 截断信号（可选键）：只在确实被 max_tokens 截断时出现——老客户端忽略未知键即可。
        // 刻意不新增 finish_reason 取值：三值封闭，加第四个取值是破坏性扩展。
        if (summary.truncated) {
            obj.put("truncated", JsonBool(true))
        }
        channel.sendDone(chatId, meta, obj)
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
