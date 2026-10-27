package cjh.agent

import std.sync.*
import std.collection.*

/** 子代理墙钟超时（S4）：spawnSubagent 捕获后映射 status=timeout（T2 教训：不用字符串嗅探） */
public class SubagentTimeoutException <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/**
 * 子代理调度器（阶段 C S3，方案C §5 R2）：每个父 Agent 一个实例。
 *
 * 职责（不变量 3/4 的载体）：
 * - AgentNode 树内登记：TUI Agents 面板 / Web 帧的唯一数据源
 * - 并发信号量：maxConcurrent 满则排队（acquire 轮询 + 中断检查，不丢任务）
 * - 回合 token 归账：addTokens 累计，S4 的预算闸门读它
 *
 * 线程模型：节点表与计数字段由 lock 保护；onChanged 回调在锁外触发
 * （回调方可能再进 TUI 锁，锁内调用有死锁风险——顺序：改状态 → unlock → notify）。
 */
public enum AgentNodeState {
    Pending | Running | Ok | Failed | Timeout | Cancelled | BudgetExceeded

    /** 状态名（断言与面板渲染共用；仓颉 enum 无 == 运算符） */
    public func name(): String {
        match (this) {
            case Pending => "Pending"
            case Running => "Running"
            case Ok => "Ok"
            case Failed => "Failed"
            case Timeout => "Timeout"
            case Cancelled => "Cancelled"
            case BudgetExceeded => "BudgetExceeded"
        }
    }
}

/** 树节点：面板行渲染所需的最小字段集 */
public class AgentNode {
    public let agentId: Int64
    public let parentId: Int64
    public let label: String      // description（task 参数）
    public let kind: String       // explore / worker
    public var state: AgentNodeState = AgentNodeState.Pending
    public var iterations: Int64 = 0
    public var promptTokens: Int64 = 0
    public var completionTokens: Int64 = 0
    public var currentTool: String = ""   // 面板"当前工具"列（最有信息量）

    public init(agentId: Int64, parentId: Int64, label: String, kind: String) {
        this.agentId = agentId
        this.parentId = parentId
        this.label = label
        this.kind = kind
    }

    /** 深拷贝（snapshot 用：面板只读快照，渲染零阻塞、无共享可变态） */
    public func copy(): AgentNode {
        let n = AgentNode(this.agentId, this.parentId, this.label, this.kind)
        n.state = this.state
        n.iterations = this.iterations
        n.promptTokens = this.promptTokens
        n.completionTokens = this.completionTokens
        n.currentTool = this.currentTool
        return n
    }
}

public class SubagentScheduler {
    private let maxConcurrent: Int64
    private let sem: Semaphore
    // S4 边界（0 = 对应项不限）
    private let maxPerTurn: Int64      // 每回合派生上限（超出 budget_exceeded，直接拒）
    private let tokenBudget: Int64     // 子代理回合 token 预算
    public let timeoutMs: Int64        // 子代理墙钟超时
    private let lock: Mutex = Mutex()
    private var nodes: ArrayList<AgentNode> = ArrayList<AgentNode>()
    private var changedCb: () -> Unit = { => }
    // 本回合归账：token 累计 + 派生次数（闸门数据源）
    private var tokensThisTurn: Int64 = 0
    private var spawnedThisTurn: Int64 = 0
    // S7：低效派生计数（事后纠偏 [路由提示] 触发时 +1；总结条 ⚠N）
    private var wastedThisTurn: Int64 = 0

    public init(maxConcurrent: Int64) {
        this.maxConcurrent = maxConcurrent
        this.sem = Semaphore(maxConcurrent)
        this.maxPerTurn = 0
        this.tokenBudget = 0
        this.timeoutMs = 0
    }

    public init(maxConcurrent: Int64, maxPerTurn: Int64, tokenBudget: Int64, timeoutMs: Int64) {
        this.maxConcurrent = maxConcurrent
        this.sem = Semaphore(maxConcurrent)
        this.maxPerTurn = maxPerTurn
        this.tokenBudget = tokenBudget
        this.timeoutMs = timeoutMs
    }

    /**
     * 派生闸门（S4）：本回合派生数达上限，或 token 预算已用尽 → false。
     * 调用方（spawnSubagent）据此返回结构化 budget_exceeded——模型能读懂并改变策略。
     */
    public func allowSpawn(): Bool {
        this.lock.lock()
        let overTurns: Bool = this.maxPerTurn > 0 && this.spawnedThisTurn >= this.maxPerTurn
        let overBudget: Bool = this.tokenBudget > 0 && this.tokensThisTurn >= this.tokenBudget
        this.lock.unlock()
        return !overTurns && !overBudget
    }

    /** 成功派发后计数（在 acquire 成功后调用） */
    public func recordSpawn(): Unit {
        this.lock.lock()
        this.spawnedThisTurn += 1
        this.lock.unlock()
    }

    /** S7：低效派生 +1（spawnSubagent 事后纠偏触发时调用） */
    public func addWasted(): Unit {
        this.lock.lock()
        this.wastedThisTurn += 1
        this.lock.unlock()
    }

    public func wastedCount(): Int64 {
        this.lock.lock()
        let w = this.wastedThisTurn
        this.lock.unlock()
        return w
    }

    /** 状态变更回调（TUI markDirty 用；锁外触发） */
    public func onChanged(cb: () -> Unit): Unit {
        this.lock.lock()
        this.changedCb = cb
        this.lock.unlock()
    }

    /** 登记子代理节点（Pending → 由 spawnSubagent 推进 Running） */
    public func register(node: AgentNode): Unit {
        this.lock.lock()
        this.nodes.add(node)
        let cb = this.changedCb
        this.lock.unlock()
        cb()
    }

    /** 节点终态回写（iterations/tokens/state 一次落齐） */
    public func finish(agentId: Int64, state: AgentNodeState, iterations: Int64,
        promptTokens: Int64, completionTokens: Int64): Unit {
        this.lock.lock()
        for (n in this.nodes) {
            if (n.agentId == agentId) {
                n.state = state
                n.iterations = iterations
                n.promptTokens = promptTokens
                n.completionTokens = completionTokens
                n.currentTool = ""
            }
        }
        let cb = this.changedCb
        this.lock.unlock()
        cb()
    }

    /** 当前工具列更新（onToolStart 转发） */
    public func markTool(agentId: Int64, tool: String): Unit {
        this.lock.lock()
        for (n in this.nodes) {
            if (n.agentId == agentId) {
                n.currentTool = tool
            }
        }
        let cb = this.changedCb
        this.lock.unlock()
        cb()
    }

    /** 轮次列更新（S3 修实测问题：每轮 LLM 响应经 onTokenEstimate 转发，面板 i/5 实时递增） */
    public func markRounds(agentId: Int64, rounds: Int64): Unit {
        this.lock.lock()
        for (n in this.nodes) {
            if (n.agentId == agentId) {
                n.iterations = rounds
            }
        }
        let cb = this.changedCb
        this.lock.unlock()
        cb()
    }

    /** 面板只读快照（深拷贝，调用方随意持有） */
    public func snapshot(): ArrayList<AgentNode> {
        this.lock.lock()
        let out = ArrayList<AgentNode>()
        for (n in this.nodes) {
            out.add(n.copy())
        }
        this.lock.unlock()
        return out
    }

    public func nodeCount(): Int64 {
        this.lock.lock()
        let n = this.nodes.size
        this.lock.unlock()
        return n
    }

    /**
     * 并发槽：满则排队（每 50ms 重试），排队期间父被中断 → 返回 false（调用方转 cancelled）。
     * 不丢弃任务（方案C D9：超出排队）。
     */
    public func acquire(isInterrupted: () -> Bool): Bool {
        while (true) {
            if (this.sem.tryAcquire()) {
                return true
            }
            if (isInterrupted()) {
                return false
            }
            sleep(Duration.millisecond * 50)
        }
        return false  // 不可达（while true 仅被 return 退出）
    }

    public func release(): Unit {
        this.sem.release()
    }

    // ── S4 预算归账（闸门逻辑在 S4 接线；此处只做累计与回合重置） ──

    public func addTokens(n: Int64): Unit {
        this.lock.lock()
        this.tokensThisTurn += n
        this.lock.unlock()
    }

    public func tokensUsed(): Int64 {
        this.lock.lock()
        let t = this.tokensThisTurn
        this.lock.unlock()
        return t
    }

    /** 回合重置（父 Agent.beginRound 调用）：归账三项一并清零 */
    public func resetTurn(): Unit {
        this.lock.lock()
        this.tokensThisTurn = 0
        this.spawnedThisTurn = 0
        this.wastedThisTurn = 0
        this.lock.unlock()
    }
}
