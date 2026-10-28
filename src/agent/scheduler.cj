package cjh.agent

import std.sync.*
import std.collection.*
import std.time.*

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
    // 并发信号量：None = 不限（maxConcurrent <= 0）。
    // 必须容忍 <= 0：settings 文档语义是"四键 0 = 对应项不限"，而
    // Semaphore(0) / Semaphore(-1) 会抛 IllegalArgumentException（实测：
    // "Invalid amount to acquire." / "Negative count."）——此前直接构造会让
    // 用户配了 max_subagents: 0 后整个进程起不来（S3 复核 P1）。
    private let sem: Option<Semaphore>
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
        this.sem = SubagentScheduler.makeSem(maxConcurrent)
        this.maxPerTurn = 0
        this.tokenBudget = 0
        this.timeoutMs = 0
    }

    public init(maxConcurrent: Int64, maxPerTurn: Int64, tokenBudget: Int64, timeoutMs: Int64) {
        this.maxConcurrent = maxConcurrent
        this.sem = SubagentScheduler.makeSem(maxConcurrent)
        this.maxPerTurn = maxPerTurn
        this.tokenBudget = tokenBudget
        this.timeoutMs = timeoutMs
    }

    /** 并发上限 <= 0 = 不限（settings 语义）；Semaphore 不接受非正数 */
    private static func makeSem(n: Int64): Option<Semaphore> {
        if (n <= 0) {
            return None
        }
        return Some(Semaphore(n))
    }

    /**
     * 原子派生闸门（S3 复核 #7 修 TOCTOU）：判定 + 计数在同一把锁内完成。
     *
     * 背景：旧用法 `allowSpawn() → acquire() → recordSpawn()` 三步分离（该 API 已移除，
     * 留着就是漏洞源），而 DAG 批处理会**同批并发**执行多个 task 调用
     * （`loop.cj` 拓扑组内 spawn）；两个线程可同时通过判定（此时谁都没计数），
     * 实测可越过 max_tasks_per_turn。合并成一次加锁后，超额直接拒（budget_exceeded）。
     *
     * @return true = 已占一个回合名额（并发名额另由 acquire 控制）
     */
    public func tryBeginSpawn(): Bool {
        this.lock.lock()
        let overTurns: Bool = this.maxPerTurn > 0 && this.spawnedThisTurn >= this.maxPerTurn
        let overBudget: Bool = this.tokenBudget > 0 && this.tokensThisTurn >= this.tokenBudget
        if (overTurns || overBudget) {
            this.lock.unlock()
            return false
        }
        this.spawnedThisTurn += 1
        this.lock.unlock()
        return true
    }

    /**
     * 派生计数回退：tryBeginSpawn 已计数、但 acquire 排队期间被父中断（名额没拿到）。
     * 不回退会让取消的排队者白占一个回合名额（下一批派生被误拒）。
     */
    public func undoSpawn(): Unit {
        this.lock.lock()
        if (this.spawnedThisTurn > 0) {
            this.spawnedThisTurn -= 1
        }
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

    /** 当前工具列更新（onToolStart 转发；变更检测：同名工具重复调用不重绘） */
    public func markTool(agentId: Int64, tool: String): Unit {
        this.lock.lock()
        var changed = false
        for (n in this.nodes) {
            if (n.agentId == agentId) {
                if (n.currentTool != tool) {
                    n.currentTool = tool
                    changed = true
                }
            }
        }
        let cb = this.changedCb
        this.lock.unlock()
        if (changed) {
            cb()
        }
    }

    /**
     * 轮次/用量更新（S3 修实测卡死）：由 onRoundTick（每轮一次）驱动，iterations/
     * promptTokens/completionTokens 一次落齐。变更检测：三项都没变就跳过 cb——
     * 防御任何高频回调源把主循环淹没（cb = 快照拷贝 + markDirty 全帧置脏）。
     */
    public func markRoundUsage(agentId: Int64, rounds: Int64, promptTokens: Int64,
        completionTokens: Int64): Unit {
        this.lock.lock()
        var changed = false
        for (n in this.nodes) {
            if (n.agentId == agentId) {
                if (n.iterations != rounds || n.promptTokens != promptTokens ||
                    n.completionTokens != completionTokens) {
                    n.iterations = rounds
                    n.promptTokens = promptTokens
                    n.completionTokens = completionTokens
                    changed = true
                }
            }
        }
        let cb = this.changedCb
        this.lock.unlock()
        if (changed) {
            cb()
        }
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
     * 不丢弃任务（方案C D9：超出排队）。maxConcurrent <= 0（不限）时恒成功。
     */
    public func acquire(isInterrupted: () -> Bool): Bool {
        match (this.sem) {
            case Some(s) =>
                while (true) {
                    if (s.tryAcquire()) {
                        return true
                    }
                    if (isInterrupted()) {
                        return false
                    }
                    sleep(Duration.millisecond * 50)
                }
            case None =>
                return true  // 不限并发
        }
        return true  // 不可达（各分支均 return）
    }

    public func release(): Unit {
        match (this.sem) {
            case Some(s) => s.release()
            case None => ()  // 不限并发：无名额可还
        }
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

    /** 回合重置（父 Agent.beginRound 调用）：归账清零 + 节点面板清空
     * （修实测"结束后不消失"：终态节点保留到本回合结束供总结条归账，下一回合开始时清空） */
    public func resetTurn(): Unit {
        this.lock.lock()
        this.tokensThisTurn = 0
        this.spawnedThisTurn = 0
        this.wastedThisTurn = 0
        this.nodes.clear()
        let cb = this.changedCb
        this.lock.unlock()
        cb()
    }

    // ===== 错峰派发（修实测"并发派发撞 provider 限流"：5 路同时起跑全灭）=====
    // 并发子代理的起跑时刻按 staggerMs 间隔错开，把瞬时请求洪峰摊平。
    // 顺序派发（前一个跑完才派下一个）时 elapsed 已远超 slot 预算，自动等 0；
    // 全部节点终态后锚点重置，下一波并发从 0 重新起算。
    private var gateAnchor: DateTime = DateTime.now()
    private var gateSlot: Int64 = 0
    private var staggerMs: Int64 = 1000

    /** 调整错峰间隔（测试用：调小以快速验证门逻辑） */
    public func setStaggerMs(ms: Int64): Unit {
        this.lock.lock()
        this.staggerMs = ms
        this.lock.unlock()
    }

    /** 当前错峰间隔 */
    public func getStaggerMs(): Int64 {
        this.lock.lock()
        let ms = this.staggerMs
        this.lock.unlock()
        return ms
    }

    /**
     * 错峰派发门：子代理起跑前调用。同一波并发派发的起跑时刻按 staggerMs
     * 错开（第 k 个等 k*staggerMs）。等待在锁外进行，不阻塞面板刷新与配额闸门。
     */
    public func staggerGate(): Unit {
        this.lock.lock()
        let now = DateTime.now()
        var elapsed = (now - this.gateAnchor).toMilliseconds()
        // 空闲重置：上一波全部终态且距锚点已超过一个间隔 → 下一波从 0 起算
        var anyRunning = false
        for (n in this.nodes) {
            var running = false
            match (n.state) {
                case AgentNodeState.Running => running = true
                case _ => ()
            }
            if (running) {
                anyRunning = true
                break
            }
        }
        if (!anyRunning && elapsed > this.staggerMs) {
            this.gateAnchor = now
            this.gateSlot = 0
            elapsed = 0
        }
        let target = this.gateSlot * this.staggerMs
        let wait = target - elapsed
        this.gateSlot += 1
        this.lock.unlock()
        if (wait > 0) {
            sleep(Duration.millisecond * wait)
        }
    }
}
