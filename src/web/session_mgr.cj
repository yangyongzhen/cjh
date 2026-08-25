package cjh.web

/**
 * Web 会话管理器：WebSocket 连接 → Agent 实例映射
 *
 * 每个 WebSocket 连接绑定一个 Agent 实例。
 * 支持新建会话、恢复历史会话、销毁会话。
 *
 * 架构参考：docs/Web支持实现方案.md § 三、架构设计
 */

import std.collection.*
import cjh.agent.*
import cjh.tools.*
import cjllm.*
import cjcfg.*

/**
 * Web 会话管理器
 */
public class WebSessionManager {
    // WS 连接 ID → Agent 实例
    private let agents: HashMap<String, Agent> = HashMap<String, Agent>()
    // WS 连接 ID → 会话 ID（SessionStore 用）
    private let sessionIds: HashMap<String, String> = HashMap<String, String>()
    private let config: CjhConfig
    private let provider: LlmProvider
    private let registry: ToolRegistry

    public init(config: CjhConfig, provider: LlmProvider, registry: ToolRegistry) {
        this.config = config
        this.provider = provider
        this.registry = registry
    }

    /**
     * 创建新会话
     * @param wsId  WebSocket 连接 ID
     * @return 创建的 Agent 实例
     */
    public func createSession(wsId: String): Agent {
        // 预生成会话 ID
        let store = SessionStore(this.config.sessionsDir)
        let sessionId = store.newSessionId()

        let agent = this.buildAgent(sessionId)
        this.agents.add(wsId, agent)
        this.sessionIds.add(wsId, sessionId)
        return agent
    }

    /**
     * 恢复历史会话
     * @param wsId       WebSocket 连接 ID
     * @param sessionId  历史会话 ID
     * @return 恢复的 Agent 实例
     */
    public func resumeSession(wsId: String, sessionId: String): Agent {
        let agent = this.buildAgent(sessionId)

        // 加载历史消息
        let store = SessionStore(this.config.sessionsDir)
        let history = store.load(sessionId)
        if (history.size > 0) {
            agent.loadHistory(history)
        }

        this.agents.add(wsId, agent)
        this.sessionIds.add(wsId, sessionId)
        return agent
    }

    /**
     * 获取 WS 连接对应的 Agent
     */
    public func getAgent(wsId: String): ?Agent {
        return this.agents.get(wsId)
    }

    /**
     * 获取 WS 连接对应的会话 ID
     */
    public func getSessionId(wsId: String): ?String {
        return this.sessionIds.get(wsId)
    }

    /**
     * 销毁会话（WS 断开时调用）
     */
    public func destroySession(wsId: String): Unit {
        // 保存会话历史
        match (this.agents.get(wsId)) {
            case Some(agent) =>
                let store = SessionStore(this.config.sessionsDir)
                // save 会自动生成新会话 ID 并返回
                store.save(agent.history())
            case None => ()
        }

        this.agents.remove(wsId)
        this.sessionIds.remove(wsId)
    }

    /**
     * 构建 Agent 实例
     */
    private func buildAgent(sessionId: String): Agent {
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
}
