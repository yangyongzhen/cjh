# CHANGELOG

cjh 版本变更记录。依据 git tag 史 + 提交史整理；版本号规则：重大更新递增中间位（v1.2.0→v1.3.0），小更新递增最后位（v1.3.14→v1.3.15）。

> 注：v1.0.0 / v1.1.0（首个 tag 前）/ v1.2.2 / v1.3.0 / v1.3.5 等版本未打 tag，日期与内容按提交史还原，以「无 tag」标注。

## [v1.3.15] - 2026-09-06

### Fixed
- **回合统计 `0% cached` 统计缺口**：`StreamAccumulator` 只解析 DeepSeek 顶层 `prompt_cache_hit_tokens` 与 Anthropic `cache_read_input_tokens`，未解析 OpenAI 标准 / 智谱 GLM 等 OpenAI 兼容接口的**嵌套字段** `usage.prompt_tokens_details.cached_tokens`——跑 GLM/OpenAI 兼容 provider 时缓存命中恒为 0，状态条永远显示 `0% cached`（实际缓存可能已命中）。现按优先级解析：顶层两字段优先，嵌套字段兜底（仅当缓存值仍为 0 时读取），`prompt_tokens_details` 非对象时容错不抛异常。

### Tests
- +3 用例（`libs/cjllm/llm_test.cj`）：嵌套 `cached_tokens` 解析（GLM 真实形态 5300/12/4988）、命中为 0 与异常形态容错、顶层字段优先级
- 门禁：cjllm 34/34 + 根包 335/335 全绿 + build + --mock

## [v1.3.14] - 2026-09-06

### Added
- **V3 信任链 Step 3：信任管理 CLI**（`~/.cjh/trusted-publishers` + `cjh trust/untrust/trust-list`）：
  - 信任列表文件 `~/.cjh/trusted-publishers`（每行一个 publisher ID 或 SM2 公钥 hex，`#` 注释）
  - **空列表 = 开放模式**（默认，向后兼容）；**非空 = 严格模式**：签名插件 publisher/pubkey 必须命中列表，不匹配拒绝加载并提示 `cjh trust <publisher>`；无签名插件严格模式下同样拒绝
  - 信任列表随 `loadPlugins` 注入 `PluginManager`，与 Step 1 校验和 / Step 2 SM2 验签串联成完整信任链
- **第三方风格插件示例**（`example/plugins/`）：git-status 工具插件 + tool-result-banner 钩子插件，附加载/执行/钩子触发的单测（`example_plugins_test.cj`），锁住 plugin.json 加载契约

### Docs
- `docs/插件签名与贡献指南.md`：Step 2/Step 3 状态更新为已实现，补信任列表语义说明与信任链完整流程
- README（中英）：价值主张正面化 + 按受众价值总结表（源码注释完备、可读可学习）

### Tests
- +7 信任用例（`core_funcs_test.cj`：解析/增删/匹配/端到端强制加载——真实 SM2 签名插件在开放/严格×匹配/不匹配下行为）
- +3 插件示例用例（`example_plugins_test.cj`）
- 门禁 335 单测全绿 + `--mock` 端到端通过 + 信任 CLI 三命令实测

## [v1.3.13] - 2026-09-06

### Added
- **P2 OutputView 增量行缓存（优化提速方案 G4）**：render 每帧对全量缓冲 `split("\n",-1)`（O(总量)，长会话卡主循环）改 `lineCache` 增量维护——`append`/`appendDelta`/`ensureNewline` 走 O(本帧文本) 增量，`endStream` 全量重建；渲染输出逐位不变
- **P2b TUI 视觉层次美化**：状态栏边框 `+--` → Unicode `┌┐─` 实线；状态栏 bg234 / 用户回显 bg237 / 工具调用行 bg236 / 思考块 bg233 整行背景卡片（`padBg` 统一补 `cols-1`）；行内代码芯片（fg250+bg236）
- **`NO_COLOR` 支持**：设置后 TUI 全部颜色/样式转义返回空串（无障碍/管道场景）
- **TUI 主题扩至 10 套**：新增 dracula / nord / gruvbox / tokyo-night（v1.3.0 批次加入），`/theme` 实时切换
- 双平台发布包：`dist/linux/cjh-v1.3.13-linux-x64` + `dist/cjh-v1.3.13-windows-x64.zip` + SHA256SUMS

### Fixed
- **TUI 边框恒灰根治**：`Theme.apply()` 早已写回 `Ansi.THEME_BORDER = p.border`，但主题表无一处赋值 `.border` → 10 主题全部静默回退默认 244。修复：每个主题显式设 `.border`（同色系醒目色，如 starfrost 73 / dracula 177 / gruvbox 208），`/theme` 切换边框即时变色
- 整行背景卡片内 `Ansi.reset()` 断裂问题（`Logo.badge` 嵌入点改 `fg()` 重设）

### Changed
- 性能：流式长会话渲染 CPU 成本从 O(总量) 降至 O(本帧新增文本)

### Tests
- +12 用例（`outputview_linecache_test.cj`，行缓存与 `content().split` 逐位等价，含首/尾空串边界）；门禁 325 单测 + PTY 15 场景 49 断言全绿

## [v1.3.12] - 2026-09-04

### Fixed
- **粘贴中文乱码根治**：复制中文粘贴进 TUI 输入框变 `å¥½` 类 Latin-1 乱码。根因 = `readBracketedPaste` 逐字节 `Rune(Int32(byte))` 拼接（与 bash 输出乱码同款，bracketed paste 独立路径漏网）。修复：字节累积到 `ArrayList<Byte>` + 字节层结束标记匹配 + 整段 `safeFromUtf8` 解码（cjterm 新增 cjutil 依赖）

### Tests
- +8 单测（`TermPasteDecodeTest`）+ PTY 场景13（真实粘贴中文/emoji 进输入框）；290 单测全绿

## [v1.3.11] - 2026-09-04

### Fixed
- **长会话 TUI 主协程停摆 + 泄漏 bash/僵尸根治**：51 轮 43 分钟重 bash 会话后 TUI 停摆（按键无响应、画面冻结、终端停留 raw）。根因两条叠加：① 9 处裸 `Mutex.lock()` 未 `try/finally` 守护，持锁临界区抛异常即锁泄漏 → 主循环与流式回调双双 park → 仓颉"无可运行协程"stop 路径；② 退出路径不清理子进程 + `killSession` 只 terminate 不 wait → 僵尸 + 泄漏会话 bash
- 修复：全部裸 `lock()` 加 `try/finally` 守锁 + `run()` 每帧 try/catch 兜底 + `finally→restoreTerminal`；`killSession` 加 `wait(5s)` 回收；退出清理（close bash / disconnect MCP / `Log.shutdown`）；mock 加 `CJH_MOCK_BASH` 门控驱动真实会话

### Tests
- +3 回归用例 + 退出路径 PTY（无残留子进程、终端 raw=False）；282 单测全绿

## [v1.3.10] - 2026-09-03

### Fixed
- **TUI 假死/无法输入根治**：画面冻结无法输入但进程存活 CPU 100%。根因 = `cjlog.LogSink` 异步日志的空闲节流 `sleepMs` 写成纯整数忙等（`while (i < ms*1000)` 自增不耗时），sink 协程在仓颉主 worker 上满速自旋，饿死 TUI 渲染/输入主循环。修复：改真实 `sleep(Duration.millisecond * ms)`

### Tests
- +1 回归用例（耗时断言先红后绿，78µs 空转→真实 ~80ms）；280 单测全绿

## [v1.3.9] - 2026-09-03

### Fixed
- **工具输出中文乱码根治**：bash 会话 stdout 显示 `éè¯»...`（中文 UTF-8 字节被逐字节当 Latin-1 码点）。根因两处同类 bug：① `bash_session.readUntilMarker` 逐字节 `String(Rune(byte))` 拼 stdout；② `web_search.urlDecode` 的 `%XX` 逐字节转字符。修复：整段/字符边界 `safeFromUtf8` 解码（bash 路径维护跨块 pending 字节）

### Tests
- +4 回归用例（bash 中文跨 4096 读取边界先红后绿 + urlDecode 3 组）；279 单测全绿

## [v1.3.8] - 2026-09-03

### Fixed
- **"连续几轮会话总被打断"根治**：空闲看门狗误杀推理模型"前思考期"——用户反馈几乎没法用，连续对话被"模型 Ns 无响应"反复中断。curl 直连铁证：模型没停滞（300s 发 12269 帧全是 reasoning）。根因全在客户端：① `agentLastActivity` 跨 run 不重置（上轮旧帧污染新轮判定）② 空闲预算默认 60s 过激进（doc 写 180s）③ token 估算跨轮残留（0.0K 显示）。修复：run 启动 + onThinking 每轮重置锚点、默认 60→180s、`resetAgentTokens` 每轮清零

### Tests
- +3 回归用例 + 真实模型 PTY 连续 3 轮全通过（看门狗/强制插入 0 条）；275 单测全绿

## [v1.3.7] - 2026-09-02

### Fixed
- **双平台发布包修复**：打包时发现 HEAD 的 cjpm.toml 静态链接配置早被连带清空（README 声称默认静态，实际产动态二进制，v1.3.5~v1.3.7 连续 3 版无人察觉）；winbuild.sh 的 stdx 路径指向 dynamic/ 致 Windows exe 动态挂 12 个 libstdx DLL。修复：恢复 `--static --static-std --static-libs` + static/stdx 路径

### Changed
- **预算竞速下沉传输层**：`runWithBudget` 从 openai.cj 调用点下沉进 `HttpStreamClient.connect()/request()` 内部——anthropic/ollama/**未来任何复用传输层的新协议零改动自动获得保护**（connect 预算=idleTimeout 且重试一次、request 预算=writeTimeout 30s）

### Tests
- +1 黑洞地址回归用例（TEST-NET 实测裸 connect 8s+ 挂起 → 预算 1s 时 ~2s 抛 BudgetTimeoutException）；272 单测全绿

## [v1.3.6] - 2026-09-02

### Fixed
- **首个 LLM 请求 442s 卡死 + 8 次中断全部失效根治**：根因 = 仓颉裸 `TcpSocket.connect`（DNS/TCP/TLS）无超时参数 × `HttpStreamClient.abort()` 只 close 已建的 socket、connect 挂死期间 socket==None 空转。修复：新增 `cjutil.runWithBudget` 预算竞速原语（spawn + Future.get 轮询 + cancelChecker + 预算），openai.cj 四处窗口（connect×2 / request×2）全部包上

### Tests
- +5 cjutil 用例；272 单测全绿

## [v1.3.5] - 2026-09-02（无 tag）

### Fixed
- **TUI 僵尸忙态根治**（"Streaming… 永不结束 + 排队永不发送"事故）：根因 = 仓颉 `String[0..N]` 字节切片校验 UTF-8 边界 × spawn 未捕获异常静默杀任务线程——`summarizeForMemory()` 的 `task[0..60]` 在中文摘要上必炸，且调用点在 spawn 收尾块 try 之外 → `setAgentRunning(false)` 永不执行。修复：切片改 `truncateUtf8` + 收尾块独立 try/catch 兜底。**技术债"偶发 UTF-8 异常"正式闭环**

### Tests
- +3 回归测试（事故真实数据）；269 单测全绿

## [v1.3.4] - 2026-09-01

### Fixed
- **Streaming 卡死根治**：空闲预算 180→60s + timedOut 内容保留不重试（代理 keep-alive 不发完成标记时的"卡→重试→又卡"死循环）；事件级空闲预算（内容不再增长 + 时间流逝即结束回合）
- **粘贴自动发送修复**：启用 bracketed paste（`ESC[?2004h`）+ `readBracketedPaste` 连续空闲判定（原 1.5s 总超时漏闭合标记）
- 连按方向键残留字母（AAAA/BBBB）：CSI 序列 next 已是终结字母仍多读吞序列
- Windows 方向键识别加固（vkToKeyEvent 改 if-else——交叉编译 match 常量比较异常）
- markdown 表格底边框后另起一行

### Added
- 忙时 Enter 强制插入发送（打断当前回合 + 排队，对齐 omp followup）
- 帮助页补全（/provider /skills /compact /tree /fork /task /theme + 输入技巧 + 快捷键）且超屏可滚动
- 看门狗回归测试（keep-alive 空帧停滞场景）

### Tests
- 269 单测 + 46 PTY 全绿

## [v1.3.3] - 2026-08-31

### Fixed
- **流式传输根治**：finish_reason / 短读轮询 / 响应头轮询全阶段可中断（此前只包了部分阶段，中断在轮询窗口全失效）；大 chunk 越界修复
- markdown 渲染对齐 omp：ATX 标题主题色 / 表格完整边框 / python 内置函数高亮；思考块配色对齐 omp

### Added
- 轮次软顶（默认 100 + 收尾指令）
- 两级 Ctrl+C 兜底（任务中打断/强退，空闲一次退出）

### Tests
- 261 单测 + 41 PTY 全绿

## [v1.3.2] - 2026-08-29

### Added
- **bash 超时 + Ctrl+C 中断当前轮** + 持久 bash 会话（`BashSession` 跨轮复用）
- **跨会话项目记忆**（AGENTS.md 注入 + 会话存档）
- **摘要快模型路由**（compaction 走快模型，实测主模型摘要 10-100s → 快模型数秒）
- **429 备用 key 轮换**（`fallbackKeys` 自动切换）
- compaction 保留工具结果；read_file SQLite 支持；提示词优化

### Changed
- **静态链接单文件发布**：cjpm.toml 默认 `--static --static-std --static-libs`，Linux 产物单文件零依赖（含仓颉运行时+stdx）

### Tests
- 228 单测 + 36 PTY 全绿

## [v1.3.1] - 2026-08-29

### Fixed
- **LLM 效率三连修复**：① compaction 检查从 run() 开头移入每轮循环（原实现单次任务几十轮内从不复查）② 触发信号用真实 `usage.promptTokens`（字符估算实测 7x 低估）③ `compactKeep` 12→6（否则压缩删不掉足够消息）——prompt 峰值 42.9K→9.4K
- **10 个潜伏 bug 修复**：edit 替换毁文件（Byte 当十进制输出）、hashline FNV-1a 溢出、grep/glob 目录搜索不递归、append_file 静默创建、capability 资源检查缺口、会话 ID 毫秒碰撞、tool 消息丢 name、glob/list_dir 静态状态竞态等

### Added
- **单测纳入 CI 门禁**（AGENTS.md 项目指令：`cjpm test` 全绿为唯一交付凭证）
- 每轮过程日志（cjlog 独立异步日志库，双文件落盘）
- build.cj 产物改名 cjh（cjpm 固定输出 main，post-build 复制）

### Tests
- 单测扩至 182 全绿

## [v1.3.0] - 2026-08-28（无 tag）

### Added
- **Web 支持**：内置 HTTP Server + WebSocket 流式对话（`ChatRequest`→`tool_start`→`tool_result`→流式 `delta`→`done`）+ REST API（sessions/models/tasks/health）+ 前端 SPA（原生 JS + marked.js + DOMPurify + highlight.js）+ auth_token 鉴权中间件 + 启动安全审计日志
- **插件信任链**：SHA256 校验和（Step 1）+ SM2 国密签名验证（Step 2，仓颉 `stdx.crypto` 原生）+ `require_signature` 配置
- V2e IM 网关 Channel 抽象（Web 渠道重构）
- **4 套经典主题**：dracula / nord / gruvbox / tokyo-night（TUI 主题 6→10）
- Web 前端 skills/mcp 侧边栏 + settings 配置页 + 流式 Markdown 渲染优化

### Tests
- Web 协议端到端验证（python WS 客户端实测 28 帧流式）

## [v1.2.3] - 2026-08-24

### Added
- **OMP 风格写入架构**：write_file 整段写入 + append_file 续写 + hashline 行锚点编辑三件套，英文 prompt 引导工具选择
- **cjutil 底层包抽离**（通用工具独立：UTF-8 安全解码 / 字节安全截断）

### Fixed
- JSON 截断容错（repairTruncatedJson）+ write_file 工具描述改进
- UTF-8 安全解码防 TUI 崩（非法字节容错 U+FFFD）

## [v1.2.2] - 2026-08-24（无 tag）

### Added
- **回合总结条**：每轮结束 `✓ N rounds · M tools · Xs · Y tokens · Z% cached`（`ModelResponse.usage` 新增 `TokenUsage`，三协议 usage 解析）
- **/compact + /tree + /fork**：手动压缩 + 树形会话列示/分支
- **星霜青主题系统** + `/theme` 交互式选择器（方向键选择）

### Fixed
- 回复左右留白 + 空行分隔；状态栏边框输入框可见性

## [v1.2.1] - 2026-08-24

### Added
- 星霜青主题（品牌色 73）落地 + `/theme` 切换命令
- 功能清单文档（cjh功能清单.md）

## [v1.2.0] - 2026-08-23

### Added
- **V2d 并发执行引擎**：DAG 依赖分析（资源访问 `(path, isWrite)` 提取）+ 拓扑分组调度（同组 spawn 并发，组间串行）+ 性能基线三维统计（parallelBatches/parallelSavedMs/maxParallelism）
- **工具效率 P0-P2**：hashline 重设计（行号锚点 `@@N` + 内容验证编辑，借鉴 OMP）
- **V2c 记忆分层**：Compaction 摘要压缩 + AGENTS.md 项目指令加载
- **V2b 插件系统**：Skills 即文件（frontmatter + 声明式工具）+ plugin.json shell 工具插件
- **树形会话 + `--mode json`**：saveFork/parentOf/listTree 树形分支 + 无头 JSON 模式
- **V3b Ollama 本地模型**：复用 OpenAI SSE 协议，本地 HTTP 无 TLS
- Tasks 面板（Agent 任务列表 TUI 实时展示）

### Tests
- 单测扩至 152 全绿（read 边界/grep/glob/hashline/agent DAG+截断端到端/session/skills/utf8 等）

## [v1.1.0] - 2026-08-23

### Added
- 版本徽章 + 标题重命名（"Agent made by Cangjie"）
- TUI 组件补齐：Spinner / ConfirmDialog / MultiLineEditor / TabBar / Box
- compaction 初版 + AGENTS.md 加载 + provider 配置对话框

### Fixed
- 终端尺寸读取（C helper 绕过 FFI ioctl 问题 + stderr/stdin 兜底）
- TUI 审批结束后按键卡死（pendingApproval 残留吞按键）
- truncate CSI 序列处理

## [v1.0.0] - 2026-08-21（无 tag，首个提交）

### Added
- **P0 MVP**：Agent 核心（消息状态机 + 工具调用协议 + 迭代）
- **5 个内置工具**：bash / read_file / write_file / grep / list_dir
- 全屏 TUI（差分渲染 + ANSI + termios 原始模式，纯 libc FFI 自实现）
- OpenAI / Anthropic 双协议 SSE 流式 + 流式累加器
- 配置系统 + 会话持久化（首跑自动生成 auth.json/settings.json 模板）
- cjterm / cjllm / cjcfg 独立库拆分
- 静态编译 + DT_RPATH 内嵌（`./main` 无需 LD_LIBRARY_PATH）
- 非 UTF-8 终端 UI 自动降级 ASCII
