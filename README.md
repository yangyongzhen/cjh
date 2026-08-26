<div align="center">

# cjh · 仓颉 Coding Agent

**用华为仓颉语言从零实现的交互式编码代理**

终端里用自然语言描述任务 → Agent 理解意图、自主规划、调用工具、观察结果、迭代直至完成。全流程在 TUI 中实时呈现，亦可通过 Web 远程驱动。

[功能](#-功能一览) · [快速开始](#-快速开始) · [架构](#-架构) · [插件生态](#-插件生态与信任链) · [文档](#-文档) · [路线图](#-路线图)

</div>

---

## 🌟 为什么是 cjh

| | |
|---|---|
| **仓颉原生的 Coding Agent** | 从 Agent 核心、工具系统、TUI 渲染到 Web Server，全部用仓颉语言实现，是仓颉生态在 AI 编程领域的旗舰实践。 |
| **单二进制 · 零运行时依赖** | 仓颉 `cjnative` 静态编译，一个二进制跑起来，无需 Python/Node 环境。 |
| **多 Provider 开箱即用** | OpenAI / DeepSeek / GLM / Anthropic / Ollama 全兼容，`/provider` 热切换。 |
| **插件信任链** | SHA256 校验和 + SM2 国密签名验证（仓颉 `stdx.crypto` 原生），防供应链投毒。 |
| **并发执行引擎** | DAG 依赖分析 + 拓扑分组调度，LLM 并行工具调用自动并发执行。 |
| **Web 原生支持** | 内置 HTTP Server + WebSocket 流式对话 + REST API + 前端 SPA，远程驱动 Agent。 |

## 🚀 功能一览

### Agent 核心

- **多轮工具调用循环**：消息历史 → LLM → 工具调用 → 结果回填 → 再调用，支持复杂任务编排
- **三域 Capability 安全模型**：commands / tools / resources 白名单 + 危险操作审批链
- **自动 Compaction**：消息条数超阈值自动 LLM 摘要压缩早期历史
- **项目指令**：自动加载 `AGENTS.md` / `.atomcode.md` 项目指令注入 system prompt

### 工具系统（7 个内置 + 可扩展）

| 工具 | 说明 |
|---|---|
| `bash` | 执行 shell 命令，捕获 stdout/stderr |
| `read_file` | 读取文件，大文件返回符号摘要，offset/limit 按需展开 |
| `write_file` | 写入文件（创建/覆盖） |
| `hashline_edit` | 行号锚点 `@@N` + 内容验证编辑 |
| `grep` | 目录树递归搜索，gitignore 感知 |
| `list_dir` | 列出目录树 |
| `todo_write` | LLM 通过工具调用管理任务列表 |

### 并发执行引擎（V2d）

- **DAG 依赖分析**：从 `ToolCall` 提取资源访问 `(path, isWrite)`，自动构建依赖图
- **拓扑分组调度**：同组工具 spawn 并发，组间串行，保持 LLM 原始回填顺序
- **性能基线测量**：`parallelBatches` / `parallelSavedMs` / `maxParallelism` 三维统计

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

- **全屏 TUI**：差分渲染 + ANSI 转义，termios 原始模式（纯 libc FFI）
- **Markdown 渲染**：标题 / 列表 / 代码块 / 表格 / 链接
- **6 套主题**：starfrost（星霜青）/ classic / catppuccin / rose-pine / solarized / monokai，`/theme` 实时切换
- **多行编辑器**：Ctrl+E 进入，Alt+Enter 提交
- **斜杠命令补全**：`/` 触发下拉补全
- **Tasks 面板**：Agent 内置任务列表实时展示
- **回合总结条**：`✓ 2 rounds · 3 tools · 42.6s · 1.53K tokens · 99% cached`
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

### 无头模式

- **JSON 模式**：`--mode json` 无头模式，输出 JSON 结果（脚本可解析）
- **CLI 模式**：`--cli` 命令行交互模式
- **Mock 模式**：`--mock` 验证模式，使用 MockProvider，无 API Key 也能测

## 🔧 快速开始

### 环境要求

- 仓颉 SDK 1.0.5+（`cjc` / `cjpm`）
- stdx 扩展标准库
- Linux（本项目纯终端，无 GUI 依赖）

### 构建

```bash
# 激活仓颉环境
source /path/to/cj-env.sh

# 构建
cjpm build
```

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
./target/release/bin/main

# CLI 模式（纯文本交互）
./target/release/bin/main --cli

# JSON 无头模式（脚本集成）
./target/release/bin/main --mode json "用 grep 搜索 TODO"

# 恢复历史会话
./target/release/bin/main --resume <session-id>

# Mock 模式（无 API Key 演示）
CJH_MOCK=1 ./target/release/bin/main

# Web 模式（远程驱动 Agent）
./target/release/bin/main web --port 8765 --token my-secret
```

### 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `CJH_API_KEY` | API Key（任一） | — |
| `CJH_BASE_URL` | LLM 端点 | OpenAI |
| `CJH_MODEL` | 模型名 | gpt-4o-mini |
| `CJH_PROVIDER` | Provider 切换（openai/anthropic/ollama） | openai |
| `CJH_MOCK` | `1` 启用 mock | 关 |
| `CJH_CONFIG_DIR` | 配置目录 | `~/.cjh` |

## 📁 架构

```
┌─────────────────────────────────────────────────────────┐
│                    cjh 主入口 (main.cj)                   │
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
│  cjterm（终端 UI）· cjcfg（配置）· cjutil（SHA256/SM2）  │
└─────────────────────────────────────────────────────────┘
```

### 包划分

| 包 | 职责 |
|---|---|
| `cjh.agent` | Agent 主循环编排（消息状态机 + 工具调用 + DAG 并发） |
| `cjh.tools` | 工具接口、注册中心、内置工具、插件系统、MCP 客户端 |
| `cjh.tui` | TUI 应用层（对话界面、Markdown 渲染） |
| `cjh.web` | Web Server（HTTP + WebSocket + REST API + 前端 SPA） |
| `cjterm`（libs/） | **独立终端 UI 库**：ANSI / 差分渲染 / termios / 6 套主题（纯 libc FFI，可复用） |
| `cjllm`（libs/） | **独立 LLM 协议库**：OpenAI / Anthropic / Ollama / SSE / Mock |
| `cjcfg`（libs/） | **独立配置库**：settings.json / auth.json / 环境变量 / 会话管理 |
| `cjutil`（libs/） | **独立工具库**：SHA256 / SM2 签名 / UTF-8 / JSON 修复 / 日志 |

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
| v1.0.0 | 初始版本：TUI + Agent 循环 + 基础工具 |
| v1.1.0 | 记忆分层 + 插件系统 + 树形会话 + Ollama 支持 |
| v1.2.0 | 并发执行引擎 + 工具效率提升 + Tasks 面板 |
| v1.2.1 | 星霜青主题系统 + /theme 切换 |
| v1.2.2 | 回合总结条 + /compact + /tree + /fork |
| v1.2.3 | SSE 空闲超时 + 工具结果截断与回溯 + MCP 协议支持 + 6 套主题 |
| **v1.3.0** | **Web 支持 + 插件信任链（SHA256 + SM2 签名）+ require_signature 配置** |

## 🗺️ 路线图

### ✅ 已完成

- [x] **V1**：Agent 核心 + 工具 + 双协议 + TUI + 会话 + mock
- [x] **V2a**：三域 Capability + 审批链
- [x] **V2b Step 1+2**：plugin.json + Shell 工具插件 + 事件钩子
- [x] **V2b MCP 扩展点**：McpClient stdio + McpTool 代理 + McpManager
- [x] **V2c**：Compaction + AGENTS.md 项目指令
- [x] **V2d 并发引擎**：DAG 依赖分析 + 拓扑分组调度 + 性能基线
- [x] **V3 信任链 Step 1+2**：SHA256 校验和 + SM2 签名验证
- [x] **Web 支持 Step 1-5**：HTTP Server + WebSocket + REST API + 前端 SPA + 鉴权

### 🔜 进行中

- [ ] **V3 信任链 Step 3**：信任管理 CLI（`/cjh trust` / `untrust` / `trust-list`）
- [ ] **V2e IM 网关**：Channel 抽象 + Web 渠道 + 审批远程化

### 📋 计划中

- [ ] **V2b Step 3**：WASM 工具沙箱 + 中心仓 + `cjh install`
- [ ] **Web TLS**：`ServerBuilder.tlsConfig` 支持
- [ ] **V4 多 Agent**：多 Agent 协作 + 鸿蒙原生适配

## 📚 文档

- [方案与架构设计 v2](docs/方案与架构设计-v2.md) — 项目设计与架构
- [cjh 功能清单](docs/cjh功能清单.md) — 完整功能列表
- [插件系统实现方案](docs/插件系统实现方案.md) — 插件系统设计
- [插件签名与贡献指南](docs/插件签名与贡献指南.md) — 信任链与插件发布
- [Web 支持实现方案](docs/Web支持实现方案.md) — Web Server 设计
- [进度记录](docs/进度记录.md) — 开发进度与状态追踪
- [开发文档与踩坑记录](docs/开发文档与踩坑记录.md) — 仓颉工程踩坑经验

## 🤝 仓颉生态价值

cjh 是仓颉语言在 **AI 编程代理**领域的完整实践，为仓颉生态贡献：

| 贡献 | 说明 |
|---|---|
| **cjterm** | 独立终端 UI 库（ANSI / 差分渲染 / termios / 6 套主题），纯 libc FFI，任何仓颉终端项目可复用 |
| **cjllm** | 独立 LLM 协议库（OpenAI / Anthropic / Ollama / SSE / Mock），任何仓颉 AI 项目可复用 |
| **cjutil** | 独立工具库（SHA256 / SM2 签名 / UTF-8 / JSON 修复 / 日志），仓颉生态通用基础设施 |
| **MCP 协议实现** | 仓颉语言首个 MCP 客户端实现，为仓颉生态接入 MCP 工具网络铺路 |
| **插件信任链** | 仓颉 `stdx.crypto` 国密 SM2 在插件安全场景的实践范例 |
| **工程踩坑经验** | 完整记录仓颉开发中的 FFI / 编译 / 并发 / TLS 等坑点，降低后来者门槛 |

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
│   ├── agent/loop.cj       # Agent 主循环 + DAG 并发调度
│   ├── tools/              # 工具系统（内置工具 + 插件 + MCP）
│   ├── tui/                # TUI 应用层
│   ├── web/                # Web Server（HTTP + WS + REST + 前端）
│   └── main.cj             # CLI/TUI/JSON/Web/Mock 入口
├── libs/                   # 独立可复用库
│   ├── cjterm/             # 终端 UI 库（ANSI / 差分渲染 / termios / 主题）
│   ├── cjllm/              # LLM 协议库（OpenAI / Anthropic / Ollama / SSE）
│   ├── cjcfg/              # 配置库（settings.json / auth.json / 会话）
│   └── cjutil/             # 工具库（SHA256 / SM2 / UTF-8 / JSON 修复 / 日志）
├── example/                # 示例
│   ├── plugins/            # 插件示例（echo-test / log-pruner / signed-demo）
│   └── mcp/                # MCP 服务器示例
├── docs/                   # 文档
└── cjpm.toml               # 仓颉包管理配置
```

## 📄 License

MIT
