# cjh 功能清单

> 最后更新：2026-08-25
> 版本：v1.3.0
> 性质：cjh 已具备和支持的功能完整列表

---

## 一、核心架构

| 功能 | 说明 |
|------|------|
| **Agent 主循环** | 消息历史 → LLM → 工具调用 → 结果回填 → 循环，支持多轮工具调用 |
| **多 Provider 支持** | OpenAI / DeepSeek / GLM / Ollama / Anthropic 协议兼容 |
| **Provider 热切换** | `/model` `/provider` 命令运行时切换，历史保留 |
| **单二进制零依赖** | 仓颉原生编译，无运行时依赖，跨平台分发 |

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
| **回合总结条** | 每轮结束后显示 `─── ✓ 2 rounds · 3 tools · 42.6s · 1.53K tokens · 99% cached ───` |

## 三、主题系统

| 功能 | 说明 |
|------|------|
| **6 套主题** | starfrost（星霜青）/classic（经典亮青）/catppuccin/rose-pine/solarized/monokai |
| **运行时切换** | `/theme [name]` 切换，持久化到 settings.json |
| **交互式选择** | `/theme` 无参数时弹出 picker，上下键选择 |
| **实时预览** | 主题切换即时渲染，无需重启 |

## 四、工具系统

| 工具 | 说明 |
|------|------|
| **bash** | 执行 shell 命令，捕获 stdout/stderr |
| **read_file** | 读取文件，大文件返回符号摘要，offset/limit 按需展开 |
| **write_file** | 写入文件（创建/覆盖） |
| **hashline_edit** | 行号锚点 `@@N` + 内容验证编辑，`@@{hash}` 哈希锚点向后兼容 |
| **grep** | 目录树递归搜索，gitignore 感知，上下文行参数 |
| **list_dir** | 列出目录树 |
| **todo_write** | LLM 通过工具调用管理任务列表（add/doing/done/update/clear/list） |

## 五、工具执行引擎

| 功能 | 说明 |
|------|------|
| **V2d 并发执行** | Read vs. Write 分类调度，全 read-only 批次 spawn 并发，含 state-modifying 整批串行 |
| **CjhTool 接口** | `isReadOnly()` 分类，DeclarativeTool 声明式工具 |
| **ToolRegistry** | 工具注册 + 按名查找 + read-only 分类 |
| **工具结果截断+落盘+回溯** | 超阈值工具结果保留头尾 + 完整落盘 `~/.cjh/spill/<sessionId>/<toolCallId>.txt` + 省略标记含落盘路径，模型可用 `read_file` 按需读回；工具差异化阈值（bash 8000/list_dir 4000/默认 6000） |

## 六、记忆与会话管理

| 功能 | 说明 |
|------|------|
| **树形会话** | 会话分支/fork，parent 链追踪，`/tree` 树形列示 |
| **会话恢复** | `--resume <id>` 恢复历史会话 |
| **会话列表** | `--list` 列出所有会话 |
| **自动 Compaction** | 消息条数超阈值触发 LLM 摘要压缩早期历史，`compactThreshold`/`compactKeep` 配置 |
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
| **示例插件** | `example/plugins/echo-test`（工具插件）+ `log-pruner`（事件钩子插件） |

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
| **settings.json** | base_url / model / max_iterations / system_prompt / temperature / max_tokens / models / capability / compact_threshold / compact_keep / enabled_skills / enabled_plugins / mcp_servers / theme / tool_result_max_chars |
| **auth.json** | api_key 存储 |
| **环境变量** | `CJH_CONFIG_DIR` `CJH_MOCK` `CJH_PROVIDER` 等覆盖 |
| **模型预设** | `/provider deepseek|openai|glm|ollama` 预设 base_url+model |

## 十三、斜杠命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/new` | 开始新会话 |
| `/resume [id]` | 恢复历史会话（无 id 时列出） |
| `/model [id|#]` | 列出/切换模型 |
| `/provider [name] [key]` | 切换 provider（deepseek/openai/glm/ollama） |
| `/skills` | 列出技能与启用状态 |
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

## 十五、版本历史

| 版本 | 主要功能 |
|------|----------|
| v1.0.0 | 初始版本：TUI + Agent 循环 + 基础工具 |
| v1.1.0 | V2c 记忆分层 + V2b 插件系统 + 树形会话 + V3b Ollama 支持 |
| v1.2.0 | V2d 并发执行引擎 + P0-P2 工具效率提升 + 输入队列方案 B + Tasks 面板 + TodoWriteTool |
| v1.2.1 | 星霜青主题系统 + /theme 切换 + 回合总结条 + UI 打磨 |
| v1.2.2 | 回合总结条 + Tasks 面板 + 输入队列方案 B + /compact + /tree + /fork |
| v1.2.3 | SSE 空闲超时 + token 统计健壮性 + 工具结果截断与回溯 + V2b 插件系统（plugin.json + 事件钩子）+ MCP 协议支持 + 6 套主题 + 主题实时预览 |
| v1.3.0 | Web 支持实现方案 Step 1-5：HTTP server + WebSocket 流式对话 + 前端 app.js + REST API + Markdown 渲染（marked.js + DOMPurify + highlight.js）+ 代码块复制按钮 + auth_token 鉴权中间件 + 启动安全审计日志 |

## 十六、代码组织原则

- **高内聚低耦合**：满足软件设计六大原则（单一职责、开闭、里氏替换、接口隔离、依赖倒置、迪米特法则）
- **单向依赖 + 回调注入**：循环依赖靠单向依赖 + 回调注入解决，禁止"移包打补丁"破坏包内聚性
- **包结构**：`cjh.agent`（Agent 核心）→ `cjh.tools`（工具）→ `cjh.tui`（TUI）→ `cjterm`（终端组件）→ `cjllm`（LLM 协议）→ `cjcfg`（配置）

---

## 十七、待推进功能（v2 路线图）

| 优先级 | 功能 | 说明 |
|--------|------|------|
| ★★★ | V2d 并发引擎完整形态 | DAG 依赖分析 + Provider 连接预热 + 性能基线测量 |
| ★★★ | V3 信任链 | 插件签名 + 内容校验和 + 发布者信任列表 |
| ★★★ | V2b 插件系统完整形态 | WASM 工具沙箱 + 中心仓 + `cjh install` |
| ★★☆ | V2e IM 网关 | Channel 抽象 + Web 渠道 + 审批远程化 |
| ★★☆ | V3b 协议深化 | Provider Registry + 模型能力描述 |
| ★☆☆ | V4 多 Agent | 多 agent 协作 + 鸿蒙原生适配 |
