# 子代理集群调度与路由 · 阶段 C 方案（评审 + 定稿建议）

> 状态：**评审已完成；D8（TUI 呈现=三件套）已确认**；D5/D6/D7/D9/D10 待讨论（2026-10-26）。
> 上游文档：`docs/并行子代理与上下文隔离-方案.md`（下称"原方案"）。
> 本文两块内容：**§1–§3 是对原方案落实情况的评审（含 3 个 P0）**；**§4 起是阶段 C「集群调度」的设计**，含两项新增需求：主代理作为决策中枢/路由中心、TUI 内多 agent 呈现。

---

## 1. 评审结论（一句话）

原方案的**架构判断是对的**（Agent 树 = 进程树、权限单调、两道窄门），阶段 A 的四个安全洞（G1–G4）确实关掉了（`buildSubagentRegistry` / `buildSubagentConfig` + 9 个用例可证）。
但**阶段 B 只落了一半**：中断机制在、"可观测"只做到"结论回传带树形前缀"，子代理运行期仍是黑盒；**阶段 C 的边界（并发/预算/超时）一个都没做**，而原方案 §7 把它们写成已承诺项。

结论：**并行调度现在不能开闸**——不是体验问题，是 3 个 P0（越权批准、abort 串台、无边界资源）会真出错。

> 进度更新（2026-10-26，commit `9d0f88b`）：P0-1（审批单槽）与 P0-2（abort 串台）**主路径已修**（§7 的 S1/S2a），但复核出 1 处 P0 残留 + 1 处 Web 回归，见 **§7.1**。P0-3（并发/预算/超时边界）仍未动，**开闸条件依然不满足**。

---

## 2. 文档 vs 实现的偏差表（带代码坐标）

| # | 原方案承诺 | 实际 | 定性 |
|---|---|---|---|
| B1 | §8「子事件经回调加前缀汇入主流」 | `spawnSubagent` 只接了 `onApproval`；`onDelta/onReasoning/onToolStart/onToolResult/onTokens` 全空 | **P0 黑盒**：worker 最长可跑 15 轮（见 C2），用户只看到一行 `▶ task {...}` 然后干等 |
| B2 | §10 风险 2「UI 需队列化 modal 防互相覆盖」 | TUI 是**单槽**：`pendingApproval: Option<String>` + `approvalResult: Option<Bool>` + 单个 `ConfirmDialog`（`src/tui/app.cj:120-121,529-551`） | **P0 越权**：详见 §3.1 |
| C1 | §7「`Semaphore(maxConcurrentSubagents)`，默认 4，settings 可配」 | 无信号量、无配置项（`grep maxConcurrentSubagents` 零命中） | **P0 无上限** |
| C2 | §7 / 子代理 prompt「max_iterations=5」 | `AgentConfig(..., 5, ...)` 是**软顶**：`hardCap = maxIterations + wrapUpRounds(10) = 15`（`loop.cj:665-669`） | 对模型撒谎：system prompt 说 5，实际 15 → token/时间放大 3 倍 |
| C3 | §7「结构化结果 + transcript 落盘」 | `TaskSpawnResult` 只有 `text/iterations/promptTokens/completionTokens/status`；**无 `filesTouched`、无 `transcriptPath`** | P1 事后不可回看 |
| C4 | §7「子代理 tokens 计入父 RunSummary」 | `RunSummary` 无相应字段；只在 task 结果文本里带 `↑↓`，总结条不含全树 | P1 成本不可见（而"成本不可见"正是无效派生的根因） |
| C5 | §7「token 预算 / 时间上限」 | 均无；**子代理无墙钟超时** → 卡住会把父回合的组 barrier 永久阻塞 | **P0** 违反不变量 4「有界资源」 |
| D1 | §9「C：explore→快模型路由（复用 summaryProvider）」 | 未做；子代理一律用父 provider | 待 C 期 |
| W1 | §8「Web 协议 v5 加 agent_id/agent_label」 | 已作为"偏差 1"延后，只做了 reason 前缀 | 可接受，但 TUI 树呈现会连带需要它 |
| W2 | §10 风险 2「WS 靠 request_id 多路复用」 | **网关侧实现是正确的**：`pendingApprovals: HashMap<String, ApprovalSlot>`（`src/gateway/channel.cj:346-347`），未知/超时/重复答复都结构化报错 | ✅ 真落地（对比 TUI 侧的错误做法，见 §3.1） |
| T1 | 门禁「per 项配测试」 | 子代理测试全是**顺序**脚本化 provider（`SubagentScriptProvider`），没有一条并发用例 | P1：并发是本期的本质，必须补并发测试 |
| T2 | `cancelled` 判定（§11.1 偏差 2） | 靠 `summary.reply` 前缀 `[已中断` 字符串嗅探；本期还要加 `timeout`/`budget_exceeded`，字符串嗅探会更脆 | P2：改由 `RunSummary` 显式字段承载（`interrupted: Bool`），前缀仅用于展示 |
| T3 | task 结果走通用截断器 | `configMax` 默认 6000（`cjconfig`→`AgentConfig.toolResultMaxChars`），头尾各半 + 落盘 → 结论若在中间会被切 | P1：`task` 单列阈值并约定"结论在前、明细在后" |

> 建议同时把原方案 §11.1 的状态描述改为「A 全落 / B 落一半（机制在、呈现缺）/ C 未动」，避免后续 PR 以此为依据误判已达基线。

---

## 3. 必须先修的 5 个硬问题

### 3.1 P0-1 审批单槽 → 并发时越权批准（TUI）

现状：`TuiApp.requestApproval` 把 prompt 写进单槽并弹**唯一**的 modal；第二个子代理调用时覆盖第一个的 prompt；用户按 `y` 后 `approvalResult=Some(true)`，**两个等待线程都读到同一个 true**。
即"A 的危险操作被批准，是因为用户在看 B 的弹窗"。

修法（不改语义，只改结构）：
- 审批改为**队列**：`ArrayList<ApprovalReq{ reqId, agentLabel, tool, reason }>`，`HashMap<Int64, Option<Bool>>` 存结果；`y/n` 只作用于队首，弹窗标题显示 `审批 (2/3)`。
- `Ctrl+C` 现有"有未决审批则写 false"分支改为"拒绝队首"，其余排队项继续展示（或整体拒绝，二选一，建议整体拒绝 + 明确提示）。
- 复用 `Agent.agentId`：审批请求带上来源 agent，弹窗展示 `[task:label]`（已有前缀）+ agent id。
- 测试：`src/tests/tui_app_test.cj` 补"两个并发 requestApproval，队首 y 只放行一个"；`tui_pty_test.py` 补"审批排队 + y 只批队首"。

> 顺带：Web 前端是单 modal，第二个 `approval_request` 会覆盖第一个弹窗（服务端槽位是对的，第一个请求会一直阻塞到 300s 超时）。同批修：前端改成"队列 + 当前/总数"提示。

### 3.2 P0-2 共享 provider 的 `abort()` 会串台

`OpenAiProvider.currentTransport` 是**单槽**（`libs/cjllm/src/openai.cj:25,266`），`abort()` 关闭"当前"连接。父与 N 个子代理并发共用同一 provider 实例时：
- 父 Ctrl+C 的 `abort()` 可能关到某个子代理的连接 → 父自己的流只能等 `isCancelled()` 的 ≤5s 短读轮询退出（可用但语义错）；
- 子代理 `interrupt()` 的 abort 可能关到**兄弟**的连接。

好消息：真正的取消靠 per-call `isCancelled()` 回调，所以不会死锁；坏消息：`abort()` 这个加速器在多 agent 下是错的。

修法（二选一，推荐 A）：
- **A. 子代理各自 new provider 实例**（同 baseUrl/model/key 配置），`abort()` 天然隔离；顺带给 D1「explore 走快模型」留出干净的落点。成本：多一次 TLS 握手（并发时本来也是多条连接）。
- B. 把 `currentTransport` 改成 `HashMap<callId, transport>`（传输层改造，影响 3 个 provider，风险更大）。

### 3.3 P0-3 无上限 / 无预算 / 无超时

必须落在 harness 层（不靠 prompt 自觉），见 §5 R2：信号量 4、每回合派生上限 6、子代理 token 预算、300s 墙钟超时 → 超限一律**结构化失败**而非挂死。
超时用"设中断标志 + 等一个 join 窗口（如 5s）+ 放弃引用"实现，**不能**依赖阻塞 join（仓颉线程无法 safe kill）。

### 3.4 P1 子代理写冲突对父 DAG 不可见

`extractResourceAccess` 对未知工具（含 `task`）返回 `("", true)`（`loop.cj:1383-1384`），而 `buildDependencyGraph` 在 `path.size==0` 时直接 `continue`（`1418-1419`）→ **N 个 task 之间零依赖、与父的 `write_file` 同组并发**：两个 worker 写同一文件 = 静默覆盖。
修法见 §5 R3（task 加 `scope`，scope 参与 DAG + 子代理写域收窄）。

### 3.5 P1 结论提取不稳定

`extractSubagentResult` 取"最后一条有内容的 assistant 消息"：达轮次上限时最后一轮常是收尾句（信息稀薄）；若最后一轮只有 tool_calls，则返回 `"(子代理未产生回复文本)"` ——**零信息失败**。
修法：优先最后 assistant 文本；为空则用"工具轨迹摘要"兜底（读过的文件、命中的关键行），并在结果头显式标注 `status` 与"产出稀薄"。

---

## 4. 阶段 C 的目标：把"放任"改成"决策中枢 + 调度器 + 治理"

用户提出的判断是对的：**当前不是"路由"，是"放任"**。证据：
- `task` 工具描述只有一句鼓励："PARALLEL: … issue MULTIPLE task calls in ONE turn"（`src/task.cj:52`）；
- 默认 system prompt（`libs/cjcfg/src/config.cj:530-556`）**一句都没提 task / 并行**；
- 没有任何"简单任务不要外包"的反向约束，也没有数量/成本边界 → 模型倾向为"看起来重要"的任务都派一个 explore，每次派生的固定开销 ≈ 3–5k token（子代理 system prompt + 全量工具 schema）。

设计主张：**决策中枢不是"让 LLM 每轮猜一次"，而是"harness 把成本边界和信号做出来，模型在该边界内决定"**。三层：

```
┌ 层0 决策中枢（主代理 / LLM） ─ 判定表 + 反例 + 事后纠偏信号
├ 层1 调度器（harness）        ─ 并发/预算/超时/冲突  (代码强制，不看 prompt)
└ 层2 治理与呈现（TUI/Web）    ─ Agents 面板 + 焦点切换 + 审批队列 + 全树归账
```

---

## 5. 设计细节

### R1 路由：主代理做决策中枢（层 0）

**(a) 判定表进 prompt（判定标准，不是鼓励语）**——加到 `buildSystemPrompt` 的固定段 + `task` 工具描述：

| 情形 | 决策 |
|---|---|
| 单文件改动、答案明确、预估 ≤3 次工具调用 | **自己做**（默认路径） |
| 需全局扫描、答案可一句话回答、你随后要据此改代码（≥5 文件级检索） | 派 1 个 `explore` |
| ≥2 个**互不写同一文件**的独立改动，且每个 ≥3 轮工具 | 派 N 个 `worker` |
| 只是想"确认一下"/为一个文件派 worker/把一个任务拆成"先想再写"两路 | **禁止** |

配套硬性表述：一轮 ≤3 路、每回合 ≤6 个派生、不给 `scope` 的 worker 视为全仓写（会被串行化）。

**(b) 硬闸门（层 1，代码强制）**：`SubagentScheduler`
- `maxConcurrentSubagents = 4`（排队，不丢弃）
- `maxTasksPerTurn = 6` → 超出返回 `status=budget_exceeded`，文案直接告诉模型"请自己做"
- `maxSubagentTokens = 200_000`（父回合累计）→ 超限后续派生直接拒
- `subagentTimeoutMs = 300_000` → `status=timeout` + 中断子代理
- 全部可 settings 配；`--mock` 下用较小值便于测。

**(c) 事后纠偏（比说教有效）**：子代理 `iterations<=1 且 text<200 字符` → 在 task 结果尾部追加一行
`[路由提示] 该子任务 1 轮完成、结论 87 字符；此类任务下次请直接处理（单次派生固定开销约 3–5k token：子代理 system prompt + 全量工具 schema）`，
并累加到 `RunSummary.wastedSpawns`，总结条显示 `⚠ 2 次低效派生`。→ 用真实成本反馈让模型自我校准。

**(d) 用户开关（物理可达性，与 capability 同一哲学）**：
`/parallel on|off|auto`（off = 不注册 `TaskTool`，子代理物理不可达）+ settings `subagent.mode`。

**(e) 不做的事**：**不建议**加"额外一次 LLM 调用做复杂度分类器"。延迟 + 误判 + 又一份 token，收益不抵；判定表 + 硬闸门 + 成本反馈已经覆盖 95% 场景。若日后要，只作为"离线建议"（累计 `wastedSpawns` 超阈值时提示用户开 off）。

### R2 调度器与数据模型（层 1）

新增 `src/agent/scheduler.cj`（package `cjh.agent`，不碰 `cjh.tools`，避免循环依赖）：

```cangjie
public enum AgentNodeState { Pending | Running | Ok | Failed | Timeout | Cancelled | BudgetExceeded }

public class AgentNode {          // 树节点（TUI/Web 唯一数据源，不变量 3）
    public let agentId: Int64
    public let parentId: Int64
    public let label: String      // description
    public let kind: String       // explore / worker
    public var state: AgentNodeState
    public var iterations: Int64
    public var promptTokens: Int64
    public var completionTokens: Int64
    public var lastTool: String   // 当前正在跑的工具（面板行用）
    public var startedAt: DateTime
    public var nodeId: Int64      // 树内序号（列表上限 6/7 索引）
}

public class SubagentScheduler {   // 每个父 Agent 一个实例
    public func acquire(): Unit        // 信号量，满则阻塞（配合超时）
    public func release(): Unit
    public func register(node: AgentNode): Unit
    public func snapshot(): ArrayList<AgentNode>   // 加锁拷贝，供 TUI 渲染
    public func onChanged(cb: () -> Unit): Unit    // TUI markDirty
    public func addTokens(n: Int64): Bool          // 预算闸门，false = 超限
}
```

- `TaskTool.execute` 从"scheduler 满/超限"路径返回结构化 `budget_exceeded` 文本（模型能读懂并改变策略）。
- `spawnSubagent` 里把子代理的 `onThinking/onToolStart/onToolResult/onDelta/onTokens` 接到 scheduler：更新 `AgentNode` 并（按焦点策略）转发到 UI。
- 子代理 provider 各自实例（§3.2 方案 A）；`explore` 用 `summaryProvider`（快模型）→ 顺手把 D1 做完，并在 `AgentNode` 上标 `model=fast`。
- `transcriptPath`：子代理完整 messages 落 `spillDir/<sid>/sub-<label>-<agentId>/transcript.txt`（复用 `writeSpill`），路径进 `TaskSpawnResult`。
- `filesTouched`：子代理自己 `recordTouchedPaths`（已有机制）在结束时导出。
- **接线收敛（S2a 后新增的注意点）**：`TaskTool` 现在在 `entries.cj` 的 `runJson` / `runTui` 两处各自注册、各自捕获 `cjhCfg` 造 provider 与 agent。S3/S4 要给派生加 scheduler/事件/预算，别再复制第三份——先抽一个 `registerTaskTool(registry, agent, config, deps)`（`deps` 装 scheduler + provider 工厂 + 审批回调），两处入口都调它。

### R3 冲突消解：scope（层 1）

1. `task` 增可选参数 `scope: ["src/web/*.cj", ...]`（glob 风格，与 capability 的 fs 语法一致）。
2. `extractResourceAccess` 对 `task` 返回每个 scope 项（`isWrite=true`）→ 父 DAG 自然产生"scope 重叠 → 串行"边；无 `scope` 的 worker 返回一个哨兵 `("**", true)`，与所有 writer 串行（保守，避免静默覆盖）。
3. **写域收窄**：`AgentConfig` 增 `writeScope: ArrayList<String>`（空=不限），`executeGuarded` 在 capability **之后**追加 AND 判定（只收窄、绝不放宽）。红线：不动 `Capability` 默认宽松语义，不改 `enabled` 语义。
4. 模型不给 scope 时，TUI 在该 agent 面板行打 `⚠ 无写域`，并在结果里提示"下次请给 scope 以便并行"。

### R4 TUI 多 agent 呈现（层 2，用户问题二）

**结论：不做多窗格；用"主流只讲父的故事 + 右下 Agents 面板 + 焦点切换"三件套。**
理由：终端高度有限（24 行起步），多窗格会让每个 agent 只剩 3–4 行，且现有 `OutputView` 是 append-only 的行模型 + 单一 diff 渲染，改多窗格等于重写渲染层。三件套在现有架构上是**增量**，且能同时满足"看全局"和"看某一个"。

**(1) 主消息流只保留里程碑**：`▶ task [worker:改路由 scope=src/agent]` 一行 → 结束时树形结果（已有 `├─ … └─`）+ 结论。父的叙事不被淹没，符合"窄门"。

**(2) Agents 面板**（照 `TasksPanel` 的 `snapshot + Mutex + height()/render()` 成熟模式，`libs/cjterm/src/agentspanel.cj`，可独立单测，不依赖 Agent）：

```
╭─ Agents (3 running · 1 done · ↑12.4k) ──────────────────╮
│ ⠹ explore  找配置      2/5   ↑1.2k   grep config        │
│ ⠼ worker   改路由      4/5   ↑3.4k   edit_file loop.cj  │
│ ⠸ worker*  补测试      1/5   ↑0.6k   read_file *_test.cj│
│ ✓ explore  查依赖      2     ↑0.9k                      │
╰─────────────────────────────────────────────────────────╯
```
- 位置：输出区右下，**Tasks 面板之上**；高度 = min(节点数+2, 7)；超出折成 `+N more`。
- 每行：spinner/状态符 + 类型 + 标签（`*` = 当前焦点）+ `轮次/软顶` + token + **当前工具**（最有信息量的一列）。
- 状态色：运行=强调、✓=OK、✗=错误、⏹=取消、⏱=超时、`⚠`=无写域。
- 刷新：`scheduler.onChanged` → `markDirty()`；**渲染零阻塞**（只读快照）。

**(3) 焦点切换（关键增量）**：**`Tab` 已被"视图切换（对话/帮助）"占用**（`app.cj:1379-1387`），且 `Ctrl+U/Ctrl+D` 是滚动，不能动。键位方案：
- 主键 `Ctrl+T`（ch=20）循环焦点，`Ctrl+G`（ch=7）反向；控制字节的 `text` 为空（`term.cj:65-71`），不会漏进输入框。
- 辅助：面板行首数字（`1..9`）+ `Ctrl+T 1` 语义等价；`/agent <n>` 亦可（slash 命令已有框架）。
- 可选（后置）：鼠标点击面板行聚焦——`KeyEvent` 已解析 SGR 鼠标（`mouseX/mouseY/mouseButton`），但 app 层目前只打日志、无命中测试，属新增工作量，不列入本期必做。
- 焦点=父（默认）：子代理事件**不进主流**，只在面板行里滚动更新（含 `lastTool`）。
- 焦点=某子代理：该子代理的**细粒度**事件插入主流，带竖线前缀
  ```
  │ ⠼ [worker:改路由] ▶ edit_file src/agent/loop.cj
  │ ↳ edit_file: 已修改 1 处
  ```
  其余子代理仍折叠为面板一行。状态栏右侧显示 `[focus worker:改路由 · Ctrl+T 切换]`。
- 帮助视图需同步补这一行按键说明（`app.cj:1734+`）。
- 实现约束（必须遵守）：`OutputView.appendDelta` 共用"当前行"，**多路 delta 会撕行** → 只对**焦点**子代理转发 `onDelta`（且同一时刻最多一路），非焦点只转发"行事件"（`onToolStart/onToolResult` 已是整行）。这是一条硬规则，写进代码注释。

**(4) 审批队列化**（§3.1 的 UI 部分）：标题 `审批 (2/3)`，`y` 只批队首，队列项带 `[task:label]`。

**(5) 回合总结条全树归账**（不变量 4 的可观测化）：
`─── ✓ 3 rounds · 6 tools · 3 agents (2✓ 1✗) · 42.6s · 8.9k tokens · ⚠1 低效派生 ───`

**(6) Web**：协议加 `agent_id / parent_id / agent_label / agent_state` 可选帧字段（原方案 §8 的 v5 顺延），前端按 agent 分列 + 复用服务端 `request_id` 队列；本轮**TUI 为主，Web 只保证字段不虚报**（`web/capabilities.cj` 按帧清单推导）。

**(7) pty 测试矩阵**：mock 脚本化 provider 让父一次发 3 个 task（一快一慢一失败）→ 断言：面板 3 行 + 计数正确、`Ctrl+T` 后焦点行出现竖线前缀、审批排队 `y` 只批队首、超时行显示 `⏱`；**回归**：原有 `Tab` 视图切换场景必须全绿（键位不冲突）。

---

## 6. 失败自愈矩阵（补原方案缺失）

| 子代理出口 | 父的默认动作 | 回父文本要点 |
|---|---|---|
| `ok` | 正常利用结论 | 结论 + 触碰文件 |
| `failed` | **不自动重试**（多半同因失败） | 错误码 + 建议换个更窄 scope / 自己做 |
| `timeout` | 中断并回收引用 | "超时，已产出部分：\<最后文本>" |
| `cancelled` | 静默（父自己也在中断） | `[已中断]` |
| `budget_exceeded` | 拒绝派生 | "预算/并发已满，请直接处理本任务" |
| `denied`（审批被拒） | 不重试 | 明确指出被拒的具体操作 |

---

## 7. 实施顺序（每步可独立交付、可测、可回退）

| 步 | 内容 | 改动文件 | 测试 |
|---|---|---|---|
| **S1** | 审批队列化 + 前端单 modal 排队 | `src/tui/app.cj`、`libs/cjterm/src/confirm.cj`、`src/web/static_assets.cj` | `tui_app_test` 并发审批 2 例；pty 1 场景 |
| **S2a** | provider per-instance（abort 隔离） | `src/entries.cj` | 子代理 provider 不共享断言；`llm_test` |
| **S2b** | provider 生命周期收尾（`abort()` 关闭池化连接）+ 派生不触发 warmup | `src/entries.cj`、`src/main.cj`（`makeProvider(cfg, warmup)`） | 泄漏用例（伪造 provider 断言 abort 被调）；warmup 计数断言 |
| **S2c** | explore→快模型路由（`makeSummaryProvider`）+ 可选 provider 池 | `src/entries.cj`、`src/main.cj` | 子代理 kind→model 断言 |
| **S3** | 子代理事件转发 + `AgentNode`/`scheduler` + AgentsPanel + `Ctrl+T` 焦点 | `src/agent/scheduler.cj`(新)、`libs/cjterm/src/agentspanel.cj`(新)、`src/tui/app.cj`、`src/entries.cj` | scheduler 单测（信号量/预算/超时）；面板渲染单测；pty 4 场景 + `Tab` 回归 |
| **S4** | 边界：并发/每回合上限/token 预算/墙钟超时 + `status=timeout/budget_exceeded` | `src/agent/scheduler.cj`、`src/task.cj`、`libs/cjcfg`(settings 项) | 并发基准（`dag_bench` 扩展）；超时用例（假 provider 挂 5s） |
| **S5** | 路由策略：system prompt 判定表 + task 描述改写 + 事后纠偏 + `/parallel` 开关 | `libs/cjcfg/src/config.cj`、`src/task.cj`、`src/skills.cj`、`src/slash_command.cj` | 纯函数策略判定；mock 端到端「简单任务不派生」 |
| **S6** | scope 冲突消解 + `writeScope` 收窄 | `src/agent/loop.cj`(DAG)、`src/task.cj`、`src/entries.cj` | DAG 重叠串行；越界写被拒（**红线：同批核对 capability 默认宽松不变**） |
| **S7** | 归账与转录：`transcriptPath`/`filesTouched`/`RunSummary` 全树 + 总结条 | `src/task.cj`、`src/agent/loop.cj`、`src/entries.cj` | 字段断言；总结条字符串断言 |
| **S8** | Web 帧字段 + capabilities + 文档/CHANGELOG | `src/web/*` | `web_smoke_test.py`；协议测试 |

顺序理由：**先修安全（S1/S2）→ 再有眼睛（S3）→ 才有边界（S4）→ 才敢开路由（S5）**。S1/S2 不改变任何功能语义，可以立刻合入。

> ✅ 落地（2026-10-26，commit `9d0f88b`）：**S1 与 S2a 已完成**（审批队列化 TUI+Web、provider 每子代理独立实例；
> 门禁：test.sh 552 / test_libs.sh 175（cjterm 加 `ConfirmDialog.currentTitle()`）/ pty 67 / build 零代码告警 / --mock 全过）。
> 落地明细见 `并行子代理与上下文隔离-方案.md` §11.3；**复核发现的残留见 §7.1**（S2b/S2c 未做，另 4 处需收口）。
>
> ✅ 落地（2026-10-27）：**S3 + §7.1 复核收口（A–F）已完成**。S3a `src/agent/scheduler.cj`（AgentNode/AgentNodeState/SubagentScheduler：
> 登记/终态/当前工具/快照深拷贝/onChanged/并发信号量+排队中断检查/回合 token 归账）；
> S3c `libs/cjterm/src/agentspanel.cj`（TasksPanel 同款模式，高度 min(n+2,7) + "+N more"，标题全树归账 `Agents (N running · M done · ↑xxk)`）；
> S3d 主流只讲父的故事 + Agents 面板 + 焦点切换（**键位偏差：方案原定 Ctrl+T，实测 ch=20 已被思考展开占用 → 改 Ctrl+G(ch=7)**，帮助页已同步）；
> 焦点子代理行事件进主流（`│` 前缀），**delta 绝不转发的硬规则**已写进代码注释；S3e G-B 审批队列项带 agent 身份（label 与队列平行，子代理审批等待时面板行显示"等待审批"）。
> 测试：scheduler 3 例 + 面板渲染 4 例 + tui 焦点/label 2 例；pty 67 → **75**（+审批排队 4b、Agents 面板/Ctrl+G 焦点 4c；Tab 回归全绿）。
> S4（边界）、S5-S8 待做；G-A TUI 审批超时随 S4。
>
> ✅ 落地（2026-10-27，同日）：**S4 + G-A 已完成**。cjcfg 四键 `max_subagents`(4) / `max_tasks_per_turn`(6) /
> `subagent_token_budget`(200k) / `subagent_timeout_ms`(300s)，0=对应项不限；
> SubagentScheduler 扩 allowSpawn（派生数/token 预算闸门）+ recordSpawn + 全参构造；
> spawnSubagent 接闸门：配额满 → 结构化 `budget_exceeded`（文案指引模型改策略）、并发满排队（父中断 → cancelled）、
> 名额 finally 释放；墙钟超时经 `runSubagentWithTimeout`（线程化 + 25ms 轮询 + 超时中断 + 5s 宽限 + 放弃引用，
> 抛 `SubagentTimeoutException` 映射 status=timeout，T2 教训：不用字符串嗅探）；beginRound 重置回合归账。
> **G-A**：TUI 审批超时与服务端同源（subagent_timeout_ms），到点=拒绝 + 自愈摘队（队首则推进/收起弹窗）。
> 测试：cjcfg 解析 2 例 + scheduler 闸门 1 例 + spawn 集成 2 例（budget_exceeded/timeout）+ TUI 超时 1 例。
> S5-S8 待做。
>
> ✅ 落地（2026-10-27）：**S5 已完成**（D5=不做额外 LLM 路由调用，全静态）。
> S5a 判定表：默认 system prompt 新增 `## Subagent routing (task tool)` 段（config.cj）+ task 工具描述整段重写
>（何时派生判定表 / Forbidden 反向约束 / 成本边界 ~3-5k / 上限数字与 S4 硬闸门一致）；
> S5(b) 硬闸门 = S4 已做的 allowSpawn/budget_exceeded；
> S5(c) 事后纠偏：1 轮完成且结论 <200 字符的派生在结果尾部挂 `[路由提示]`（真实成本反馈，比说教有效）；
> S5(d) `/parallel on|off|auto`（slash + SLASH_COMMANDS 补全）+ settings `subagent_mode`（启动默认；off=task 派发物理关闭）。
> 测试：路由提示断言 + off 拒绝用例（spawnFn 不执行）+ subagent_mode 解析/默认 2 例。S6-S8 待做。
>
> ✅ 落地（2026-10-27）：**S6 已完成**（红线核对：Capability 默认宽松语义零改动，capability_test 未动）。
> R3(1) task 增可选 `scope`（逗号分隔 glob 字符串；spawnFn 扩 4 参）；
> R3(2) `extractResourceAccesses`（多资源版）：task 每项 scope 一条写边；**无 scope worker 哨兵 ("**",true)
> 与所有带资源调用串行**（实现偏差：判定为"哨兵写 vs 任意资源即冲突"而非字符串相等——相等判定会让
> 哨兵只与同为哨兵的任务串行，漏掉与 scoped writer 的冲突）；DAG 依赖判定改多资源交集；
> R3(3) `AgentConfig.writeScope`（var+默认空=不限，构造签名零变动），executeGuarded 在 capability 之后
> AND 收窄（Capability.globMatch），越界写返回"超出本子代理写域"；
> R3(4) 工具描述写明"无 scope 的 worker 与所有 writer 串行——给 scope 才能并行写"。
> 测试：scope 提取/哨兵 1 例 + DAG 重叠串行 1 例（agent 包内直测 internal）+ 越界写 e2e 1 例
>（子代理观察到最后一条 tool 结果为"超出本子代理写域"；未配置 capability 证默认宽松未动）。S7-S8 待做。
>
> ✅ 落地（2026-10-27）：**S7 已完成**（归账与转录，不变量 4 的收口）。
> `TaskSpawnResult` 扩 `transcriptPath`/`filesTouched`（var+默认，构造签名零变动；status 语义文档补
> timeout/budget_exceeded）；`writeSubagentTranscript` 落 `spillDir/<sid>/sub-<type>/transcript-<agentId>.md`
>（markdown：system/user/assistant/tool 全过程；spillDir 为空跳过，失败静默不碍主流程）；
> 子代理 `getTouchedFiles()` 快照导出；树状渲染树尾补 `触碰文件`（≤5 个）与 `转录:` 行——回父上下文的
> 是结论（窄门不变），过程在盘上可回看；
> 总结条全树归账：`N agents (x✓ y✗)`（scheduler.snapshot 统计）+ `⚠N 低效派生`（[路由提示] 触发时
> scheduler.addWasted，beginRound 清零）。
> 测试：转录文件真实存在且含子代理过程 + 触碰文件导出 1 例（SubChildProvider 加 case 5：
> 第 1 轮 read_file 制造触碰、第 2 轮收场；踩坑复录：case 1 每轮都发 read_file 永不收场、
> Directory.create 不幂等需先 removeIfExists）。S8 待做。
>
> ✅ 落地（2026-10-27）：**S8 已完成——阶段 C（S1–S8）全部落地**。
> 协议升 **v5**：tool_start / tool_result 增可选 `agent_id` / `agent_label`（D10：缺省**不序列化**=
> 父回合，字段不虚报，老客户端零影响）；capabilities.cj 版本号与帧清单注释同步。
> 测试：父帧缺字段 / 子帧带字段 + 版本号断言 2 例（web_protocol_test）。
> 前端按 agent 分列渲染另立项（D10 既定）；`agent_state` 未加（子代理工具帧尚不经 web 通道，
> 加了即虚报——待 S8 后续把子代理工具事件接入 WS 通道时一并补）。
> **验收对照（§8 不变量）**：1 权限单调 ✅（writeScope 只收窄+越界写用例）；2 上下文单向流 ✅
>（简报+结论+transcriptPath 只落盘不回灌）；3 可观测 ✅（面板/焦点/审批队列）；4 有界资源 ✅
>（并发 4/每回合 6/预算 200k/超时 300s，超限均结构化失败且不挂死）。

### 7.1 S1/S2a 复核（2026-10-26，读码复核结论）

**结论：两个 P0 的主路径确实修好了**（越权批准、abort 串台都不再成立），但有 4 处需要收口，其中 1 处是本轮**新引入的回归**。

> ✅ 收口（2026-10-26）：**A–F 已全部修复**。落地方式：A/B `show()` 进锁 + 仅队首 show（非队首经 `ConfirmDialog.updateTitle()` 只刷标题）；C `ErrorEvent.requestId` + `sendApprovalError` 前端按 id 对账（倒计时归零不本地弹队，服务端 id 权威推进）；D 等待方读后即删 + Ctrl+C 测试补断言；E `spawnSubagent` finally `provider.abort()` + `makeProvider(cfg, warmup)` 子代理路径关预热；F pty 新增场景 4b（`CJH_MOCK_TASKS` 门控：父并发派两个 explore → 两路 read_file 审批进队列 → y 只批队首 → (1/2)→(2/2)）。pty 67 → **71 场景全过**；test.sh / test_libs.sh 见当轮交付记录。

| # | 问题 | 位置 | 定性 | 修法 |
|---|---|---|---|---|
| **A** | **非队首请求方也调用 `confirmDialog.show()`**：`title/headPrompt` 在锁内算、`show()` 在锁外调。若该线程在 unlock 与 show 之间被抢占，而队首恰在此时被答复，则弹窗会被**回写成已答复项的内容**（用户看着 A 的文案，按下的却是 B 的决定） | `src/tui/app.cj` `requestApproval` | **P0 残留（越权窗口虽窄仍在）** | 把 `show()` 移进 `approvalLock` 内，且**只有"入队后成为队首"的调用方才 show**；非队首只入队 |
| **B** | `denyAllApprovals()`（Ctrl+C 整体拒绝）之后，若某调用方正处于"已入队、未 show"，它仍会 `show()` → 弹出一个**已被拒绝、按键无响应**的死弹窗（`approvalQueue` 已空，按键走输入框但弹窗盖住输出区） | 同上 | P1 观感/可理解性 | 同 A 的修法：show 前持锁校验"我仍是队首（id 仍在 approvalIds 里）" |
| **C** | Web：`approval_timeout` 以 `{"type":"error","code":"approval_timeout"}` 到达 → `closeApprovalIfOpen()` **清空整个队列**（其他仍在 TTL 内、本可答复的审批被一并丢弃），且 `setExecuting(false)`（服务端注释明确"回合继续"） | `src/web/static_assets.cj` `handleServerMessage` | **P1 回归（本轮新增）** | `case 'error'` 里先判 code：`approval_timeout`/`approval_unknown` → 只 `closeApprovalModal() + showNextApproval()`，不改 executing；前端倒计时归零时同样要推进队列 |
| **D** | `approvalAnswers` 只写不删（每个审批留一条直到进程结束）；`testApprovalQueueCtrlCDeniesAll` 没有断言两路结果都是 false | `src/tui/app.cj`、`src/tests/tui_app_test.cj` | P2 | 等待方读到结果后 `remove(id)`；补齐结果断言 |
| **E** | S2a 把 provider 变成"每次派生新建"，但 `spawnSubagent` 的 `finally` 只 `unregisterChild`，**不关闭该 provider 的池化 keep-alive 连接** → 每次派生泄漏 1 个 fd 直到 GC；且 `makeProvider()` 内部 `spawn { pp.warmup() }` → **每次派生多打一条 GET**（warmup 连接用完即 close，不复用，纯开销） | `src/entries.cj`、`src/main.cj:72` | P2 资源/浪费 | `finally { provider.abort() }`（abort 同时关 current+pooled）；`makeProvider(cfg, warmup=false)` 供子代理路径使用 |
| **F** | 无 pty 覆盖：S1 的门禁只加了 2 例单测（`handleKey` 直驱），弹窗"应答后立刻弹下一项"的渲染时序没有真实终端用例（原计划 §7 写的是 pty 1 场景） | `scripts/tui_pty_test.py` | P3 | 补 1 场景：两路审批 → `y` → 断言标题变 `(2/2)` 且第二项文案可见 |

**新发现的缺口（原方案遗漏，不是 S1 的锅）**：
- **G-A TUI 审批没有超时**。`requestApproval` 是 `while(true) + sleep(5ms)` 永久阻塞；Web 侧服务端有 300s 超时并按拒绝处理，TUI 没有 → 用户离开终端后，4 路 worker 全部永久阻塞、父回合卡死（Ctrl+C 是唯一出路）。并发越高越危险。建议 S4 一并做：TUI 侧加可配超时（默认 300s），超时=拒绝并提示。
- **G-B 并发审批缺乏"谁在等"的信息**。队列里只有 prompt 字符串，弹窗看不到 `[task:label]` 之外的身份；S3 的 `AgentNode` 落地后应把 `agentId/label` 带进审批项（TUI 弹窗 + Web 帧字段一次做完）。


### 实施前提（重要）

本机（Windows + `D:\Program Files (x86)\Cangjie`）**只能编译不能过门禁**：`scripts/test.sh` / `test_libs.sh` 是 bash + `/tmp` 路径，`cjpm.toml` 是 Linux 静态链接配置（rpath/linux stdx），且本机 `~/.cangjie/stdx` 只有 `ohos-aarch64`，没有 windows-x64 stdx。
→ **S1–S8 的实现与验证必须在 Linux 开发机（或等价环境）执行**，否则 AGENTS.md 的三道门禁（`test.sh` 549+ / `test_libs.sh` 175 / `tui_pty_test.py` 67+）无法出凭证。

---

## 8. 验收标准（用原方案的四个不变量当标尺）

| 不变量 | 现状 | 本期验收（可量化） |
|---|---|---|
| 1 权限单调 | ✅ A 期已成立 | **新增**：`writeScope` 只收窄（越界写用例必红/绿可证）；`explore` 依然物理无写工具 |
| 2 上下文单向流 | ✅ 已成立 | 简报 + 结论不变；`transcriptPath` 只落盘不回灌 |
| 3 可观测 | ⚠ B1 仍在（运行期黑盒）；**审批多路已落地**（S1 队列 + 标题 `审批(n/m)`，残留见 §7.1 A/B/C） | 面板可见每节点状态/轮次/token/当前工具；`Ctrl+T` 可看任一子代理细粒度流；审批按队员排队且超时可控 |
| 4 有界资源 | ❌（C1/C2/C5） | 并发≤4、派生≤6/回合、子代理 token 预算、300s 超时，超限均结构化失败且**不挂死**（用例证） |

门禁：`./scripts/test.sh` 全绿（552 → ~575）、`./scripts/test_libs.sh` 175 全绿（若动 `cjterm` 必须单独跑）、`python3 scripts/tui_pty_test.py`（67 → ~74）、`cjpm build` 告警仅那 5 条 `--static`、`--mock` 端到端通过。

---

## 9. 待确认决策点（建议值已给）

| # | 决策点 | 建议 |
|---|---|---|
| D5 | 是否做"额外 LLM 路由调用" | **不做**（用判定表 + 硬闸门 + 成本反馈） |
| D6 | provider 隔离方式 | ✅ 已按 **A（子代理各自实例）** 落地（S2a）；**S2b/S2c 收口建议**：`finally { provider.abort() }` 防连接泄漏 + 派生路径不触发 warmup（见 §7.1 E） |
| D11 | 是否上 provider 池（容量=并发上限，独占借用） | **先不做**。池化能省握手，但要处理借用/归还/异常泄漏；等 S4 的并发上限落地、实测握手占比后再定（当前"每次新建 + abort 收尾"已正确） |
| D7 | 冲突消解强度 | `scope` 可选 + 无 scope 的 worker 与所有 writer 串行（保守优先） |
| D8 | TUI 呈现方案 | ✅ **已确认**：三件套（主流里程碑 + Agents 面板 + 焦点切换），不做多窗格；焦点键用 `Ctrl+T`（`Tab` 已被视图切换占用） |
| D9 | 默认值 | 并发 4 / 每回合 6 / 子代理 200k token / 300s；`/parallel` 默认 `auto` |
| D10 | 本期是否含 Web 呈现 | **只带帧字段**，前端多列渲染另立项 |

---

## 10. 风险登记（补充）

1. **TUI 渲染压力**：面板每帧重算 → 只在 `onChanged` 置脏位，面板快照拷贝 ≤8 元素，可忽略；但 pty 测试矩阵必须扩（原方案风险 3）。
2. **`appendDelta` 单流限制**：焦点策略是硬约束，未来若要"多路流式同时显示"，需先把 `OutputView` 改成 per-source stream（大改，不列入本期）。
3. **软顶 15 轮与"5 轮"表述不一致**：要么把子代理 `wrapUpRounds` 配成 0（硬 5 轮，但 worker 容易半途而废），要么把 prompt 改成"5 轮软顶、收尾最多 +10"（建议后者，诚实告知）。
4. **bash 串行假象**：并发 worker 的 bash 仍 Mutex 串行（原方案风险 5）——面板里"3 个 worker 同时卡在 bash"要能解释，面板行显示 `bash(排队)` 而非静默。
5. **cost 放大**：N 路并发 = N 份 prompt；靠预算闸门 + 全树归账 + `⚠ 低效派生` 三件套兜底。
6. **键位预算紧张**：`Tab`（视图）、`Ctrl+U/D`（滚动）、`Ctrl+C`（中断，两级）已占；本期只用 `Ctrl+T`/`Ctrl+G`，其余交互（取消单个子代理、看详情）走 slash 命令（`/agents`、`/agent kill <n>`），避免继续啃键位；每加一个键都要在 pty 矩阵加回归。

---

## 11. 与既有文档的关系

- 原方案「四个不变量」保留为评审标尺，本文不改其内容。
- 原方案 §7/§8/§11.1 需同步修订：把未落地项标注清楚（B1/C1–C5/W1/T1），并把 §11.1"阶段 A+B 已落地"改为分层表述。
- 本文 §7 S1–S8 全部落地后，原方案可标记为"阶段 A+B+C 完成，D 待立项"。
