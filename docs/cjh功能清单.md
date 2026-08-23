# cjh 功能清单

> 最后更新：2026-08-24
> 版本：v1.2.1
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
| **星霜青主题** | 默认主题，鸿蒙生态同源品牌色，低饱和雾面青 |
| **经典亮青主题** | 旧版高饱和亮青配色，向后兼容 |
| **运行时切换** | `/theme [name]` 切换，持久化到 settings.json |
| **交互式选择** | `/theme` 无参数时弹出 picker，上下键选择 |

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

## 六、记忆与会话管理

| 功能 | 说明 |
|------|------|
| **树形会话** | 会话分支/fork，parent 链追踪，`/tree` 树形列示 |
| **会话恢复** | `--resume <id>` 恢复历史会话 |
| **会话列表** | `--list` 列出所有会话 |
| **自动 Compaction** | 消息条数超阈值触发 LLM 摘要压缩早期历史，`compactThreshold`/`compactKeep` 配置 |
| **手动 Compaction** | `/compact` 命令强制压缩历史 |
| **项目指令** | `loadProjectInstructions` 逐级查 AGENTS.md |

## 七、技能系统

| 功能 | 说明 |
|------|------|
| **V2b 插件系统** | parseFrontmatter 统一解析、DeclarativeTool、`/skills` 命令、示例技能 |
| **技能白名单** | `enabled_skills` 配置启用技能 |
| **技能携带工具** | 技能可注册声明式工具 |

## 八、安全模型

| 功能 | 说明 |
|------|------|
| **三域 capability** | commands（命令）/ tools（工具）/ resources（文件与危险命令）白名单 |
| **审批链** | 危险操作需人工确认，TUI 内嵌 y/n 审批 |
| **宽松模式** | 未配置 capability 时全部允许 |

## 九、无头模式

| 功能 | 说明 |
|------|------|
| **JSON 模式** | `--mode json` 无头模式，输出 JSON 结果（脚本可解析） |
| **CLI 模式** | `--cli` 命令行交互模式 |
| **Mock 模式** | `--mock` 验证模式，使用 MockProvider |

## 十、配置系统

| 功能 | 说明 |
|------|------|
| **settings.json** | base_url / model / max_iterations / system_prompt / temperature / max_tokens / models / capability / compact_threshold / compact_keep / enabled_skills / theme |
| **auth.json** | api_key 存储 |
| **环境变量** | `CJH_CONFIG_DIR` `CJH_MOCK` `CJH_PROVIDER` 等覆盖 |
| **模型预设** | `/provider deepseek|openai|glm|ollama` 预设 base_url+model |

## 十一、斜杠命令

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
| `/theme [name]` | TUI 主题切换（starfrost|classic） |
| `/quit` | 退出 |

## 十二、Provider 支持

| Provider | 协议 | 说明 |
|----------|------|------|
| **OpenAI** | OpenAI API | 兼容 GPT-4o / GPT-4o-mini |
| **DeepSeek** | OpenAI 兼容 | deepseek-chat / deepseek-v4-flash，支持 prompt_cache_hit_tokens |
| **GLM** | OpenAI 兼容 | glm-4-flash，智谱 AI |
| **Ollama** | OpenAI 兼容（无 TLS） | 本地模型，apiKey 可空，CJH_PROVIDER=ollama 接入 |
| **Anthropic** | Anthropic API | Claude 系列，支持 cache_read_input_tokens |

## 十三、版本历史

| 版本 | 主要功能 |
|------|----------|
| v1.0.0 | 初始版本：TUI + Agent 循环 + 基础工具 |
| v1.1.0 | V2c 记忆分层 + V2b 插件系统 + 树形会话 + V3b Ollama 支持 |
| v1.2.0 | V2d 并发执行引擎 + P0-P2 工具效率提升 + 输入队列方案 B + Tasks 面板 + TodoWriteTool |
| v1.2.1 | 星霜青主题系统 + /theme 切换 + 回合总结条 + UI 打磨 |

## 十四、代码组织原则

- **高内聚低耦合**：满足软件设计六大原则（单一职责、开闭、里氏替换、接口隔离、依赖倒置、迪米特法则）
- **单向依赖 + 回调注入**：循环依赖靠单向依赖 + 回调注入解决，禁止"移包打补丁"破坏包内聚性
- **包结构**：`cjh.agent`（Agent 核心）→ `cjh.tools`（工具）→ `cjh.tui`（TUI）→ `cjterm`（终端组件）→ `cjllm`（LLM 协议）→ `cjcfg`（配置）

---

## 十五、待推进功能（v2 路线图）

| 优先级 | 功能 | 说明 |
|--------|------|------|
| P1 | V2e IM 网关 | Channel 抽象 + Web 渠道 + 审批远程化 |
| P1 | V3 信任链 | 签名信任链 + 编译期类型安全 |
| P2 | V4 多 Agent | 多 agent 协作 + 鸿蒙原生适配 |
| P2 | P3-P4 工具效率 | LSP 语义高亮 + DAP 调试栈展示 |
