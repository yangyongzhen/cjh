# cjh 优化方案（对标 omp）

> 最后更新：2026-08-29
> 性质：迭代方向清单 + 实施状态追踪（防遗忘）
> 对比基准：omp（Oh My Pi）核心卖点（hashline/LSP/DAP/双内核/并行子 Agent/流规则/Hindsight 记忆/进程内工具）
> 优先级：P0=可靠性/可用性硬伤；P1=重要性价比高；P2=增强/远期

---

## 执行状态总览

| 优先级 | 项 | 状态 | 提交 |
|---|---|---|---|
| P0 | bash 工具超时 | ✅ 已实施（默认 60s，CJH_BASH_TIMEOUT 可配，timeout 命令包装 + base64 传命令） | 待提交 |
| P0 | Ctrl+C 中断当前轮 | ✅ 已实施（忙时中断 agent、空闲两次退出、审批拒绝保持） | 待提交 |
| P1 | 持久 bash 会话 | ⏸ 暂缓——std.process 管道 `read` 阻塞无超时，命令挂死会卡死读循环（违背 P0-1）；需先解决非阻塞读/进程 kill 能力 | — |
| P1 | task 结构化返回 + 并行引导 | ✅ 已实施（spec 加并行引导；结果 `=== 子代理结果 ===` 结构化标记） | 待提交 |
| P1 | 模型路由（摘要快模型） | ✅ 已实施（settings `summary_model/base_url/api_key`，compaction 摘要走快模型）；429 fallback ⬜ 待做（需 openai.cj 请求层 key 轮换） | 待提交 |
| P1 | 跨会话项目记忆（Hindsight 式） | ✅ 已实施（会话结束写 `~/.cjh/project-memory/<project>.md`，新会话注入 system prompt） | 待提交 |
| P1 | read 支持 SQLite | ✅ 已实施（.db/.sqlite/.sqlite3 走 sqlite3 CLI，表列表+每表前 20 行；无 sqlite3 时明确提示） | 待提交 |
| P1 | compaction 保留工具结果 | ✅ 已实施（assistant 文本进摘要，tool_call/tool_result 保留原文） | 待提交 |
| P1 | 提示词优化包 | ✅ 已实施（读-改-验循环、工具失败重试、批量并行示例、上下文预算） | 待提交 |
| P2 | LSP 集成（diagnostics/rename/references） | ⬜ 规划 | — |
| P2 | eval 持久内核（Python 回调 cjh 工具） | ⬜ 规划 | — |
| P2 | 流规则（流式正则拦截注入） | ⬜ 规划 | — |
| P2 | /review reviewer 子代理 | ⬜ 规划 | — |
| P2 | 跨轮自动并行（合并独立只读） | ⬜ 规划 | — |
| P2 | 配置继承（CLAUDE.md/.cursor/rules） | ⬜ 规划 | — |
| P2 | DAP 调试器 / 首 token 延迟 / prompt 前缀稳定 | ⬜ 规划 | — |

---

## P0 — 可靠性/可用性硬伤

### P0-1 bash 工具超时

**问题**：`BashTool` 无超时——`git pull`/构建/网络命令卡死会**永久挂起 agent 整个会话**（实测风险）。

**方案**：
- `BashTool` 支持超时（默认 60s，`CJH_BASH_TIMEOUT` 或 settings 可配）
- 超时 kill 整个进程树（bash 的子进程也要杀）
- 返回 `isError=true` + 提示"命令超时（N 秒）"，附已捕获的部分输出

### P0-2 Ctrl+C 中断当前轮而非退出

**问题**：当前 Ctrl+C 直接关 TUI，正在执行的 agent 轮次（工具调用/模型流式）上下文全丢；用户想打断卡住的工具/模型时只能自杀式退出。

**方案**：
- agent 忙时 Ctrl+C → 设置中断标志：工具执行完/轮次间中止循环，保留已完成工作，返回部分结果
- agent 空闲时 Ctrl+C → 第一次提示"再按 Ctrl+C 退出"，第二次退出
- 审批等待中的 Ctrl+C 保持原语义（拒绝审批）
- 中断后提示"已中断，可继续提问"

---

## P1 — 重要、性价比高

### P1-3 持久 bash 会话

**问题**：每次 `bash -c` 都是全新 shell——`cd`/export 不保留，多步构建/测试反复重设环境（omp 内嵌 brush shell 持久会话是效率关键）。

**方案**：
- `BashSession`：spawn 持久 bash 进程（交互模式），跨调用保留 cwd/env
- 命令写 stdin + 独特分隔符读 stdout，支持超时
- 并发安全（Mutex）；失败自动重启会话
- BashTool 默认走持久会话（可配置关闭）

### P1-4 task 结构化返回 + 并行引导

**问题**：task 返回纯文本；模型很少发多个并行 task（无提示词引导）；无隔离工作区。

**方案**：
- task 工具描述加"可并行派发多个独立子任务"引导
- 结果格式化为结构化文本（Findings/Summary/Status 段），主 LLM 易 parse
- 子代理 explore 用快模型（配合 P1-5）

### P1-5 模型路由（摘要快模型 + 429 fallback）

**问题**：compaction 摘要/子代理调用 10-100s 是隐藏时间黑洞（实测）；无 429 fallback。

**方案**：
- settings 加 `summary_model`/`summary_base_url`/`summary_api_key`：compaction 摘要 + explore 子代理走快模型
- 429/限流自动 fallback：备用 key/provider 轮换（复用 KeyRotator 思路）

### P1-6 跨会话项目记忆（Hindsight 式）

**问题**：只有会话树 + 静态 AGENTS.md，隔天回来 agent 对项目一无所知（omp Hindsight 是核心卖点）。

**方案**：
- 会话结束（onRunComplete）→ 压缩关键信息（任务/决策/文件/命令）→ 写 `~/.cjh/project-memory/<cwd-hash>.md`（限 1 条，防膨胀）
- 新会话启动注入 system prompt（"项目记忆"段）
- 复用 compaction 摘要逻辑

### P1-7 read 支持 SQLite

**问题**：调试数据类任务只能 bash sqlite3（omp"一切皆路径"，read 直接读 SQLite 表/行）。

**方案**：
- ReadTool 检测 `.sqlite/.sqlite3/.db` → SQLite 模式（调 sqlite3 CLI：`.tables` / `SELECT * FROM x LIMIT n`）
- 输出带表结构 + 行数据，行数限制防爆上下文

### P1-8 compaction 保留工具结果

**问题**：当前 LLM 摘要会丢工具结果细节，压缩后 agent"失忆"。

**方案**：
- 压缩输入：tool_call/tool_result 消息保留原文，仅 assistant 纯文本消息进摘要
- 重建：system + 摘要 + 保留的工具消息 + 最近 keep 条
- 摘要请求可配快模型（配合 P1-5）

### P1-9 提示词优化包

**问题**：实测模型仍倾向每轮 1 工具；"Keep responses short"已加但批量/重试引导不足。

**方案**（纯提示词迭代）：
- 读-改-验循环："read → edit → verify with bash" 三段式明示
- 工具失败重试："工具失败先看错误原因，修正参数重试，不要换工具重做"
- 批量并行具体示例："读 3 个文件 = 1 轮发 3 个 read_file"
- 上下文预算："bash 输出会被截断到 2000 字符，需要完整输出用 read_file 读 spill"

---

## P2 — 增强/远期（规划，不实施）

| 项 | 说明 |
|---|---|
| LSP 集成 | diagnostics/rename/references 走协议（omp 最大差异；先单语言） |
| eval 持久内核 | Python 内核可回调 cjh 工具（数据分析） |
| 流规则 | 流式正则命中 → 中断 → 注入规则 → 重试（模型守规矩终极方案） |
| /review | 专用 reviewer 子代理，P0-P3 分级输出 |
| 跨轮自动并行 | 模型每轮 1 工具时合并多轮独立只读（高风险谨慎） |
| 配置继承 | 自动读 CLAUDE.md/.cursor/rules 等 |
| DAP 调试器 | lldb/dlv/debugpy 集成 |
| 首 token 延迟 | SSE 解析缓冲优化 |
| prompt 前缀稳定 | 提高 provider 缓存命中率 |

---

## 已对齐 omp 的能力（无需再规划）

- ✅ Hashline 编辑（hashline_edit，@@N 行号锚点 + 内容验证 + 偏移校正）
- ✅ 结构化 read 摘要（大文件符号摘要 + 按需展开）
- ✅ 进程内 grep/glob（零 fork/exec）
- ✅ 子 Agent（task：explore/worker）
- ✅ 工具结果截断 + 落盘回溯（spill）
- ✅ Compaction（双阈值：消息条数 + 真实 prompt token）
- ✅ TUI（差分渲染/主题/审批弹窗/Tasks 面板/多行编辑）
- ✅ 测试体系（216 单测 + 36 PTY 集成）

---

> 备注：本方案随实施持续更新。每完成一项更新状态表 + 记录提交。
