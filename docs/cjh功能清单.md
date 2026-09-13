# cjh 功能清单

> 最后更新：2026-09-13
> 版本：v1.5.0
> 性质：cjh 已具备和支持的功能完整列表

---

## 一、核心架构

| 功能 | 说明 |
|------|------|
| **Agent 主循环** | 消息历史 → LLM → 工具调用 → 结果回填 → 循环，支持多轮工具调用 |
| **多 Provider 支持** | OpenAI / DeepSeek / GLM / Ollama / Anthropic 协议兼容 |
| **Provider 热切换** | `/model` `/provider` 命令运行时切换，历史保留 |
| **单二进制零依赖** | 仓颉原生编译，无运行时依赖，跨平台分发 |
| **预算竞速中断** | `runWithBudget` 原语：LLM 请求 connect/写/读全阶段有界超时 + 用户取消检查器（下沉传输层，新协议复用即天然继承）；裸 connect 挂死从"永久卡死"变为秒级可中断 |
| **超长工具参数 JSON 修复** | `repairTruncatedJson`：LLM 生成超长 tool_call 被 max_tokens 截断时，优先闭合被截断字符串再闭合 JSON，恢复可用参数 |
| **异步 Compaction** | 轮末按真实 `usage.promptTokens` 触发，读快照 spawn 后台摘要（不阻塞主循环），下一轮请求前换装/顺延，失败静默重试再回退同步路径 |
| **双平台条件编译** | POSIX termios / Windows 控制台 API 用 `@When[os == "..."]` 内置条件编译隔离，业务代码零平台分支；交叉编译产物经 strings 符号级验证后端互斥 |
| **模块化包架构** | 6 包单向依赖（cjh 主体 + cjllm/cjterm/cjutil/cjlog/cjconfig），循环依赖用回调注入解决；5 个库包独立开源发布 v0.1.0 |

## 二、TUI 终端界面

| 功能 | 说明 |
|------|------|
| **全屏 TUI** | 差分渲染 + ANSI 转义，支持鼠标/键盘 |
| **流式回复** | LLM 流式输出实时渲染，mojibake 整体修复 |
| **Markdown 渲染** | 标题/列表/代码块/表格/链接 |
| **多行编辑器** | Ctrl+E 进入，Alt+Enter 提交，Esc 退出 |
| **斜杠命令补全** | `/` 触发下拉补全，上下键选择 |
| **视图标签栏** | 对话/帮助视图切换 |
| **欢迎视图** | 启动/新会话时两栏布局（logo+模型 / Tips+会话） |
| **状态栏** | 模型徽章 + cwd + 状态文本 + 蓝色边框 |
| **审批弹窗** | 危险操作内嵌 y/n 审批 |
| **Provider 配置表单** | `/provider` 无参数时弹出配置表单 |
| **输入队列方案 B** | Agent 执行期间输入可编辑，提交入队 + 提示，执行完自动处理下一条 |
| **Tasks 面板** | Agent 内置任务列表实时展示，对齐 Claude Code TodoWrite |
| **回合总结条** | 每轮结束后显示 `─── ✓ 2 rounds · 3 tools · 42.6s · 1.5k tokens · 99% cached ───`（token 为模型 usage 真实值逐轮累加，缓存率按 provider 协议解析——DeepSeek `prompt_cache_hit_tokens` / Anthropic `cache_read_input_tokens` / OpenAI 标准嵌套 `prompt_tokens_details.cached_tokens` 三字段全解析） |
| **增量行缓存** | OutputView 行级增量维护，渲染复杂度 O(全部行)→O(变化行)，长会话无卡顿无闪屏（等价性有专项单测锁定） |
| **思考过程折叠** | 推理/思考段独立视图；折叠态（默认）一行全局摘要贴消息流末尾（状态提示、始终可见），`Ctrl+T` 展开后**逐轮交织**——每轮思考钉在**本轮回复之前**（不再全堆到会话末尾）、内容行两格缩进 + 灰斜体 + 背景卡片；**思考块与回复之间留一行空行间隔**（交织段边界 gap；相邻行本身已空则不重复插，滚动总行数已计入 gap）；`PageUp`/`Ctrl+U` 上滚回看历史轮次；单轮超长处**中间截断**保头尾 |
| **bracketed paste** | 粘贴走独立读取路径，按字符边界解码（中文粘贴不乱码，v1.3.12 根治） |
| **双平台输入** | POSIX termios / Windows 控制台 API（含 UTF-8 中文输入、快捷键体系），`@When` 条件编译隔离 |
| **NO_COLOR 支持** | 终端禁用颜色时自动降级（v1.3.13） |
| **可靠性兜底** | 主循环单帧异常不终止事件循环；终端 raw 恢复放 finally（崩溃也还原 ECHO）；Ctrl+C 优雅中断当前轮 |

## 三、主题系统

| 功能 | 说明 |
|------|------|
| **10 套主题** | starfrost（星霜青）/classic（经典亮青）/catppuccin/rose-pine/solarized/monokai 等 10 套（v1.3.13 自 6 套扩充） |
| **运行时切换** | `/theme [name]` 切换，持久化到 settings.json |
| **交互式选择** | `/theme` 无参数时弹出 picker，上下键选择 |
| **实时预览** | 主题切换即时渲染，无需重启 |
| **按主题变色的输入框边框** | 每个主题显式定义输入框边框色，视觉层次统一 |

## 四、工具系统

| 工具 | 说明 |
|------|------|
| **bash** | 执行 shell 命令，捕获 stdout/stderr |
| **read_file** | 读取文件，大文件返回符号摘要，offset/limit 按需展开 |
| **write_file** | 写入文件（创建/覆盖） |
| **hashline_edit** | 行号锚点 `@@N` + 内容验证编辑，`@@{hash}` 哈希锚点向后兼容 |
| **grep** | 目录树递归搜索，gitignore 感知，上下文行参数 |
| **list_dir** | 列出目录树 |
| **cangjie_ref** | 仓颉知识层离线检索：对 `~/.cjh/cangjie-ref/` 语料做 CJK 2-gram + ASCII 词混合分词、行级打分，命中带绝对 `路径:行号` 供精读；纯离线不联网，语料目录不存在则**不注册**（零开销） |
| **todo_write** | LLM 通过工具调用管理任务列表（add/doing/done/update/clear/list） |
| **web_search** | 联网搜索，多后端路由（Tavily/Exa/SearXNG/DDG）+ per-engine key rotation，snippet 截断 500 字符 |
| **web_fetch** | 抓取网页，三级降级链（仓颉 HTTP GET → curl → Firecrawl）+ SSRF 防护 + HTML 清洗 → Markdown，截断 ~32KB |

### web_search + web_fetch 详细设计

详见 [Web 搜索与抓取工具设计](Web搜索与抓取工具设计.md)。

**web_search（信息检索）**：
- SearchProvider 接口 + SearchRouter 多后端路由（Auto fallback）
- TavilyProvider：主力，1000 req/月免费不绑卡，per-engine key rotation
- ExaProvider：语义搜索，长尾查询强，per-engine key rotation
- SearXNGProvider：自建零成本，聚合 70+ 后端
- DDGProvider：零 key 兜底，永远 enable
- snippet 截断到 500 字符，默认返回 5 条（最多 10 条）

**web_fetch（信息获取）**：
- 三级降级链：
  1. 仓颉 stdx.net.http GET（第一层，~50% 站点）
  2. exec curl + 浏览器头（第二层，~70% 站点，数组式 exec 防注入）
  3. Firecrawl API（第三层，~96% 站点，Keyless 1000 credits/month）
- SSRF 防护：协议白名单 + IP 段拦截（loopback/link-local/RFC1918/云元数据 169.254.169.254）+ DNS 解析校验 + 重定向逐跳重校
- HTML 清洗 → Markdown（去 script/style/nav + 标签剥离 + HTML 实体解码）
- 截断到 ~32KB（~8K token），硬下载上限 5MB

**会话级预算（防 prompt injection 烧流量）**：
- WebBudget 计数器：20 fetches · 30 searches · 1MB download（默认）
- 超出预算拒绝后续调用
- 线程安全（ReentrantMutex），V2d 并发引擎可安全调用

**配置**（settings.json）：
```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto",
    "tavily_api_keys": "",
    "exa_api_keys": "",
    "searxng_url": "",
    "max_results": 5,
    "timeout_seconds": 8
  },
  "web_fetch": {
    "enabled": true,
    "allow_internal_hosts": false,
    "max_chars": 32000,
    "timeout_seconds": 30
  }
}
```

环境变量：`TAVILY_API_KEYS` · `EXA_API_KEYS` · `SEARXNG_URL` · `FIRECRAWL_API_KEY` · `CJH_WEB_SEARCH_PROVIDER`

## 五、工具执行引擎

| 功能 | 说明 |
|------|------|
| **V2d 并发执行** | Read vs. Write 分类调度，全 read-only 批次 spawn 并发，含 state-modifying 整批串行 |
| **CjhTool 接口** | `isReadOnly()` 分类，DeclarativeTool 声明式工具 |
| **ToolRegistry** | 工具注册 + 按名查找 + read-only 分类 |
| **工具结果截断+落盘+回溯** | 超阈值工具结果保留头尾 + 完整落盘 `~/.cjh/spill/<sessionId>/<toolCallId>.txt` + 省略标记含落盘路径，模型可用 `read_file` 按需读回；工具差异化阈值（bash 2000/list_dir 4000/默认 6000，read_file 不截断） |

## 六、记忆与会话管理

| 功能 | 说明 |
|------|------|
| **树形会话** | 会话分支/fork，parent 链追踪，`/tree` 树形列示 |
| **会话恢复** | `--resume <id>` 恢复历史会话 |
| **会话列表** | `--list` 列出所有会话 |
| **自动 Compaction** | 消息条数或估算 prompt token（真实 `usage.promptTokens`）超阈值触发 LLM 摘要压缩早期历史，`compactThreshold`/`compact_token_threshold`/`compactKeep` 配置 |
| **手动 Compaction** | `/compact` 命令强制压缩历史 |
| **项目指令** | `loadProjectInstructions` 逐级查 AGENTS.md |

## 七、插件系统（V2b）

| 功能 | 说明 |
|------|------|
| **plugin.json 元数据** | 插件包根目录声明 name/version/author/tools/hooks |
| **Shell 工具插件** | 工具实现 = shell 脚本，参数通过 `CJH_TOOL_ARGS` 环境变量传递（JSON），stdout 输出结果 |
| **PluginManager** | 扫描 `~/.cjh/plugins/*/plugin.json`，路径遍历防护，白名单过滤 |
| **事件钩子** | `on_tool_result` 钩子：工具结果回填前触发，插件可拦截/改写；事件数据通过 `CJH_HOOK_DATA` 环境变量传递 |
| **插件白名单** | `enabled_plugins` 配置启用插件 |
| **插件信任链（V3，三步全部实现）** | ① SHA256 目录校验和（`sha256DirExcluding`，加载时比对）；② SM2 国密签名验证（stdx.crypto 原生实现，零外部依赖，pubkey DER + 签 checksum）；③ 信任列表 CLI（`cjh trust/untrust/trust-list` + `~/.cjh/trusted-publishers`，空列表=开放模式/非空=严格模式） |
| **require_signature 强制模式** | 配置开启后，无完整签名（checksum+pubkey+signature）的插件拒绝加载 |
| **示例插件** | `example/plugins/`：echo-test（工具）+ log-pruner（钩子）+ git-status（第三方风格工具）+ tool-result-banner（第三方风格钩子）+ signed-demo（SM2 签名插件，附签名生成器） |

## 八、MCP 协议支持（V2b 扩展点）

| 功能 | 说明 |
|------|------|
| **MCP 客户端** | `McpClient`：stdio 传输 + JSON-RPC 2.0 + initialize 握手 + tools/list + tools/call |
| **MCP 工具代理** | `McpTool`：注册到 ToolRegistry，LLM 调用时转发给 MCP 服务器 |
| **MCP 管理器** | `McpManager`：管理多个 MCP 服务器的连接和工具注册 |
| **配置** | `settings.json` 的 `mcp_servers` 段配置 MCP 服务器 |
| **示例 MCP 服务器** | `example/mcp/echo-mcp-server.sh`：最小 stdio MCP 服务器（bash 实现） |

## 九、技能系统

| 功能 | 说明 |
|------|------|
| **技能即 Markdown** | `~/.cjh/skills/<name>.md`，frontmatter 声明元数据 + 工具 |
| **技能白名单** | `enabled_skills` 配置启用技能 |
| **技能携带工具** | 技能 frontmatter 的 `tools` 段注册声明式工具 |
| **`/skills` 命令** | 列出技能与启用状态 |
| **仓颉知识层（一期）** | 仓内 `skills/` 六篇自研技能（资源地图 / 环境搭建 / 速查 / PR 模板 / README 模板 / 中心仓发布），`scripts/install-cangjie-knowledge.sh` 投影安装：**入口 / 全文分离**——`~/.cjh/skills/<name>.md` 只留描述 + 指向全文的绝对路径（9 篇合计 6,588 B 常驻），全文落 `~/.cjh/cangjie-ref/skills/<name>/SKILL.md` 按需 `read_file` / `grep` |
| **仓颉知识层（二期）** | 只读工具 `cangjie_ref`（`src/tools/cangjie_ref.cj`）：对 `~/.cjh/cangjie-ref/` 语料做**纯离线**检索——CJK 2-gram + ASCII 词混合分词、行级打分（覆盖率 / 频次 / 小节标题加成）、命中带绝对 `路径:行号` 供 `read_file` 精读；语料目录不存在则**不注册**（未装知识层零开销），工具描述 334 B，不联网、语料不进二进制 |
| **仓颉知识层（三期）** | `cjh ref status / verify / rebuild / update`：`status`（语料概况）、`verify`（按清单逐文件重算 SHA-256，报缺失 / 被改 / 多余，失败非零退出）、`rebuild`（人工增删改语料后重扫重建清单）**全部纯本地**；`update` 是**唯一联网入口**（`git clone --depth 1` AtomGit `Cangjie-SIG/CangjieSkills`，必须人显式敲命令，模型回答途中永不触发下载），`--source <目录>` 可离线刷新、`--repo` / `--branch` 换源、`--dry-run` 只预演、`--restore` 用覆盖前快照回滚。覆盖前快照落 `~/.cjh/cangjie-ref.prev`（**在语料目录之外**，避免回滚时被一起删）；覆盖后重扫清单 + 自检，任一环失败自动回滚；**同名技能只对齐 `.md`**（旧 md 清掉、非 md 资产保留），来源里没有的技能目录不动；TUI 侧另有 `/ref` 面板，联网动作需 `--yes` 二次确认 |
| **外部技能收录** | `--with-cangjie-skills` 从 CangjieSkills 分级收录三个技能：两个纯 Markdown 零依赖（`cangjie-code-review` / `cangjie-build-diagnose`）+ `cangjie-coding` 需 Python 3.11+（上游 `search_docs.py` + `knowledge.sqlite3`，缺 Python 则跳过）；语料落 `~/.cjh/cangjie-ref/skills/<name>/`（8.9 MB，只作运行时数据，不进二进制） |
| **安装幂等与迁移** | 入口带标记 `cjh-knowledge-entry v1`，重跑即幂等刷新；旧版整篇入口自动迁移（先备份到 `~/.cjh/skills/.backup/` 再改写，不丢内容）；非本工具生成的文件默认跳过，`--force` 覆盖 |

## 十、安全模型

| 功能 | 说明 |
|------|------|
| **三域 capability** | commands（命令）/ tools（工具）/ resources（文件与危险命令）白名单 |
| **审批链** | 危险操作需人工确认，TUI 内嵌 y/n 审批 |
| **宽松模式** | 未配置 capability 时全部允许 |

## 十一、无头模式

| 功能 | 说明 |
|------|------|
| **JSON 模式** | `--mode json` 无头模式，输出 JSON 结果（脚本可解析） |
| **CLI 模式** | `--cli` 命令行交互模式 |
| **Mock 模式** | `--mock` 验证模式，使用 MockProvider |

## 十二、配置系统

| 功能 | 说明 |
|------|------|
| **settings.json** | base_url / model / max_iterations / system_prompt / temperature / max_tokens / models / capability / compact_threshold / compact_keep / enabled_skills / enabled_plugins / mcp_servers / theme / tool_result_max_chars / require_signature / web_search / web_fetch / max_tokens 等 |
| **auth.json** | api_key 存储 |
| **环境变量** | `CJH_CONFIG_DIR` `CJH_MOCK` `CJH_PROVIDER` 等覆盖 |
| **模型预设** | `/provider deepseek|openai|glm|ollama|qwen|kimi|doubao|siliconflow` 预设 base_url+model（支持 custom 端点） |
| **配置模板兜底** | cjconfig 首次运行自动生成带注释模板，缺失字段取默认值 |

## 十三、斜杠命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/new` | 开始新会话 |
| `/resume [id]` | 恢复历史会话（无 id 时列出） |
| `/model [id|#]` | 列出/切换模型 |
| `/provider [name] [key]` | 切换 provider（deepseek/openai/glm/ollama） |
| `/skills` | 列出技能与启用状态 |
| `/ref [status\|verify\|rebuild\|search <词>\|update]` | 仓颉知识层语料面板：**纯本地** `status`/`verify`/`rebuild`/`search` 直接出结果（与 `cjh ref` 同一实现）；`update` 是唯一联网动作——**不带 `--yes` 只打印计划**（语料目录 / 来源 / 分支 / 流程），带 `--yes` 才执行，`--source <目录>` 走离线不拦 |
| `/compact` | 手动压缩历史（LLM 摘要早期消息） |
| `/tree` | 树形列示会话分支 |
| `/fork` | 从当前会话分支新会话 |
| `/settings` | 查看采样参数（temp/max_tokens） |
| `/task` | 任务管理（add/done/doing/clear/list） |
| `/theme [name]` | TUI 主题切换（starfrost|classic|catppuccin|rose-pine|solarized|monokai） |
| `/quit` | 退出 |

## 十四、Provider 支持

| Provider | 协议 | 说明 |
|----------|------|------|
| **OpenAI** | OpenAI API | 兼容 GPT-4o / GPT-4o-mini |
| **DeepSeek** | OpenAI 兼容 | deepseek-chat / deepseek-v4-flash，支持 prompt_cache_hit_tokens |
| **GLM** | OpenAI 兼容 | glm-4-flash，智谱 AI |
| **Ollama** | OpenAI 兼容（无 TLS） | 本地模型，apiKey 可空，CJH_PROVIDER=ollama 接入 |
| **Anthropic** | Anthropic API | Claude 系列，支持 cache_read_input_tokens |
| **MCP 服务器** | MCP 协议（stdio） | 通过 `mcp_servers` 配置接入，工具自动注册 |

## 十五、Web 界面

| 功能 | 说明 |
|------|------|
| **Web 远程驱动** | 内置 HTTP Server + WebSocket 流式对话 + REST API + 前端 SPA（Markdown/代码高亮/复制） |
| **模型下拉切换** | 右上角下拉列出 models 列表 + 当前模型选中；切换即时生效，模型带端点时联动更新（切厂家） |
| **配置表单** | 厂家下拉（按端点分组去重）+ API 端点 + 模型 + API Key + 行为参数 + Web 配置，选厂家/模型自动回填端点 |
| **工作区切换（运行时生效）** | chdir 切换进程 cwd + 重置持久 bash 会话（cwd 独立于进程）+ 更新最近访问排序，无需重启 |
| **目录浏览选择器** | `/api/fs/list` 列目录，前端 📁 浏览器进子目录 / 上一级 / 选择当前目录，替代纯手工输入 |
| **当前工作区高亮** | 工作区列表对比 cwd 标记 active，切换后即时高亮 |
| **web 模块单测** | WorkspaceManager 6 用例 + WebApi 工具函数 4 用例（`cjpm test --filter "*Workspace*|*WebApi*"`） |

## 十六、版本历史

| 版本 | 主要功能 |
|------|----------|
| v1.0.0 | 初始版本：TUI + Agent 循环 + 基础工具 |
| v1.1.0 | V2c 记忆分层 + V2b 插件系统 + 树形会话 + V3b Ollama 支持 |
| v1.2.0 | V2d 并发执行引擎 + P0-P2 工具效率提升 + 输入队列方案 B + Tasks 面板 + TodoWriteTool |
| v1.2.1 | 星霜青主题系统 + /theme 切换 + 回合总结条 + UI 打磨 |
| v1.2.2 | 回合总结条 + Tasks 面板 + 输入队列方案 B + /compact + /tree + /fork |
| v1.2.3 | SSE 空闲超时 + token 统计健壮性 + 工具结果截断与回溯 + V2b 插件系统（plugin.json + 事件钩子）+ MCP 协议支持 + 6 套主题 + 主题实时预览 |
| v1.3.0 | Web 支持实现方案 Step 1-5：HTTP server + WebSocket 流式对话 + 前端 app.js + REST API + Markdown 渲染（marked.js + DOMPurify + highlight.js）+ 代码块复制按钮 + auth_token 鉴权中间件 + 启动安全审计日志 |
| v1.3.1 | P0+P1 优化（bash 超时 / Ctrl+C 中断 / 提示词 / 项目记忆 / 模型路由 / compaction / task / SQLite）+ 持久 bash 会话（跨命令保留 cwd/env）+ 429 fallback 备用 key 轮换 + provider 弹窗预设（qwen/kimi/doubao/siliconflow + custom 端点 + 接入协议）+ TUI 零测试补齐（202 全绿）+ 技能示例 |
| v1.3.2 | 静态链接单文件发布（零仓颉动态库依赖，`dist/cjh-v1.3.2-linux-x64`） |
| v1.3.3 | Web 工作区切换运行时真正生效（chdir + bash 会话重置）+ 目录浏览选择器 + 配置表单厂家选择 + 右上角模型下拉修复（原"加载中"死代码）+ 配置按钮文字化 + web 模块单测（238 全绿） |
| v1.3.4 | Streaming 卡死根治（流式传输链路排查修复）+ 粘贴自动发送修复 |
| v1.3.5 | TUI 僵尸忙态根治 + 技术债"偶发 UTF-8 异常"正式闭环（`truncateUtf8` 字符边界截断，禁裸 `String[0..N]` 切中文） |
| v1.3.6 | 首个 LLM 请求 442s 卡死 + 8 次中断全部失效根治：`runWithBudget` 预算竞速原语（裸 socket 无 connect 超时的仓颉 1.0.5 实测问题） |
| v1.3.7 | 预算竞速下沉传输层（connect/write/read 全有界，新协议复用传输层零改动继承）+ 双平台发布包修复 |
| v1.3.8 | "连续几轮会话总被打断"根治 |
| v1.3.9 | 工具输出中文乱码根治（字节流→String 按字符边界 `safeFromUtf8` 解码，替代逐字节 `Rune(byte)` 拼接） |
| v1.3.10 | TUI 假死/无法输入根治（异步日志 sink 计数空循环假 sleep 饿死主 worker，改 runtime `sleep`） |
| v1.3.11 | 长会话 TUI 主协程停摆 + 泄漏 bash/僵尸根治（裸 `Mutex.lock()` 临界区异常锁泄漏→全 `try/finally` 守护；退出路径显式回收子进程 + 关闭 Log/MCP/会话） |
| v1.3.12 | 粘贴中文乱码根治（bracketed paste 独立读取路径按字符边界解码） |
| v1.3.13 | P2 OutputView 增量行缓存（渲染 O(全部行)→O(变化行)）+ P2b TUI 视觉层次美化 + `NO_COLOR` 支持 + 主题扩至 10 套 + 双平台发布包 |
| v1.3.14 | V3 信任链 Step 3 信任管理 CLI（`cjh trust/untrust/trust-list` + `~/.cjh/trusted-publishers`，空列表开放/非空严格）+ 第三方风格插件示例（git-status / tool-result-banner）+ libs 生态冷启动发布（cjterm/cjlog/cjconfig/cjutil/cjllm 独立仓库 v0.1.0） |
| v1.3.15 | 回合统计缓存率统计缺口修复：解析 OpenAI 标准/智谱 GLM 嵌套字段 `prompt_tokens_details.cached_tokens`（此前 GLM/OpenAI 兼容接口恒显示 0% cached） |
| v1.4.0 | 仓颉内置知识层一 + 二期：技能「入口 / 全文分离」（`~/.cjh/skills/<name>.md` 只留描述 + 指向全文的绝对路径，9 篇常驻 20,086 → 6,588 B），`scripts/install-cangjie-knowledge.sh` 投影安装 + `--with-cangjie-skills` 分级收录；只读工具 `cangjie_ref` 对 `~/.cjh/cangjie-ref/` 语料纯离线检索（CJK 2-gram + ASCII 词分词、行级打分、命中带 `路径:行号`） |
| v1.5.0 | 仓颉内置知识层三期 + TUI `/ref` 面板：`cjh ref status / verify / rebuild / update` 子命令（前三者纯本地；`update` 唯一联网入口、只能人显式触发，`--source` 离线刷新、`--repo`/`--branch` 换源、`--dry-run` 只预演、`--restore` 快照回滚）+ 覆盖前快照与自检失败自动回滚 + **同名技能只对齐 `.md`**（保留上游非 md 资产、来源没有的技能目录不动）+ `cjh ref search` 复用二期检索；TUI `/ref [status\|verify\|rebuild\|search <词>\|update]`（联网动作需 `--yes` 二次确认） |

## 十七、代码组织原则

- **高内聚低耦合**：满足软件设计六大原则（单一职责、开闭、里氏替换、接口隔离、依赖倒置、迪米特法则）
- **单向依赖 + 回调注入**：循环依赖靠单向依赖 + 回调注入解决，禁止"移包打补丁"破坏包内聚性
- **包结构**：`cjh.agent`（Agent 核心）→ `cjh.tools`（工具）→ `cjh.tui`（TUI）→ `cjterm`（终端组件）→ `cjllm`（LLM 协议）→ `cjcfg`（配置）

---

## 十八、待推进功能（路线图）

| 优先级 | 功能 | 说明 |
|--------|------|------|
| ★★★ | P3 连接池 1→N | 传输层 `pooledTransport` 单槽→2-4 槽（host:port 键），主+摘要 provider 交替省建连 |
| ★★★ | V4 agent 集群调度 | 编排器 + 子 agent 并行（隔离工作区/契约/角色模型/编排 DSL/模型路由）——核心差异化（`task` 工具已建 explore/worker 基础） |
| ★★☆ | V2b 插件系统完整形态 | WASM 工具沙箱 + 中心仓 + `cjh install`（信任链三步已闭环，沙箱与仓库分发是剩余项） |
| ★★☆ | V2e IM 网关 | Channel 抽象 + Web 渠道 + 审批远程化 |
| ★★☆ | V3b 协议深化 | Provider Registry + 模型能力描述 |
| ★☆☆ | 单轮 completion 瓶颈优化 | 快模型验证 + 请求批量化（中期） |
| ★☆☆ | 库包生态演进 | 推动 5 库包进入官方收录、适配鸿蒙工具链、持续按版本号规则发版 |

## 十九、生态发布与测试门禁

| 项 | 说明 |
|----|------|
| **独立开源库包** | cjllm（LLM 协议/SSE/多 provider）/ cjterm（TUI 渲染/主题/双平台输入）/ cjutil（UTF-8 安全/SHA256/SM2/hex/runWithBudget）/ cjlog（异步分级日志）/ cjconfig（配置管理）——均含 LICENSE + README + 发布指南 + examples + CI，已发布独立仓库 v0.1.0；cjcfg 为内部架构库不独立发布 |
| **测试门禁** | `scripts/test.sh`（根包 441 用例，自动切动态链接配置）+ `python3 scripts/tui_pty_test.py`（TUI 伪终端 16 场景）+ `--mock` 端到端（工具调用链验证）；库包另有 `cd libs/cjterm && cjpm test`；交付前必须全绿 |
| **发版流程** | 版本号三处同步（cjpm.toml + logo.cj VERSION + 标题栏注释）+ 打 tag + 双远端推送；重大更新递增中间位、小更新递增最后位 |
