# 异步子代理与进阶能力 · 方案 D（草稿，待评审）

> 状态：**草稿 v0.1（2026-10-28）**——前置：阶段 A+B+C 全部落地（六十七轮，SDK 1.2.0 门禁全绿）。
> 本文 = 主方案 §9「D 进阶」立项稿 + 方案C 遗留决策项（D1/D10/D11）收口。
> 评审焦点：§4 异步 task 的三个生命周期决策（OA/OB/OC）——其余按既定红线推演，无需逐条过。

---

## 1. 背景与问题

### 1.1 当前形态（阶段 C 落地后）

并行子代理派发已完整实现并实测（5 路并发 + 错峰 + 限流退避扛真实服务商限流），
但派发模型仍是**同步阻塞**：

```
父回合 ── tool_call: task ──→ spawnSubagent ──→ runSubagentWithTimeout（阻塞至子代理终态）
        ↑______________全部子代理结束后才继续_________________↓
```

- `src/task.cj`：`TaskTool.execute` → 4 参 `spawnFn` → `TaskSpawnResult`（status = ok/failed/timeout/cancelled）一次性带回；
- `src/entries.cj`：`spawnSubagent` 同步等 `runSubagentWithTimeout`，finally 里 `sched.finish()` 落面板终态；
- 父回合在全部子代理结束前不产生任何新 token——**父代理空等**。

### 1.2 什么时候疼

| 场景 | 现状 | 疼点 |
|---|---|---|
| 派 3 个 explore 调查 + 父自己写大纲 | 父必须等全部调查完才开始写 | 空等 1–3 分钟，总时长 = max(子) 而非 overlap |
| 长调查（10 分钟级）+ 中途想追加要求 | 只能等完再提问 | 排队消息机制缓解但父不推进 |
| 派发的调查实际 1 轮就够（模型误判） | 父已付出整段等待 | 已有 `[路由提示]` 事后纠偏，但等待成本已发生 |

### 1.3 D 阶段三件事（主方案 §9 定义）

1. **D-A 异步 task**：`task_id + 轮询`（Swarm 式 fire-and-forget）——本文主体（§4）；
2. **D-B 代理原型库（archetype）**：预置子代理模板（§5）；
3. **D-C 跨代理工件缓存**：并发子代理共享重复读的结果（§6）。

附带收口方案C 遗留决策项：**D1** explore 快模型路由（§7.1）、**D10** Web 前端多列渲染（§7.2）、
**D11** provider 池（维持不做，理由更新见 §7.3）。

---

## 2. 继承红线（阶段 C 不变量，D 全程不破坏）

1. **权限单调**：子代理权限 ⊆ 父代理；archetype 只能**收窄**工具白名单，不得放大；
2. **上下文单向流**：子代理只见 brief + 自己的执行过程；异步化后仍不得让子代理读到父回合后续消息；
3. **可观测**：每个子代理全程可定位（AgentNode 状态机 / 转录 / 面板）；
4. **有界资源**：并发数 / token / 墙钟预算照旧生效——**异步不等于无界**；
5. **Capability 默认宽松语义不动**（配了段 ≠ 启用严格）。

---

## 3. 范围与不做

**做**：D-A 异步派发与收割、D-B archetype、D-C 工件缓存、D1 快模型路由、D10 Web 呈现。

**不做（本期明确排除）**：

| 项 | 理由 |
|---|---|
| 跨回合子代理存活（父回合结束子代理继续跑） | 与"回合=一致性边界"冲突：归账/中断/会话保存全要重设计；收益存疑（排队消息已覆盖多数场景）。见 OA 备选 |
| agent 间自由通信（子代理互发消息） | 上下文单向流红线；Swarm handoff 已够 |
| provider 池（D11） | 每次新建 + abort 收尾已正确，握手占比实测不高 |

---

## 4. D-A 异步 task（主体）

### 4.1 生命周期模型（增量最小化）

```
父回合 ── tool_call: task(async=true) ─→ spawn 后**立即返回** TaskHandle：
         { "task_id": "t-17", "status": "running", "panel": "Agents 面板照旧" }
父回合继续干活 ── 需要结果时 tool_call: task_wait(t-17) / task_status()
父回合结束（endRound）：存在未收结果的异步子代理 → 见决策 OA
```

新增/改动面：

| 组件 | 改动 |
|---|---|
| `task` 工具 | 增可选参 `async: Bool`（默认 false，同步行为**完全不变**——存量提示词零影响） |
| 新工具 `task_wait` | 入参 `task_id`（可多个）+ 可选 `timeout_ms`；阻塞至终态并返回 `TaskSpawnResult`（复用现有结构） |
| 新工具 `task_status` | 非阻塞查状态（running/ok/failed/timeout/cancelled + 已有输出摘要），供模型判断要不要等 |
| `SubagentScheduler` | 节点状态机不变；新增"悬挂子代理"簿记（agentId → 等待归属回合） |
| 归账/面板/转录 | **零改动**——spawnSubagent 内部链路（onRoundTick/markTool/finish）原样复用 |
| 协议 | v6：`task_status` 的 tool_result 帧带 task_id（Web 前端据此关联 D10 多列渲染） |

### 4.2 三个生命周期决策（评审焦点）

**OA. 父回合结束时，未收结果的异步子代理怎么办？**

| 备选 | 取舍 |
|---|---|
| A1 回合结束前**强制 task_wait 全部**（默认） | 一致性最好：归账/总结条/会话保存边界不变；父的最终答复可以引用全部结果。实现小（endRound 前收集悬挂 id 逐个收割，带剩余超时） |
| A2 结果**顺延到下一轮**（排队消息触发时注入） | 真正 fire-and-forget，但跨回合持有进程：中断传播、会话保存、面板生命周期全要改；建议缓一期 |
| A3 回合结束时**中断未完成者** | 语义最粗暴，浪费已花的 token，与"超时保留已完成"的既有语义相悖 |

**建议 A1**：异步只在**回合内**生效，回合边界仍是硬同步点。A2 作为二期（若实测确有需求）。

**OB. 同步/异步混用一批时，依赖图怎么排？**

现 DAG 按 `(path, isWrite)` 资源冲突串行。异步子代理不占父的工具执行槽，因此：
- `async=true` 的 task 调用**不进 DAG 阻塞链**（派发即返回），仅登记；
- 同批里的同步工具（如 read_file）与异步子代理**天然并行**——这正是异步的收益；
- `task_wait` 视为对所引 task_id 的**资源依赖**（join 语义），进 DAG 保证拓扑正确。

**OC. 预算怎么算？**

- 并发上限：异步子代理**照占** `max_subagents` 名额（acquire 移到 spawn 时而非收割时）；
- token 预算：`subagent_token_budget` 照旧由 scheduler 按回合归账，异步不豁免；
- 墙钟：`subagent_timeout_ms` 不变；新增 `task_wait` 自身可带 `timeout_ms`（到点返回
  `status=running` + 已有输出摘要，父可再 wait 或放弃——放弃走既有 cancelled 语义）。

### 4.3 与既有机制的交互

- **中断**：父 Ctrl+C → 中断传播链已按登记表遍历子代理，异步者同样登记（registerChild）→ 全部收割；`task_wait` 阻塞中收到中断 → 返回 cancelled；
- **审批**：子代理审批弹窗/队列与同步完全一致（panel/labels 机制复用）；
- **面板**：派发即上板（现状），`task_status` 轮询不产生额外面板刷新；
- **会话保存**：回合结束所有子代理已终态（OA-A1），会话 JSON 不需要新增引用字段。

---

## 5. D-B 代理原型库（archetype）

### 5.1 形态

```jsonc
// ~/.cjh/archetypes/reviewer.json（用户级；内置四个随二进制走）
{
  "name": "reviewer",
  "description": "代码审查：只读，聚焦缺陷与风险，输出分级结论",
  "subagent_type": "explore",            // 底层类型（决定默认资源边界）
  "tools": ["read_file", "grep", "glob", "ast_grep", "list_dir"],  // 收窄白名单（红线 1：只能收窄）
  "system_prompt_suffix": "审查时按 严重/一般/建议 分级输出，引用行号。"
}
```

- **内置四个**：`explore` / `worker`（= 现有两类，行为不变）/ `reviewer` / `test-runner`；
- **发现顺序**：项目 `.cjh/archetypes/` > 用户 `~/.cjh/archetypes/` > 内置；同名后者覆盖前者；
- **task 工具**：增可选参 `archetype: String`；与 `subagent_type` 同时给出时 archetype **优先**（其内嵌 subagent_type 决定边界）；
- **安全**：archetype 的 system_prompt_suffix 经由既有 system prompt 组装链进入子代理，**不绕过** capability 审批（红线 5）。

### 5.2 不做

- archetype 之间继承/组合（组合爆炸，等真实需求）；
- 在线市场/远端分发（供应链面，等插件信任链方案复用）。

---

## 6. D-C 跨代理工件缓存

### 6.1 设计

- **粒度**：`read_file`（path + mtime + offset/limit 窗口哈希）与 `grep`（path + pattern + mtime）；
- **存放**：进程内 `HashMap<CacheKey, (result, hits)>`，回合结束清空（与归账周期一致）；
- **共享范围**：同父的子代理树共享（父的缓存对子**只读**——上下文单向流不变，缓存不是上下文注入）；
- **失效**：mtime 变化即失效（简单正确，不做 hash 校验——文件大时 mtime 已够）；
- **可观测**：命中数进总结条（`cache 12 hits`），避免"看不见的优化"。

### 6.2 边界

- **不缓存**：bash 执行结果（副作用命令不可复用）、web_search/fetch（时效性）；
- **截断结果**：缓存截断后的形态 + spill 路径（保证语义一致）；
- **写后失效**：同树内任何 write_file/edit 命中同 path → 该 path 全部缓存条目作废。

---

## 7. 方案C 遗留决策项收口

### 7.1 D1：explore 快模型路由（本期做，小）

- 复用既有 `summaryProvider`（compaction 已在用）：`explore` 类子代理的 provider =
  `summaryProvider ?? 父 provider`（loop.cj:1205 同款取法）；
- `settings` 增 `subagent_fast_model: Bool`（默认 **false**——行为不变，用户显式开）；
- `AgentNode` 增 `model: "fast"|"main"` 字段，面板 kind 列显示 `explore·fast`；
- 验收：开了开关后 explore 子代理请求打到 summaryProvider 的 base_url（转录可查）。

### 7.2 D10：Web 前端多列渲染（本期做，前端侧）

- 协议 v5 帧已带 `agent_id` / `agent_label`（缺省不序列化）；
- SPA 按 agent_id 分列：每个子代理一个可折叠列，工具行进各自列（主流仍是父）；
- 协议**不升 v6**（帧字段零变化，纯前端）——若 D-A 的 task_status 帧带 task_id，则随 D-A 升 v6。

### 7.3 D11：provider 池——维持不做（理由更新）

1.2.0 下每次新建 + abort 收尾语义经 S2a/S2b/S2c 收口已正确；错峰派发进一步削峰；
握手成本在流式长任务里占比 <1%（转录耗时对比）。若异步化（D-A）后握手并发成为
瓶颈，再评估——届时池的正确性风险（借用/归还/泄漏）才有对应的收益体量。

---

## 8. 分期计划

| 期 | 内容 | 规模 |
|---|---|---|
| D-1 | D1 快模型路由 + D10 Web 多列渲染（独立小件，先拿收益） | 小 |
| D-2 | D-A 异步 task（OA-A1 版）：async 参数 + task_wait/task_status + 收割语义 + 协议 v6（如带 task_id） | 大 |
| D-3 | D-B archetype（内置四个 + 发现链 + task 参数） | 中 |
| D-4 | D-C 工件缓存 | 中 |

依赖：D-2 不依赖 D-3/D-4；D-3/D-4 相互独立，可与 D-2 并行；D-1 随时可做。

---

## 9. 验收清单（对应门禁）

- [ ] 同步 task 全部存量场景零回归（默认 async=false 行为逐位一致）
- [ ] 异步：派 3 个异步子代理 + 父自行产出 → task_wait 收割 → 总结条全树归账数字正确
- [ ] 异步：回合结束强制收割（OA-A1）——悬挂者全部终态、面板清空、无进程泄漏
- [ ] 中断：异步批量派发中 Ctrl+C → 全部 cancelled、面板 n/m 归零
- [ ] 预算：异步占额达 max_subagents → 后续派发 `budget_exceeded`
- [ ] archetype：收窄白名单生效；尝试放大 → 拒绝；capability_test 同批更新（红线）
- [ ] 缓存：并发 5 子代理重复读同文件 → 命中数 >0；写后失效正确
- [ ] D1：开关开启后 explore 走 summaryProvider（转录 base_url 可查）；默认关闭零影响
- [ ] D10：Web 端多列渲染 + 旧协议客户端不破（帧缺省不序列化）
- [ ] 全门禁：test.sh / test_libs.sh / pty / --mock / 零代码告警

---

## 10. 开放问题（请评审拍板）

1. **OA**：采纳 A1（回合内异步 + 边界强同步）？还是直接上 A2（跨回合存活）？
   ——A2 的真实需求依赖"派长调查 + 父继续干活"的使用频率，可以先 A1 观察一轮。
2. **task_wait 的阻塞形态**：模型调 task_wait 是一次工具调用（阻塞当前轮），是否需要
   分段等待（wait(timeout) 返回 running，模型可中途插话）？建议初版只做整段阻塞。
3. **D-C 缓存的失效粒度**：mtime 够吗？网络盘/编辑器原子写（rename）会闪变 mtime——
   建议 mtime + size 双键。
4. **archetype 数量**：内置四个够吗？是否补 `doc-writer`？
