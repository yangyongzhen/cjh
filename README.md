<div align="center">

# cjh · 仓颉语言实现的 Harness

**用华为仓颉语言从零实现的交互式编码代理（coding agent harness）。**

终端里用自然语言描述任务 → Agent 理解意图、自主规划、调用工具、观察结果、迭代直至完成。全流程在 TUI 中实时呈现，亦可通过 Web 远程驱动。

**cjh 是仓颉语言原生实现的 coding agent harness**：单二进制零依赖分发（一个文件 = 一个 agent）、语言级内存安全加持的插件信任链、以「省 token + 高执行效率」为双硬性指标的系统化工程优化。终端 TUI 与 Web 远程双驱动，并面向 **多 agent 并行编排** 演进（借鉴 swarm 等成熟范式，取并行子代理取向）。

[立项初衷](#-立项初衷仓颉原生的差异化价值) · [功能](#-功能一览) · [两大硬性指标](#-两大硬性指标) · [快速开始](#-快速开始) · [架构](#-架构) · [插件生态](#-插件生态与信任链) · [文档](#-文档) · [路线图](#-路线图)

</div>

---

## 🎯 立项初衷：仓颉原生的差异化价值

> AI 编程 agent 领域已有 codex、claude code、deepseek dsh、pi、omp 等成熟方案，功能层面已被充分验证。
> cjh 的价值，是用仓颉语言从底层把一个**完整、可运行、可复用的 coding agent harness**重新实现出来——
> 源码注释完备、可读可学习，是仓颉做 agent 的一手参考实现。
> 单二进制分发、语言级安全、多后端编译、M:N 原生并发，这些仓颉语言特性在 agent 这一真实工程场景里完整落地，并由此支撑 **多 agent 并行编排**。

立项核心命题：**主流 agent 已证明功能可行，功能堆砌无意义；仓颉独有优势才是立身之本。** 三个硬约束贯穿全部设计：

1. **不重复造轮子**：功能层面主流 agent 已证明可行，功能堆砌无意义；
2. **仓颉独有优势是前提**：别的语言能轻易做到的，不构成竞争力；取长补短，好的当然可以借鉴，但仓颉语言特性带来的差异化更值得做；
3. **生态贡献是目标**：像 dsh 的插件生态一样，让社区愿意为 cjh 贡献——这要求插件门槛足够低、分发足够顺、信任机制足够完善。

### 仓颉语言特性如何命中痛点

仓颉语言的特性恰好命中上述痛点中的 4 个。这是"为什么是仓颉"而非"顺便用仓颉"：

| 仓颉特性 | 解决的痛点 | 差异化优势 |
|---|---|---|
| **静态编译单二进制**（cjnative） | 运行时包袱、分发成本 | 无 Node/Bun/npm 依赖树，`一个文件 = 一个 agent`，<10MB |
| **强安全语言设计**（安全 DNA） | 安全模型 | 插件/技能编译期类型检查，内存安全，恶意代码风险结构性降低 |
| **多后端编译 + 终端层平台抽象**（cjnative/cjvm + 鸿蒙位） | 平台覆盖 | Linux / macOS / Windows 原生运行，鸿蒙预留；终端层 VT 输出统一 + 平台后端条件编译，一份源码多平台二进制（[方案](docs/跨平台终端层设计方案.md)） |
| **M:N 轻量线程 + 高性能** | 上下文管理、并发 | 原生并发处理流式/多 agent，低开销 |
| **国产根技术** | 信创/自主可控 | 政企、金融等敏感场景无涉外运行时依赖 |

### cjh 的差异化

面对主流 agent 的成熟方案，cjh 的差异化优势体现在：

**1. 仓颉单二进制 → 插件零依赖、分发即用**

dsh 的插件生态强大，但 Node/npm 依赖树是隐形门槛。cjh 用仓颉单二进制：插件 = 一个 shell 脚本或一个仓颉包，无运行时环境配置，`git clone` 即用。门槛降到最低，社区贡献意愿才最高。

**2. 仓颉强安全 DNA → 插件安全结构性提升**

主流 agent 的插件安全靠沙箱+审批（运行时拦截），cjh 借助仓颉编译期类型检查+内存安全，从语言层面降低恶意代码风险。叠加 SHA256 校验和 + SM2 国密签名验证（仓颉 `stdx.crypto` 原生），形成"语言层安全 + 信任链安全"双保险。

**3. 省 token + 高执行效率 → 双硬性指标全面优化**

这是 cjh 区别于"功能堆砌"的核心。参考 Pi 的省 token 工程化与 OMP 的 hashline 文件改写等成熟经验，结合仓颉语言特性做系统性优化。详见下方[两大硬性指标](#-两大硬性指标)章节。

**4. 长远目标：多 agent 并行编排**

多 agent 协作已是业界成熟范式——OpenAI Swarm（handoff 交接）、crewAI、AutoGen、LangGraph 等各有实现。**cjh 不宣称概念创新**，而是借鉴该范式、选择自己的实现取向：

| 范式 | 代表 | 协作模型 |
|---|---|---|
| handoff 交接 | OpenAI Swarm | **串行**：一个 agent 把对话交接给另一个 |
| 并行子代理 | cjh 规划（V4） | **并行**：编排器 fork 多个子代理，独立上下文并行干活 |

cjh 的取向是**并行子代理 + 上下文隔离**（类 Linux fork）：子代理只需任务局部记忆，按任务隔离上下文省 token；测试/编码/审查可并行推进。这一取向由仓颉特性天然支撑——**M:N 轻量线程**让子代理即进程内线程、调度零额外开销；**静态单二进制**让整个多代理系统就是一个文件。真正的组合优势是"并行 + 隔离上下文 + 进程内零开销 + 单文件分发"四者的落地，而非概念本身。（V4 规划中；`task` 工具已建 explore/worker 基础）

**省 token 是分工并行的核心目标，而非副产品。** 一个任务全程交给单个 agent，等同于一个人从头到尾全知——每一步都背负全局上下文，token 随任务规模持续膨胀；而团队协作的常识是：每个人只需知道与自己职责相关的部分，信息的"按需分配"理应让总消耗更低。cjh 的并行子代理正是按任务隔离上下文——子代理只携带任务相关的局部记忆，目标是**同样的任务、更少的 token**。这与 swarm 的 handoff 串行（对话整体接力、历史持续累积）形成本质区别：后者提升的是吞吐，前者同时优化成本。

> 📋 **完整功能清单**（持续更新至 v1.5.0）→ [docs/cjh功能清单.md](docs/cjh功能清单.md) —— Agent 主循环 / 15 内置工具 / 10 主题 / 插件系统与信任链 / MCP / 双平台 / 版本历史的完整盘点，随版本持续更新。

## 🌟 为什么是 cjh

| | |
|---|---|
| **仓颉原生的 Coding Agent Harness** | 从 Agent 核心、工具系统、TUI 渲染到 Web Server，全部用仓颉语言实现，是仓颉生态在 AI 编程领域的旗舰实践。 |
| **单二进制 · 零运行时依赖** | 仓颉 `cjnative` 静态编译，一个二进制跑起来，无需 Python/Node 环境。 |
| **省 token + 高执行效率** | 借鉴 Pi 的省 token 工程化（工具结果截断与回溯、自动 Compaction、prompt cache 利用），借鉴 OMP 的 hashline 文件改写（精确行级编辑、避免整文件重写），两大硬性指标全面优化。 |
| **多 Provider 开箱即用** | OpenAI / DeepSeek / GLM / Anthropic / Ollama 全兼容，`/provider` 热切换。 |
| **插件信任链** | SHA256 校验和 + SM2 国密签名验证（仓颉 `stdx.crypto` 原生），防供应链投毒。 |
| **Web 原生支持** | 内置 HTTP Server + WebSocket 流式对话 + REST API + 前端 SPA，远程驱动 Agent。 |
| **跨平台原生** | 仓颉多后端编译 + 终端层平台抽象（POSIX/Win32 后端条件编译，VT 输出统一），一份源码出多平台二进制：Linux 静态单文件 + Windows 交叉编译 exe 已实测产出，macOS 直通（[方案](docs/跨平台终端层设计方案.md)）。 |

### 价值总结（按受众）

| 受众 | 价值 |
|---|---|
| **仓颉生态** | 最完整的"仓颉做 AI 应用"参考：TUI（cjterm）、SSE 流式（cjllm）、MCP 客户端、插件 SM2 签名、跨平台终端层——五个方向的"首个"或"最完整"实现；libs/ 下 5 个独立库是可直接取用的基建 |
| **信创 / 政企** | 单二进制零依赖 + 无涉外运行时依赖 + SM2 国密签名，敏感场景下"无涉外依赖"是真实差异化 |
| **工程质量** | 441 单测 + 93 库包单测 + 67 PTY 检查（16 场景），测试真实抓出 10+ 潜伏 bug（含 edit 工具"此前从未真正工作过"）；性能优化有实测数据（prompt 峰值 42.9K→9.4K、单轮 5-22s→2-5s）；CI 门禁（测试全绿、先红后绿）强制执行 |
| **设计判断** | 截断+落盘回溯省 token（而非简单截断、不丢中间信息）；hashline 行锚点编辑；多 agent 取并行子代理+上下文隔离，并明确"不宣称概念创新，是选择实现取向" |
| **学习 / 移植** | 源码注释完备（关键路径 16%–26%，注释写"为什么"而非复述代码）+ 完整 docs 体系（架构设计、30+ 踩坑记录、工具设计文档），接手成本低 |

> **诚实定位**：cjh 不与 codex / claude code 比功能广度，价值在仓颉生态位与可直接复用、可学习的资产。多 agent 并行编排（V4）规划中（`task` 工具已提供 explore/worker 原语）；libs/ 5 库"可独立发布"但尚未发布——见[路线图](#-路线图)。

## 🎯 两大硬性指标

cjh 的核心设计目标是两大硬性指标：**省 token** + **高执行效率**。这两点直接决定 coding agent 的实用价值与成本。

### 指标一：省 token

LLM API 按 token 计费，coding agent 多轮工具调用累积 token 消耗惊人。cjh 参考 [Pi agent 的省 token 工程化](docs/pi%20agent的核心卖点.md) 的经验，从四个维度系统优化：

| 优化手段 | 实现方式 | 效果 |
|---|---|---|
| **工具结果截断与回溯** | 超阈值工具结果保留头尾 + **完整落盘** `~/.cjh/spill/<sessionId>/<toolCallId>.txt` + 省略标记含落盘路径，模型可用 `read_file` 按需读回 | 避免像某些 agent（如 d'sh）只取开头和结尾丢失中间信息；落盘回溯既省 token 又不丢信息 |
| **自动 Compaction** | 消息条数或估算 token 超阈值触发 LLM 摘要压缩早期历史，`compactThreshold` / `compact_token_threshold` / `compactKeep` 可配 | 长会话不爆上下文窗口，省 token 又防溢出 |
| **prompt cache 利用** | DeepSeek `prompt_cache_hit_tokens` + Anthropic `cache_read_input_tokens` 统计与展示 | 利用 Provider 的 prompt 缓存，重复前缀不重复计费 |
| **回合总结条** | 每轮结束显示 `✓ 2 rounds · 3 tools · 42.6s · 1.5k tokens · 99% cached` | token 消耗实时可见，便于人工干预 |

**工具结果截断与回溯的精妙设计**：不同于简单截断（只保留前 N 行），cjh 采用 **头尾保留 + 中间落盘** 策略。模型看到结果的开头和结尾（保留上下文连贯性），中间完整内容落盘到 `~/.cjh/spill/`，省略标记中包含落盘路径。当模型需要中间信息时，可用 `read_file` 按需读回。这样既大幅省 token，又不丢失任何信息——**这是 cjh 区别于简单截断 agent 的核心设计**。

工具差异化阈值（避免一刀切）：
- `bash`：2000 字符（激进截断——bash 输出常占 prompt 大头，完整结果落盘可回溯）
- `list_dir`：4000 字符
- 默认：6000 字符

### 指标二：高执行效率

coding agent 的执行效率直接决定用户等待时间。cjh 从三个维度优化：

| 优化手段 | 实现方式 | 效果 |
|---|---|---|
| **V2d 并发执行引擎** | DAG 依赖分析（从 `ToolCall` 提取资源访问 `(path, isWrite)`）+ 拓扑分组调度（同组 spawn 并发，组间串行） | LLM 并行工具调用自动并发执行，`parallelSavedMs` 实时统计节省时间 |
| **hashline 文件改写**（借鉴 OMP） | 行号锚点 `@@N` + 内容验证编辑，避免 read 整文件 + write 整文件的开销 | 大文件精确行级编辑，省 token 又快 |
| **keep-alive 连接复用** | 上一轮响应自然读完的连接入池，下一轮 `chatStream` 优先复用（单槽复用池，中断时整体关闭） | 多轮任务省 TCP+TLS 握手（实测 2-5s/轮次）；构造时预热已移除（stdx `readTimer` 后台线程 WARN 会污染 TUI，得不偿失） |

**V2d 并发引擎的 DAG 依赖分析**：每个工具调用提取资源访问 `(path, isWrite)`，自动构建依赖图。规则：
- 同一 path 且至少一个 isWrite → 串行依赖边
- 不同 path → 可并发（即使都是 write）
- `bash` 的 command 当 path 处理（不同 bash 命令可并发）

拓扑分组调度：按依赖关系分组，同一组的工具调用可并发执行；下一组必须等当前组全部完成。组内顺序保持 LLM 原始顺序（结果回填顺序）。单元素组直接串行执行（避免 spawn 开销）；多元素组 spawn 并发。

性能基线测量三维统计：
- `parallelBatches`：并发执行的批次数
- `parallelSavedMs`：并发相比串行节省的毫秒数
- `maxParallelism`：最大并发度（单组最多工具数）

### 📊 实测基准（2026-08-29，真实 LLM 任务）

> 任务：优化 shooter HTML 小游戏（deepseek-v4-flash），对比优化前后同一任务 240-300s 窗口数据。

| 指标 | 优化前 | 优化后 | 说明 |
|---|---|---|---|
| prompt 峰值 | 42.9K token（无上限爬升） | **9.4K**（压缩后重置 5-7K） | 历史压缩机制修复（见下） |
| 同窗口轮次 | 48 轮 / 300s | 15 轮 / 240s | 单轮耗时降为 2-5s（此前 5-22s） |
| 压缩触发 | 从不触发 | 每 ~5 轮自动压缩 | 双阈值：消息条数 OR 真实 prompt token |
| 工具执行耗时 | <100ms | <100ms | 框架本身非瓶颈（实测） |
| 并行工具批 | 偶发 | 实测 3 路并行 read_file | V2d DAG 引擎 |

**历史压缩机制的三次迭代修复**（`docs/疑难问题-LLM工具调用效率低.md`）：
1. 压缩检查从 `run()` 开头移入**每轮循环**——原实现单次任务几十轮内从不复查
2. 触发信号用 provider 返回的**真实 `usage.promptTokens`**——字符估算实测 7x 低估
3. `compactKeep` 12→6——否则压缩删不掉足够消息、prompt 无法重置

## 📸 界面预览

### TUI 终端界面

![cjh TUI](docs/imgs/cjh.png)

全屏 TUI：彩色 logo + 标题栏 + 对话/帮助视图标签 + 可滚动输出区（Markdown 渲染、流式增量、工具调用提示、回合总结条）+ 状态栏 + 输入框（`/` 命令下拉补全、Ctrl+E 多行编辑）。

### Web 远程界面

![cjh Web](docs/imgs/web.png)

内置 HTTP Server + WebSocket 流式对话 + REST API + 前端 SPA，浏览器远程驱动 Agent，与 TUI 共享同一套工具/插件/MCP 体系。

---

## 🚀 功能一览

### Agent 核心

- **多轮工具调用循环**：消息历史 → LLM → 工具调用 → 结果回填 → 再调用，支持复杂任务编排
- **三域 Capability 安全模型**：commands / tools / resources 白名单 + 危险操作审批链
- **自动 Compaction（后台异步）**：消息条数或真实 `usage.promptTokens` 超阈值时**后台 spawn 摘要**（不阻塞主循环），下一轮请求前 `tryGet` 非阻塞换装，未完成顺延、失败回退同步压缩，`compactThreshold` / `compact_token_threshold` / `compactKeep` 可配；手动 `/compact` 保持同步
- **项目指令**：自动加载 `AGENTS.md` / `.atomcode.md` 项目指令注入 system prompt

### 工具系统（14 个内置 + 可扩展）

| 工具 | 说明 |
|---|---|
| `bash` | 执行 shell 命令，捕获 stdout/stderr |
| `read_file` | 读取文件，大文件返回符号摘要，offset/limit 按需展开 |
| `write_file` | 写入文件（创建/覆盖） |
| `hashline_edit` | 行号锚点 `@@N` + 内容验证编辑（借鉴 OMP） |
| `edit` | str_replace 精确替换，old_string 必须唯一（或 replace_all=true） |
| `grep` | 目录树递归搜索，gitignore 感知 |
| `glob` | 文件名模式匹配，支持 `**` 跨目录（借鉴 OMP） |
| `ast_grep` | AST 结构搜索，调 ast-grep CLI（sg），降级 grep |
| `list_dir` | 列出目录树 |
| `append_file` | 追加写入文件，OpenMode.Append 增量写 |
| `todo_write` | LLM 通过工具调用管理任务列表 |
| `task` | 派发子代理执行独立任务，explore（只读）/ worker（可写）——V4 多 agent 并行编排的基础原语 |
| `web_search` | 联网搜索，多后端路由（Tavily/Exa/SearXNG/DDG）+ per-engine key rotation |
| `web_fetch` | 抓取网页，三级降级链（仓颉 HTTP → curl → Firecrawl）+ SSRF 防护 |

### LLM Provider 层

| Provider | 协议 | 说明 |
|---|---|---|
| **OpenAI** | OpenAI API | GPT-4o / GPT-4o-mini |
| **DeepSeek** | OpenAI 兼容 | deepseek-chat / deepseek-v4-flash，支持 prompt_cache_hit_tokens |
| **GLM** | OpenAI 兼容 | glm-4-flash，智谱 AI |
| **Ollama** | OpenAI 兼容（无 TLS） | 本地模型，apiKey 可空 |
| **Anthropic** | Anthropic API | Claude 系列，支持 cache_read_input_tokens |
| **MCP 服务器** | MCP 协议（stdio） | 通过 `mcp_servers` 配置接入，工具自动注册 |

- **SSE 流式解析**：逐块读取、UTF-8 安全切分、事件帧回调
- **流式累加器**：增量文本实时上屏（差分渲染逐帧刷新）
- **Provider 热切换**：`/model` `/provider` 运行时切换，历史保留

### TUI 终端界面

- **全屏 TUI**：差分渲染 + ANSI 转义，termios 原始模式（纯 libc FFI，自实现非依赖第三方库）
- **Markdown 渲染**：标题 / 列表 / 代码块 / 表格 / 链接
- **10 套主题**：starfrost（星霜青，默认）/ classic / dracula / nord / gruvbox / tokyo-night / catppuccin / rose-pine / solarized / monokai，`/theme` 实时切换，边框色随主题填充
- **视觉层次**：状态栏/用户回显/工具调用/思考块整行背景卡片 + 行内代码芯片，`NO_COLOR` 环境自动关闭全部颜色/样式转义
- **思考（推理模型）**：折叠态（默认）一行全局摘要贴消息流末尾，`Ctrl+T` 展开；展开态**逐轮交织**——每轮思考钉在**本轮回复之前**（pi transcript 阅读顺序：先看想到什么，再看那条回复），不再全堆到会话末尾；内容行两格缩进 + 灰斜体 + 背景卡片，`PageUp`/`Ctrl+U` 上滚回看历史思考；单轮超长按**中间截断**保留头尾（不再丢开头），逐轮保序保留；渲染走**增量折行 + 头段冻结**（典型帧 4459µs→311µs）
- **多行编辑器**：Ctrl+E 进入，Alt+Enter 提交
- **斜杠命令补全**：`/` 触发下拉补全
- **Tasks 面板**：Agent 内置任务列表实时展示
- **回合总结条**：`✓ 2 rounds · 3 tools · 42.6s · 1.5k tokens · 99% cached`
- **审批弹窗**：危险操作内嵌 y/n 审批
- **欢迎视图**：两栏布局（logo+模型 / Tips+会话）

### Web 支持（v1.3.0）

- **HTTP Server**：静态资源 + REST API + WebSocket
- **WebSocket 流式对话**：`ChatRequest` → `tool_start` → `tool_result` → 流式 `delta` → `done`
- **REST API**：sessions / models / tasks / health
- **前端 SPA**：原生 JS + marked.js + DOMPurify + highlight.js，6 套主题
- **auth_token 鉴权中间件** + **启动安全审计日志**

### 会话与记忆

- **树形会话**：会话分支/fork，parent 链追踪，`/tree` 树形列示
- **会话恢复**：`--resume <id>` 恢复历史会话
- **会话列表**：`--list` 列出所有会话
- **自动 Compaction**：消息超阈值自动 LLM 摘要压缩
- **工具结果截断与回溯**：超阈值结果保留头尾 + 完整落盘 `~/.cjh/spill/` + 省略标记含落盘路径

### 技能系统

- **技能即 Markdown**：`~/.cjh/skills/<name>.md`，frontmatter 声明元数据 + 工具
- **技能白名单**：`enabled_skills` 配置启用技能
- **技能携带工具**：技能 frontmatter 的 `tools` 段注册声明式工具

### 仓颉内置知识层

cjh 本身就是用仓颉写的，所以它自带一层**面向仓颉语言自身**的运行时知识：技能语料 + 离线检索 + 人显式触发的刷新链。语料是**运行时数据**（`~/.cjh/cangjie-ref/`），**不打进二进制**——知识量再涨也不影响单文件分发体积。

- **离线检索工具 `cangjie_ref`**：中文 2-gram + ASCII 词混合分词，在语料里按行召回并评分，纯本地不联网
- **技能语料**：上游 `Cangjie-SIG/CangjieSkills` 的技能正文（Markdown）；本机技能入口只留 frontmatter + 绝对路径指针，正文按需读，常驻体积大幅下降
- **刷新链**：`cjh ref update` 拉取来源 → 暂存 → 覆盖前快照 → **只对齐同名技能的 `.md`**（上游技能自带的脚本 / 知识库等非 md 资产保留）→ 重扫清单 + 自检，任一环失败**自动回滚**
- **校验与回滚**：`cjh ref verify` 按清单逐文件比对 SHA-256；`cjh ref update --restore` 从快照完整还原
- **离线承诺**：模型触发的路径永不联网；`ref update` 是唯一会联网的动作，**只能人显式触发**（TUI 里还需 `--yes` 二次确认）

```bash
cjh ref status               # 语料状态（篇数 / 字节 / 来源 / 分支）
cjh ref verify               # 校验：清单 + 逐文件 SHA-256
cjh ref rebuild              # 重扫语料重建清单（纯本地）
cjh ref search 编译报错      # 试检索，与 cangjie_ref 工具同一实现

cjh ref update --dry-run     # 预演：联网拉取但不落盘
cjh ref update               # 刷新：暂存 → 快照 → 只对齐同名技能 .md → 自检
cjh ref update --source DIR  # 从本地目录离线刷新
cjh ref update --restore     # 回滚到覆盖前快照

./scripts/install-cangjie-knowledge.sh   # 一键安装/迁移技能语料（就地瘦身为「入口指针 + 外置正文」）
```

TUI 里有等价面板：`/ref status` · `/ref verify` · `/ref rebuild` · `/ref search <关键词>` 直接出结果；`/ref update` 不带 `--yes` 时**只打印计划**（语料目录 / 来源 / 分支 / 流程），带上 `--yes` 才真正联网执行。

### 无头模式

- **JSON 模式**：`--mode json` 无头模式，输出 JSON 结果（脚本可解析）
- **CLI 模式**：`--cli` 命令行交互模式
- **Mock 模式**：`--mock` 验证模式，使用 MockProvider，无 API Key 也能测

## 🔧 快速开始

### 环境要求

- 仓颉 SDK 1.0.5+（`cjc` / `cjpm`）
- stdx 扩展标准库（Linux 版开发；打包其他平台需对应平台版，见下）
- Linux（开发环境；支持交叉打包 Windows，见下）

### 构建

```bash
# 激活仓颉环境（设 PATH；构建为静态链接单文件，无需运行时库）
source cj-env.sh

# 构建（产物为 cjh，静态链接仓颉运行时 + stdx，仅余系统库依赖，直接运行）
cjpm build

# 单元测试（自动切动态配置：静态链接下测试框架 double free 崩溃）
./scripts/test.sh          # 全量
./scripts/test.sh --filter "*Workspace*"   # 单用例
```

### 各平台打包

| 平台 | 命令 | 产物 | 说明 |
|---|---|---|---|
| Linux（默认） | `cjpm build`（cjpm.toml 已默认 `--static`） | `dist/linux/cjh-<ver>-linux-x64` | 静态链接仓颉运行时 + stdx（`ldd` 仅见 libc/libstdc++/libm 等系统库），直接分发运行，无需环境变量 |
| Windows | `./scripts/winbuild.sh` | `dist/cjh-<ver>-windows-x64.zip` | Linux 交叉编译 PE（exe + `libcangjie-runtime.dll`/`libboundscheck.dll`，stdx 静态链接进 exe，仅依赖系统库）。**前提**：`~/.cangjie/stdx/` 装 `cangjie-stdx-windows-x64-<ver>`（仓库内 `docs/cangjie-stdx-windows-x64-1.0.5.1.zip` 已备，解压即可）。**部署**：zip 解压即用，exe 与 runtime DLL 须同目录。**单文件 exe 暂不可达**：仓颉 SDK 未提供 Windows 静态 runtime（`libcangjie-runtime.a` 仅 Linux 有）——等官方支持（详见踩坑记录 §3.10） |
| macOS | POSIX 后端直通，同 Linux 源码 | — | 需 macOS 环境构建（termios 兼容，`@When` 自动选 POSIX 后端） |

> 跨平台原理：终端层 `TerminalBackend` 抽象（`@When[os == ...]` 条件编译选后端，Windows 用 Win32 Console API + VT 输出，Linux/macOS 用 termios），一份源码多平台二进制。详见 [跨平台终端层设计方案](docs/跨平台终端层设计方案.md)。

### 配置

```bash
# 设置 API Key（任选一种）
export OPENAI_API_KEY=sk-xxx        # OpenAI
export DEEPSEEK_API_KEY=sk-xxx      # DeepSeek
export DASHSCOPE_API_KEY=sk-xxx     # 通义千问
export CJH_API_KEY=sk-xxx           # 通用

# 可选：指定端点和模型
export CJH_BASE_URL=https://api.deepseek.com
export CJH_MODEL=deepseek-chat
```

### 运行

```bash
# TUI 模式（默认）
./target/release/bin/cjh

# CLI 模式（纯文本交互）
./target/release/bin/cjh --cli

# JSON 无头模式（脚本集成）
./target/release/bin/cjh --mode json "用 grep 搜索 TODO"

# 恢复历史会话
./target/release/bin/cjh --resume <session-id>

# Mock 模式（无 API Key 演示）
CJH_MOCK=1 ./target/release/bin/cjh

# Web 模式（远程驱动 Agent）
./target/release/bin/cjh web --port 8765 --token my-secret
```

### 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `CJH_API_KEY` | API Key（任一） | — |
| `CJH_BASE_URL` | LLM 端点 | OpenAI |
| `CJH_MODEL` | 模型名 | gpt-4o-mini |
| `CJH_PROVIDER` | Provider 切换（openai/anthropic/ollama） | openai |
| `CJH_MOCK` | `1` 启用 mock | 关 |
| `NO_COLOR` | 设置后 TUI 关闭全部颜色/样式转义（无障碍/管道场景） | 关 |
| `CJH_CONFIG_DIR` | 配置目录 | `~/.cjh` |

## 📁 架构

```
┌─────────────────────────────────────────────────────────┐
│             cjh 主入口 (entries.cj + main.cj)             │
│              CLI / TUI / JSON / Web / Mock               │
├─────────────────────────────────────────────────────────┤
│  TUI 层 (tui/)          │  Web 层 (web/)                │
│  差分渲染 + 按键 + 主题   │  HTTP Server + WebSocket       │
├─────────────────────────────────────────────────────────┤
│              Agent 运行时 (agent/loop.cj)                │
│        消息状态机 + 工具调用协议 + DAG 并发调度             │
├──────────────────┬──────────────────────────────────────┤
│  工具集 (tools/)  │  LLM 层 (libs/cjllm/)               │
│  bash/read/write  │  OpenAI / Anthropic / Ollama / Mock  │
│  grep/list/edit   │  SSE 流式解析 + 累加器                │
│  plugin/mcp/todo  │                                      │
├──────────────────┴──────────────────────────────────────┤
│  基础设施库 (libs/)                                      │
│  cjterm（终端UI）· cjcfg（配置）· cjutil（工具）· cjlog  │
└─────────────────────────────────────────────────────────┘
```

### 包划分

| 包 | 职责 |
|---|---|
| `cjh.agent` | Agent 主循环编排（消息状态机 + 工具调用 + DAG 并发 + 后台异步 Compaction） |
| `cjh.tools` | 工具接口、注册中心、内置工具、插件系统、MCP 客户端 |
| `cjh.tui` | TUI 应用层（对话界面、Markdown 渲染、背景卡片层次） |
| `cjh.web` | Web Server（HTTP + WebSocket + REST API + 前端 SPA） |
| `cjterm`（libs/） | **独立终端 UI 库**：ANSI / 差分渲染 / termios / Win32 跨平台终端层 / 10 套主题（纯 libc FFI 自实现，可复用） |
| `cjllm`（libs/） | **独立 LLM 协议库**：OpenAI / Anthropic / Ollama / SSE / Mock / keep-alive 复用池 / 预算竞速中断 |
| `cjcfg`（libs/） | **独立配置库**：settings.json / auth.json / 环境变量 / 会话管理 / Capability 三域模型 |
| `cjutil`（libs/） | **独立工具库**：SHA256 / SM2 签名 / UTF-8 安全解码 / JSON 修复 / BM25 / SSRF 防护 |
| `cjlog`（libs/） | **独立异步日志库**：级别控制 / 双文件落盘 / 异常堆栈提取 |

## 🔌 插件生态与信任链

### 插件系统

cjh 支持用 shell 脚本编写插件工具，`~/.cjh/plugins/<name>/plugin.json` 声明元数据：

```json
{
  "name": "echo-test",
  "version": "1.0.0",
  "tools": [{
    "name": "echo",
    "description": "Echo back the message parameter.",
    "command": "tools/echo.sh",
    "is_read_only": true,
    "parameters": {
      "type": "object",
      "properties": { "message": { "type": "string" } },
      "required": ["message"]
    }
  }]
}
```

工具脚本通过环境变量 `CJH_TOOL_ARGS` 接收参数（JSON），stdout 输出结果。

### 信任链（V3 Step 1+2）

插件可声明 `checksum` / `publisher` / `pubkey` / `signature` 四个字段，cjh 加载时自动验证：

1. **SHA256 校验和**（Step 1）：`sha256DirExcluding` 算插件目录指纹，对比 `checksum` 字段，检测文件篡改
2. **SM2 签名验证**（Step 2）：用仓颉原生 `stdx.crypto.keys.SM2PublicKey.verify` 验签，防供应链投毒

```json
{
  "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "publisher": "github:alice",
  "pubkey": "3059301306072a8648ce3d020106082a811ccf5501822d03420004...",
  "signature": "3045022100fe42fa103dbdeed8bc8c8665017583d8aa574878..."
}
```

**签名是可选的**。不带签名字段的插件照常加载，签名只是信任链加固，不强推。`settings.json` 设 `"require_signature": true` 可强制要求插件带签名。

详见 [插件签名与贡献指南](docs/插件签名与贡献指南.md)。

### MCP 协议支持

cjh 内置 MCP 客户端，支持 stdio 传输 + JSON-RPC 2.0。配置 `mcp_servers` 后，MCP 服务器的工具自动注册到 Agent：

```json
{
  "mcp_servers": {
    "my-mcp": {
      "transport": "stdio",
      "command": "node",
      "args": ["mcp-server.js"]
    }
  }
}
```

## 🧪 测试与质量保证

**441 个单元测试全绿**（根包 + `libs/cjterm` 库包 93 例，`./scripts/test.sh` 一键运行、自动切动态链接配置；库包测试需 `cd libs/cjterm && cjpm test`）+ **67 项 PTY 集成检查（16 个场景）**（`python3 scripts/tui_pty_test.py`，伪终端驱动真实 TUI），覆盖全部 15 个内置工具 + Agent 核心 + TUI 渲染/事件/思考交织 + 基础设施：

| 测试域 | 覆盖 |
|---|---|
| 工具主路径 | bash / write / append / edit / grep / glob / list_dir / hashline / todo / registry 增删改查 + 错误路径 |
| 工具边界 | read 大文件流式/offset 越界/二进制容错、grep 目录递归与 .git 跳过、glob 深嵌套/忽略目录、edit 中文/emoji/多行、hashline CRLF/单行/哈希碰撞/多锚点偏移 |
| Agent 端到端 | DAG 并行批（实测 3 路并发）、写读同 path 串行、工具结果截断 + spill 落盘完整 |
| 基础设施 | 会话保存/恢复/分支、技能 frontmatter 解析、UTF-8 容错解码/字节安全截断、WebBudget 预算、BM25 检索、web_search 路由降级链、KeyRotator 轮换 |
| 纯函数 | ToolResultTruncator 阈值/头尾/落盘、parseSgJsonLine、escapeRegex、formatToolArgs |
| **TUI 渲染与事件** | Markdown 粗体/行内代码/代码块/跨帧流式/finish 复位、Screen 差分渲染（变化行/中文/clone）、Ansi 转义序列、**TuiApp 按键协议**（Ctrl+C 退出/输入/提交/补全/视图切换/多行编辑/退格防崩） |
| **PTY 集成（真实终端）** | `scripts/tui_pty_test.py`：启动渲染、mock 工具链端到端、`/` 命令补全、帮助视图、**审批弹窗同意/拒绝**（单测无法覆盖的阻塞审批路径） |

**CI 门禁（强制，见 `AGENTS.md`）**：`./scripts/test.sh` 全绿（含 TUI PTY 场景）是唯一交付凭证；新功能/修复必须带测试；bug 修复先写复现测试再修。

**测试的价值——实测揪出 10+ 个潜伏 bug**（详见 `docs/开发文档与踩坑记录.md` 3.9 节）：

| Bug | 影响 |
|---|---|
| `edit` 替换毁文件 | 逐字节 append 把 Byte 当十进制整数输出——**edit 工具此前从未真正工作过** |
| `hashline` 必抛异常 | FNV-1a 用 UInt32 乘法溢出——**hashline 此前从未可用过** |
| grep/glob 目录搜索不递归 | 误用 `Directory.walk`（非递归 + false 终止遍历）——目录搜索只覆盖第一层 |
| append_file 静默创建 | 对不存在文件自动建文件，与 spec 不符 |
| capability 资源检查缺口 | 4 个写工具跳过 fs 白名单检查（安全模型漏洞） |
| 会话 ID 毫秒碰撞 | save/saveFork 同毫秒生成相同 ID 互相覆盖 |
| tool 消息丢 name 字段 | 会话恢复后工具名丢失 |
| glob/list_dir 静态状态竞态 | V2d 并发 + 子代理共享 registry 时互相踩踏 |

## ⌨️ 斜杠命令

| 命令 | 说明 |
|---|---|
| `/help` | 显示帮助 |
| `/new` | 开始新会话 |
| `/resume [id]` | 恢复历史会话 |
| `/model [id]` | 列出/切换模型 |
| `/provider [name] [key]` | 切换 provider |
| `/theme [name]` | 切换主题 |
| `/compact` | 手动压缩历史 |
| `/tree` | 树形列示会话分支 |
| `/fork` | 从当前会话分支 |
| `/skills` | 列出技能与启用状态 |
| `/task` | 任务管理 |
| `/settings` | 查看采样参数 |
| `/quit` | 退出 |

## 📊 版本历史

| 版本 | 主要功能 |
|---|---|
| **v1.5.0** | **仓颉内置知识层（三期）+ TUI `/ref` 面板**：新增 `cjh ref status / verify / rebuild / update` 子命令——`status` / `verify` / `rebuild` 全纯本地（`verify` 按清单逐文件重算 SHA-256，报缺失 / 被改 / 多余），`update` 是**唯一联网入口**且只能人显式触发（`--source` 离线刷新、`--repo` / `--branch` 换源、`--dry-run` 只预演、`--restore` 从覆盖前快照回滚）；覆盖前快照落语料目录之外，覆盖后重扫清单 + 自检，任一环失败自动回滚；**同名技能只对齐 `.md`**（清旧 md、保留上游非 md 资产、来源没有的技能目录不动）；`cjh ref search` 复用二期检索；TUI `/ref` 面板同步（联网动作需 `--yes` 二次确认） |
| **v1.4.0** | **仓颉内置知识层（一期 + 二期）**：一期把六篇自研技能瘦身为"描述 + 全文绝对路径"短入口（常驻 21,988 → 7,624 B）并支持从 CangjieSkills 分级收录；二期新增只读工具 `cangjie_ref`，对 `~/.cjh/cangjie-ref/` 语料纯离线检索（CJK 2-gram 分词 + 行级打分，命中带 `路径:行号` 供精读），语料不存在则不注册。技能与语料均作运行时数据，不进二进制 |
| **v1.3.28** | **展开态思考块与回复之间留空行 + 构建配置事故修复**：`Ctrl+T` 展开态下思考段与回复段原先紧贴，现每个段边界留 1 行空行（虚拟行计入滚动总行数，滚动范围不漂移；上一行本身已空则跳过，不叠双空行）；同时修复根 `cjpm.toml` 被动态测试态覆盖（v1.3.27 发布提交把 `--static` 配置换成动态配置、`version` 退回 1.3.4，导致构建产物从"静态单文件"变动态）——恢复静态基线并加固 `scripts/test.sh` 的还原 trap |
| **v1.3.27** | **思考锚点交织 + 观感优化**：思考块不再堆到会话末尾，改为每轮钉在**本轮起点**（自己那条回复之前）逐轮交织，折叠态（默认）仍是一行摘要贴消息流末尾；思考内容行去掉逐行 `› ` 前缀改**两格缩进**（同 2 显示列，折行行为零变化）；token 计数统一 **k 显示**（`fmtTokenCount`，实时状态行/思考行/回合总结条三处复用）；裸控制键（`Ctrl+O` 等 0x0F）不再泄进输入框；门禁 379 单测 + cjterm 93 + PTY 61 全绿 |
| **v1.3.26** | **Windows 粘贴三项修复 + 诊断收尾**：① 大写字母被当 Ctrl 组合（`dwControlKeyState` 位掩码写错，`0x10` 实为 SHIFT）→ `A..Z` 走 `vk-64` 解码成控制码，`M`/`J` 凭空回车/换行、`Broker`→`\x02roker`；位掩码与判定抽为平台无关纯函数 `win_mods.cj`。② 裸流粘贴批量合并的末尾早退分支（`term.cj` 第 679 行）绕过粘贴守护 → 粘贴文本的 CR 直达应用、粘贴中多次自动提交；改为走 `readGuardedRawKey()`。③ **长文粘贴"滴灌"**：drain 循环遇抬键记录即 `break`，每次 `readKey()` 只吃 1~3 条 → 6.6 秒仅投递 414 字符；改为单帧吃干（`MAX_DRAIN_RECORDS=4096` 硬预算 + 抬键记录视为已消费继续 drain），真机验证 `TERM bulk` 事件 422→8、每次一次吃干 `pending≈890` 条、粘贴整体折叠为 `[Paste #N]`。④ 按键追踪（`KeyTrace`）**恢复默认关闭**（opt-in）：仅 `CJH_TRACE_KEYS=1/on/true/yes/y/enable` 才记录，正式使用零副作用 |
| **v1.3.25** | **按键追踪默认开启（免配置）**：诊断不再依赖"记得设环境变量"——每次运行都记录到 `~/.cjh/cjh_keys.log`（与 `cjh.log` 同目录，`CJH_TRACE_FILE` 可改路径），仅 `CJH_TRACE_KEYS=0/off` 才关；启动重置 + 写头行（落点 + 版本），TUI 启动把落点写进 `cjh.log` 作面包屑；值解析容忍引号/空白/大小写 |
| **v1.3.24** | **Windows Terminal 分帧粘贴补发 Enter 改用"到达速率"判据**：WT 按帧分块投递（每帧 1~3 事件、帧间数十毫秒）使 burst 窗口与成串密度判据全部落空 → 新增 300ms 到达速率判据（非换行候选 ≥12 且换行稀疏）+ `Clock` 时钟抽象（时间逻辑可确定性单测）+ `KeyTrace` 真机轨迹设施（`CJH_TRACE_KEYS=1`） |
| **v1.3.23** | **Windows 分块粘贴补发 Enter 守护**：conhost 分波投递（波间 >15ms）使剪贴板末尾换行单独成波、判不出粘贴签名 → 旧实现当真实 Enter 提交。新增粘贴流守护窗口（200ms）+ 成串密度判据（≥8 字符），吞掉终端补发换行、不误吞真实 Enter |
| **v1.3.22** | **atomcode 式 steer**：忙时 Enter 只入队不打断（Agent 每轮 LLM 请求前拉取队列注入 user 消息）；忙时 Esc = 中断并立即发送排队消息（run 结束后作为新 turn）；Ctrl+C 两级中断不变 |
| **v1.3.21** | **Windows 粘贴带换行长文本自动提交根治**（burst 两级窗口聚合 + 粘贴签名四条件 + 重放队，对齐 atomcode reader.rs） |
| **v1.3.20** | **长粘贴软换行显示 + [Paste #N] 折叠恢复**（≥5 行/≥400 码点折叠、Enter 展开原文、输入框动态高度） |
| **v1.3.19** | **粘贴不折叠（阈值字节→码点）+ Windows 长路径状态栏折行根治 + 裸流粘贴合并** |
| **v1.3.18** | **InputBox 中文光标偏移根治（displayWidth 算列）** |
| **v1.3.17** | **Windows bash 工具 /bin/bash 不存在：Shell 降级**（Git Bash 候选 + CJH_SHELL 覆盖） |
| **v1.3.16** | **Windows TUI 框线混排根治**（双判据 isUtf8 + 主动切 65001 + BoxChars 统一边框） |
| **v1.3.15** | **P2b reasoning_effort/thinking budget 配置穿透 + compaction 后台异步化** |
| **v1.3.14** | **V3 信任链 Step 3 信任管理 CLI + 第三方插件示例**（trust/untrust/trust-list + 五库生态冷启动 v0.1.0） |
| **v1.3.13** | **P2 OutputView 增量行缓存 + P2b TUI 视觉美化**：render 每帧 O(总量) `split` 改 `lineCache` 增量维护（O(本帧文本)）；Unicode 实线边框按主题填充（10 主题 `/theme` 即时变色）+ 整行背景卡片（状态栏/用户回显/工具行/思考块）+ 行内代码芯片 + `NO_COLOR` 支持（325 单测 + 49 PTY 全绿，双平台发布包） |
| **v1.3.12** | **粘贴中文乱码根治**（bracketed paste 整段 `safeFromUtf8`）；同批含 v1.3.11 长会话 TUI 主协程停摆根治（锁泄漏 + 退出清理） |
| **v1.3.10** | **TUI 假死/无法输入根治**（cjlog sleepMs 忙等空转 → 真实 sleep） |
| **v1.3.9** | **工具输出中文乱码根治**（字节流禁止逐字节 `String(Rune(byte))`） |
| **v1.3.8** | **"连续几轮会话总被打断"根治**（空闲看门狗误杀推理模型前思考期） |
| **v1.3.7** | **首个 LLM 请求 442s 卡死 + 8 次中断全失效根治**（预算竞速下沉传输层）+ 双平台发布包修复 |
| **v1.3.4** | **TUI 交互与流式稳定性**（方向键残留/Streaming 卡死根治/忙时强制插入/粘贴自动发送） |
| **v1.3.3** | **流式传输根治 + TUI 渲染/交互打磨**（全阶段可中断 + markdown 对齐 omp） |
| **v1.3.2** | **P0+P1 优化**（bash 超时/持久会话/项目记忆/429 轮换/SQLite read）+ 静态链接单文件发布 |
| **v1.3.1** | **LLM 效率三连修复**（prompt 峰值 42.9K→9.4K）+ 13 个潜伏 bug 修复 + CI 门禁建立 |
| **v1.3.0** | **Web 支持 + 插件信任链（SHA256 + SM2 签名）** |
| v1.2.0–v1.2.3 | 并发执行引擎 / 星霜青主题 / 回合总结条 / 工具结果截断与回溯 / MCP 协议 |
| v1.1.0 | 记忆分层 + 插件系统 + 树形会话 + Ollama 支持 |
| v1.0.0 | 初始版本：TUI + Agent 循环 + 基础工具 |

> 各版本完整变更明细见 [CHANGELOG.md](CHANGELOG.md)。

## 🗺️ 路线图

### ✅ 已完成

- [x] **V1**：Agent 核心 + 工具 + 双协议 + TUI + 会话 + mock
- [x] **V2a**：三域 Capability + 审批链
- [x] **V2b Step 1+2**：plugin.json + Shell 工具插件 + 事件钩子
- [x] **V2b MCP 扩展点**：McpClient stdio + McpTool 代理 + McpManager
- [x] **V2c**：Compaction + AGENTS.md 项目指令
- [x] **V2d 并发引擎**：DAG 依赖分析 + 拓扑分组调度 + 性能基线
- [x] **V3 信任链 Step 1+2**：SHA256 校验和 + SM2 签名验证
- [x] **V3 信任链 Step 3**：信任管理 CLI（`cjh trust` / `untrust` / `trust-list`）+ 第三方插件示例（v1.3.14）
- [x] **Web 支持 Step 1-5**：HTTP Server + WebSocket + REST API + 前端 SPA + 鉴权

### 🔜 进行中

- [ ] **V2e IM 网关**：Channel 抽象 + Web 渠道 + 审批远程化

### 📋 计划中

- [ ] **V2b Step 3**：WASM 工具沙箱 + 中心仓 + `cjh install`
- [ ] **Web TLS**：`ServerBuilder.tlsConfig` 支持
- [ ] **V4 多 agent 并行编排**（借鉴 swarm 等成熟范式，取向并行子代理 + 上下文隔离）：编排器（总 agent）+ 子 agent 并行（类 Linux fork 独立工作区/上下文）+ 角色模型（项目经理/研究/编码/测试/审查）+ 契约化接口 + 编排工作流 DSL + 各 agent 独立模型路由 + 鸿蒙原生适配

## 📚 文档

- [CHANGELOG](CHANGELOG.md) — 完整版本变更记录
- [优化提速方案](docs/优化提速方案.md) — 性能优化路线图与进度总纲
- [方案与架构设计 v2](docs/方案与架构设计-v2.md) — 项目设计与架构
- [实现方案与交接](docs/实现方案与交接.md) — 架构与代码地图（新开发者接手入口）
- [cjh 功能清单](docs/cjh功能清单.md) — 完整功能列表
- [疑难问题-LLM工具调用效率低](docs/疑难问题-LLM工具调用效率低.md) — 效率优化过程与实测数据
- [插件系统实现方案](docs/插件系统实现方案.md) — 插件系统设计
- [插件签名与贡献指南](docs/插件签名与贡献指南.md) — 信任链与插件发布
- [Web 支持实现方案](docs/Web支持实现方案.md) — Web Server 设计
- [Web搜索与抓取工具设计](docs/Web搜索与抓取工具设计.md) — 搜索降级链与 key rotation
- [进度记录](docs/进度记录.md) — 开发进度与状态追踪
- [开发文档与踩坑记录](docs/开发文档与踩坑记录.md) — 仓颉工程踩坑经验
- [Pi agent 的核心卖点](docs/pi agent的核心卖点.md) — 省 token 设计借鉴
- [OMP agent 的核心卖点](docs/omp agent的核心卖点.md) — hashline 改写借鉴
- [工具结果截断与回溯方案](docs/工具结果截断与回溯方案.md) — 省 token 核心设计
- [工具执行效率差距分析](docs/工具执行效率差距分析.md) — 执行效率优化

## 🤝 仓颉生态价值

cjh 是仓颉语言在 **AI 编程代理**领域的完整实践。开发过程中沉淀出 **5 个零依赖（或仅官方 stdx）的独立仓颉库**，已自包含可独立发布，贡献仓颉生态：

| 库 | 定位 | 依赖 | 发布难度 |
|---|---|---|---|
| [**cjterm**](libs/cjterm/README.md) | 终端 UI 组件库：ANSI 控制 / 差分渲染 / 输入框/编辑器/表单/列表选择等组件 / **跨平台终端层**（termios + Win32 Console，`@When[os]` 条件编译） | 零依赖 | ★ |
| [**cjlog**](libs/cjlog/README.md) | 异步日志库：级别控制 / 双文件落盘 / 异常堆栈提取 | 零依赖 | ★ |
| [**cjconfig**](libs/cjconfig/README.md) | 通用分层配置库：环境变量 > 配置文件 > 默认值 / 声明式字段 / 自动模板 / 保留用户扩展 | 仅 stdx.json | ★ |
| [**cjutil**](libs/cjutil/README.md) | 通用工具库：UTF-8 安全截断 / SHA-256 / 国密 SM2 / 网页正文提取 / BM25 检索 / HTML→Markdown / JSON 修复 / SSRF 防护 / 跨平台 FFI | 官方 stdx | ★★ |
| [**cjllm**](libs/cjllm/README.md) | LLM 协议库：OpenAI 兼容 / Anthropic Messages / Ollama / Mock，流式 + 工具调用 + token 统计 + mojibake 修复 | cjutil+cjlog+stdx | ★★★ |

> 每个库均含独立 README、MIT LICENSE、可运行示例（`examples/`）、CI 模板、发布指南（`docs/发布指南.md`）。发布方式：独立仓库推送 atomgit（Cangjie-TPC）→ 打 tag → 可提交 pkg.cangjie-lang.cn 中心仓 → 向 Cangjie-SIG 请求收录。详见 [libs/README.md](libs/README.md)。

cjh 对仓颉生态的其他贡献：

| 贡献 | 说明 |
|---|---|
| **MCP 协议实现** | 仓颉语言首个 MCP 客户端实现（stdio 传输 + 工具注册），为仓颉生态接入 MCP 工具网络铺路 |
| **插件信任链** | 仓颉 `stdx.crypto` 国密 SM2 在插件安全场景的实践范例（SHA256 校验 + SM2 签名） |
| **跨平台终端层** | `TerminalBackend` 抽象 + 条件编译（termios / Win32），仓颉 TUI 跨平台的标准范式（[方案](docs/跨平台终端层设计方案.md)） |
| **工程踩坑经验** | 完整记录仓颉开发中的 FFI / 条件编译 / 静态链接 / 并发 / TLS 等坑点（[开发文档与踩坑记录](docs/开发文档与踩坑记录.md)），降低后来者门槛 |

## 🔨 开发

### 开发一个工具

```cangjie
public class GrepTool <: CjhTool {
    public init() {}
    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("要搜索的正则"))
        props.add("path", JsonSchema.str("搜索路径"))
        return ToolSpec("grep", "在文件中搜索文本",
            JsonSchema.object(props, ArrayList<String>(["pattern", "path"])))
    }
    public func execute(args: JsonObject): ToolResult {
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        // ... 实现搜索
        return ToolResult("结果", false)
    }
    public func isReadOnly(): Bool { true }
}

// 注册
let registry = ToolRegistry()
registry.register(GrepTool())
```

### 项目结构

```
cjh/
├── src/                    # 主程序
│   ├── entries.cj          # 业务装配入口（CLI/TUI/JSON/Web/Mock 分流）
│   ├── main.cj             # 程序入口（provider 工厂 + 模式分发）
│   ├── agent/              # Agent 主循环 + DAG 并发调度 + 工具截断器
│   ├── tools/              # 工具系统（14 内置工具 + 插件 + MCP）
│   ├── tui/                # TUI 应用层
│   ├── web/                # Web Server（HTTP + WS + REST + 前端）
│   ├── gateway/            # Channel 抽象（IM/Web 渠道网关）
│   ├── skills.cj           # 技能系统（frontmatter 解析 + 指令注入）
│   ├── ast_grep.cj         # AST 搜索工具（sg CLI + grep 降级）
│   ├── tests/              # 单元测试（工具/会话/截断器/路由/TUI 渲染/思考交织/性能优化，441 用例）
│   └── core_funcs_test.cj  # 根包纯函数测试（skills/tool_format/ast_grep/task）
├── libs/                   # 独立可复用库
│   ├── cjterm/             # 终端 UI 库（ANSI / 差分渲染 / termios / 主题）
│   ├── cjllm/              # LLM 协议库（OpenAI / Anthropic / Ollama / SSE）
│   ├── cjcfg/              # 配置库（settings.json / auth.json / 会话）
│   ├── cjutil/             # 工具库（SHA256 / SM2 / UTF-8 / JSON 修复 / BM25）
│   └── cjlog/              # 日志库
├── build.cj                # cjpm 构建钩子（产物 main → 复制为 cjh）
├── example/                # 示例
│   ├── plugins/            # 插件示例（echo-test / log-pruner / signed-demo）
│   └── mcp/                # MCP 服务器示例
├── docs/                   # 文档
└── cjpm.toml               # 仓颉包管理配置
```

## 📄 License

MIT
