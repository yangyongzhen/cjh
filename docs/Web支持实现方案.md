# Web 支持实现方案

> 创建：2026-08-25
> 状态：方案落盘，待实现
> 目标：`cjh web` 启动 HTTP 服务器 + WebSocket 流式推送，浏览器端聊天界面

---

## 一、背景与动机

cjh 目前有三种入口模式：

| 模式 | 入口 | 说明 |
|------|------|------|
| TUI | 默认 | 全屏终端 UI，差分渲染 + ANSI |
| CLI | `--no-tui` | 管道/脚本交互，stdout 输出 |
| JSON | `--mode json` | 无头模式，JSON-RPC over stdin/stdout |

**缺失场景**：远程访问、移动端访问、无法安装仓颉运行时的机器、可视化富文本展示。

**Web 支持的核心价值**：
- 浏览器即客户端，零安装门槛
- 跨设备访问（手机/平板/远程服务器）
- 富文本渲染（Markdown + 代码高亮 + Mermaid 图表）
- 文件上传/下载可视化
- 多会话标签页管理

---

## 二、技术选型

### 2.1 仓颉标准库能力

仓颉 `stdx.net.http` 自带 HTTP/1.1 + HTTP/2 + WebSocket 服务端：

| 能力 | API | 说明 |
|------|-----|------|
| HTTP Server | `ServerBuilder` + `Server.serve()` | 静态资源托管 + REST API |
| WebSocket | `WebSocket.upgradeFromServer(ctx)` | 流式推送 LLM 增量输出 |
| 路由分发 | `HttpRequestDistributor` | URL 路径 → handler 映射 |
| TLS | `ServerBuilder.tlsConfig()` | HTTPS 支持（可选） |

**结论**：无需引入第三方依赖，纯仓颉标准库即可实现。

### 2.2 前端技术栈

| 选项 | 优点 | 缺点 |
|------|------|------|
| 原生 HTML + Vanilla JS | 零构建、零依赖、单文件 | 代码冗长，无组件复用 |
| Preact + htm（CDN） | 轻量组件化，无需构建 | CDN 依赖，离线不可用 |
| Svelte 单文件编译 | 编译期优化，体积小 | 需 Node.js 构建链 |

**选择**：**原生 HTML + Vanilla JS + CSS 变量主题系统**。

理由：
- cjh 的定位是"单二进制零依赖"——前端也应零依赖
- 单 HTML 文件嵌入二进制资源，HTTP Server 直接 serve
- CSS 变量复用 cjh 的 6 套主题配色
- 后续如需复杂交互，可渐进引入 Preact

### 2.3 通信协议

**WebSocket（主）**：流式场景

```
浏览器                    cjh web server
  │                            │
  │── WS connect ─────────────→│
  │                            │
  │── {"type":"chat",          │
  │    "message":"..."} ──────→│
  │                            │── Agent.run(msg)
  │←─ {"type":"delta",         │
  │    "text":"..."} ──────────│  ← onDelta 回调
  │←─ {"type":"tool_start",    │
  │    "name":"bash"} ─────────│  ← onToolStart 回调
  │←─ {"type":"tool_result",   │
  │    "name":"bash",          │
  │    "content":"..."} ───────│  ← onToolResult 回调
  │←─ {"type":"done",          │
  │    "summary":{...}} ───────│  ← RunSummary
  │                            │
```

**HTTP REST（辅）**：非流式操作

| 端点 | 方法 | 说明 |
|------|------|------|
| `GET /api/sessions` | GET | 列出历史会话 |
| `GET /api/sessions/:id` | GET | 获取会话消息历史 |
| `POST /api/sessions/:id/fork` | POST | 分支会话 |
| `GET /api/models` | GET | 列出可用模型 |
| `POST /api/model/switch` | POST | 切换模型 |
| `GET /api/tasks` | GET | 获取当前任务列表 |
| `GET /api/health` | GET | 健康检查 |

---

## 三、架构设计

### 3.1 模块划分

```
src/web/
├── server.cj          # WebServer：HTTP + WebSocket 服务器启动/路由
├── ws_handler.cj      # WebSocketHandler：WS 连接生命周期 + 消息分发
├── rest_api.cj        # RestApi：REST 端点处理（会话/模型/任务）
├── session_mgr.cj     # WebSessionManager：浏览器会话 → Agent 实例映射
├── static_assets.cj   # 嵌入式静态资源（HTML/CSS/JS 仓颉字符串常量）
└── protocol.cj        # WS 消息协议定义（ChatRequest/DeltaEvent/DoneEvent...）

src/web/frontend/      # 前端源码（开发用）
├── index.html
├── app.js
├── styles.css
└── themes.css         # 6 套主题 CSS 变量
```

### 3.2 包结构

```
cjh (main)
├── cjh.agent          # Agent 核心
├── cjh.tools          # 工具系统
├── cjh.tui            # TUI 终端界面
├── cjh.web            # Web 服务器（新增）
├── cjterm             # 终端组件库
├── cjllm              # LLM 协议层
├── cjcfg              # 配置管理
└── cjutil             # 通用工具
```

**依赖关系**（单向，无循环）：

```
cjh.web ──→ cjh.agent ──→ cjh.tools ──→ cjllm
   │           │                          │
   │           └──→ cjcfg ←──────────────┘
   │
   └──→ stdx.net.http（仓颉标准库）
```

### 3.3 与 Agent 的集成

`Agent` 已暴露三个回调，Web 层直接挂接：

```cangjie
// 伪代码
let agent = Agent(provider, registry, config)

agent.onDelta = { delta =>
    ws.broadcast(DeltaEvent(text: delta))
}

agent.onToolStart = { name, args =>
    ws.broadcast(ToolStartEvent(name: name, args: args))
}

agent.onToolResult = { name, result =>
    ws.broadcast(ToolResultEvent(name: name, content: result.content, isError: result.isError))
}

// WebSocket onMessage → agent.run(msg)
ws.onMessage = { msg =>
    match (parseMessageType(msg)) {
        case ChatRequest(message) =>
            let summary = agent.run(message)
            ws.send(DoneEvent(summary: summary))
        case _ => ()
    }
}
```

### 3.4 多会话管理

每个浏览器标签页对应一个 WebSocket 连接，每个连接绑定一个 `Agent` 实例：

```cangjie
class WebSessionManager {
    // WS 连接 ID → Agent 实例
    private var agents: HashMap<String, Agent>

    // 创建新会话
    func createSession(wsId: String, config: AgentConfig): Agent

    // 恢复历史会话
    func resumeSession(wsId: String, sessionId: String): Agent

    // 销毁会话（WS 断开时）
    func destroySession(wsId: String): Unit
}
```

---

## 四、消息协议定义

### 4.1 浏览器 → 服务器

```typescript
// 发送聊天消息
{ "type": "chat", "message": "用 echo 工具回显 hello" }

// 中断当前执行
{ "type": "abort" }

// 切换模型
{ "type": "switch_model", "model": "deepseek-v4-flash" }

// 新建会话
{ "type": "new_session" }

// 恢复历史会话
{ "type": "resume_session", "session_id": "s1787665309.605" }

// 压缩历史
{ "type": "compact" }
```

### 4.2 服务器 → 浏览器

```typescript
// LLM 增量输出（流式）
{ "type": "delta", "text": "已用 echo 工具" }

// 工具调用开始
{ "type": "tool_start", "name": "echo", "args": {"message": "hello"} }

// 工具调用结束
{ "type": "tool_result", "name": "echo", "content": "[echo plugin] message: hello", "is_error": false }

// 回合结束总结
{ "type": "done", "summary": { "rounds": 2, "tools": 1, "duration_ms": 4062, "tokens": 4855, "cached": 96 } }

// 错误
{ "type": "error", "message": "Provider 连接失败" }

// 任务列表更新
{ "type": "tasks", "tasks": [{"id": 1, "content": "...", "status": "doing"}] }
```

---

## 五、前端设计

### 5.1 页面布局

```
┌────────────────────────────────────────────────────┐
│ cjh · Web           [模型: deepseek-v4-flash ▼]    │
├──────────┬─────────────────────────────────────────┤
│ 会话列表  │  对话区                                  │
│          │                                          │
│ • hello   │  ❯ 用 echo 工具回显 hello               │
│ • test    │                                          │
│ • ...     │  ▶ echo message: hello                  │
│          │    ↳ [echo plugin] message: hello       │
│          │                                          │
│          │  已用 echo 工具回显消息：hello ✓          │
│          │  ─── 2 rounds · 1 tools · 4.06s ───     │
│          │                                          │
│ [+ 新建]  ├─────────────────────────────────────────┤
│          │  [输入消息...                    ] [发送] │
└──────────┴─────────────────────────────────────────┘
```

### 5.2 主题复用

cjh 的 6 套 TUI 主题配色导出为 CSS 变量：

```css
:root {
  --bg-primary: #0d1117;
  --bg-secondary: #161b22;
  --text-primary: #e6edf3;
  --accent: #58a6ff;
  --border: #30363d;
  /* ... */
}

[data-theme="starfrost"] {
  --bg-primary: #0a1628;
  --accent: #4dd0e1;
  /* ... */
}
```

浏览器端通过 `localStorage` 持久化主题选择，与 cjh 的 `settings.json` 解耦。

### 5.3 Markdown 渲染

采用轻量级方案：
- **marked.js**（~28KB）：Markdown → HTML
- **highlight.js**（~30KB）：代码高亮
- **DOMPurify**（~20KB）：XSS 防护

这三个库通过 CDN 引入（离线模式下降级为纯文本展示）。

> 后续可考虑将这三个库的源码嵌入 cjh 二进制，实现完全离线。

---

## 六、安全模型

### 6.1 访问控制

| 场景 | 默认策略 | 配置项 |
|------|----------|--------|
| 本机访问 | 允许 `127.0.0.1` | `web.bind_addr` |
| 局域网访问 | 禁止（需显式开启） | `web.bind_addr = "0.0.0.0"` |
| 远程访问 | 禁止 | 建议 SSH 隧道 + `127.0.0.1` |

### 6.2 认证

```cangjie
// CjhConfig 新增
public var webEnabled: Bool = false
public var webPort: UInt16 = 8765
public var webBindAddr: String = "127.0.0.1"
public var webAuthToken: String = ""  // 空=不鉴权
```

- `webAuthToken` 非空时，HTTP 请求需携带 `Authorization: Bearer <token>` 头
- WebSocket 连接时通过 `?token=<token>` 查询参数鉴权
- 启动时若 `webAuthToken` 为空且 `bind_addr != 127.0.0.1`，打印安全警告

### 6.3 输入校验

- WebSocket 消息大小限制（默认 1MB）
- JSON Schema 校验入站消息
- HTML 转义所有用户输入（防 XSS）

---

## 七、实现计划

### Step 1：HTTP Server 骨架 + 静态资源托管

**目标**：`cjh web` 启动 HTTP 服务器，浏览器访问看到聊天界面（无后端逻辑）。

**任务**：
1. `CjhConfig` 新增 `webEnabled`/`webPort`/`webBindAddr`/`webAuthToken` 字段
2. `src/web/server.cj`：`WebServer` 类，`ServerBuilder` 启动 HTTP 服务器
3. `src/web/static_assets.cj`：前端 HTML/CSS/JS 嵌入为仓颉字符串常量
4. `src/main.cj`：`--web` 命令行参数（或 `cjh web` 子命令），启动 `WebServer`
5. `src/web/frontend/`：前端源码——`index.html` + `app.js` + `styles.css`
6. 路由：`GET /` → 返回 `index.html`；`GET /assets/*` → 返回 CSS/JS

**验证**：`cjh web` → 浏览器访问 `http://localhost:8765` → 看到聊天界面骨架

### Step 2：WebSocket 流式通信

**目标**：浏览器发送消息，cjh 执行 Agent 循环，流式回传 LLM 输出 + 工具调用状态。

**任务**：
1. `src/web/protocol.cj`：WS 消息协议定义（`ChatRequest`/`DeltaEvent`/`ToolStartEvent`/`ToolResultEvent`/`DoneEvent`/`ErrorEvent`）
2. `src/web/ws_handler.cj`：`WebSocketHandler`——WS 握手、消息分发、`Agent` 回调 → WS 推送
3. `src/web/session_mgr.cj`：`WebSessionManager`——WS 连接 → `Agent` 实例映射
4. `Agent` 三个回调（`onDelta`/`onToolStart`/`onToolResult`）挂接到 WS 推送
5. 前端 `app.js`：WebSocket 连接管理、消息接收、对话渲染

**验证**：浏览器发送"用 echo 工具回显 hello" → 看到 delta 流式输出 + 工具调用状态 + 回合总结

### Step 3：REST API + 多会话管理

**目标**：完整的会话管理（新建/恢复/分支/历史）、模型切换、任务列表。

**任务**：
1. `src/web/rest_api.cj`：REST 端点处理
   - `GET /api/sessions` → `SessionStore.listSessions()`
   - `GET /api/sessions/:id` → `SessionStore.loadHistory()`
   - `POST /api/sessions/:id/fork` → 分支会话
   - `GET /api/models` → 列出可用模型
   - `POST /api/model/switch` → 切换模型
   - `GET /api/tasks` → `Agent.getTodos()`
   - `GET /api/health` → 健康检查
2. `src/web/session_mgr.cj`：多会话生命周期管理（创建/恢复/销毁）
3. 前端：会话列表侧边栏、模型切换下拉框、任务列表面板

**验证**：
- 浏览器新建会话 → 发消息 → 刷新页面 → 会话列表显示该会话 → 点击恢复 → 历史消息加载
- 切换模型 → 发消息 → 响应来自新模型
- 任务列表面板实时更新

### Step 4：前端打磨 + 主题系统

**目标**：生产可用的前端界面。

**任务**：
1. Markdown 渲染（marked.js + highlight.js + DOMPurify）
2. 代码块复制按钮
3. 6 套主题 CSS 变量 + 主题切换器
4. 移动端响应式布局
5. 输入框：多行编辑（Shift+Enter 换行，Enter 发送）
6. 会话重命名/删除
7. 错误提示 Toast

**验证**：
- 发送 Markdown 内容 → 正确渲染（标题/列表/代码块/表格）
- 切换主题 → 配色实时变化
- 手机浏览器访问 → 布局自适应

### Step 5（可选）：TLS + 远程访问安全

**任务**：
1. `ServerBuilder.tlsConfig()` 配置 TLS 证书
2. `webAuthToken` 鉴权中间件
3. 启动安全审计日志

---

## 八、配置示例

### 8.1 `settings.json` 新增字段

```json
{
  "web": {
    "enabled": true,
    "port": 8765,
    "bind_addr": "127.0.0.1",
    "auth_token": "",
    "max_request_size": 1048576
  }
}
```

### 8.2 命令行

```bash
# 启动 Web 服务器（默认 127.0.0.1:8765）
cjh web

# 指定端口
cjh web --port 9000

# 局域网访问（需显式开启）
cjh web --bind 0.0.0.0 --token mySecret123

# 同时启动 TUI + Web（后台 Web 服务器）
cjh --web
```

---

## 九、风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| WebSocket 并发写非线程安全 | 崩溃 | WS 写操作加锁，或用 channel 串行化 |
| Agent.run 阻塞 WS 读取 | 无法接收 abort | `Agent.run` 在独立协程执行，WS 读取协程独立 |
| 前端 XSS（用户输入渲染为 HTML） | 安全漏洞 | DOMPurify 转义所有动态内容 |
| 远程访问未鉴权 | 任意人可调用工具 | 默认 `127.0.0.1`，远程需 `auth_token` |
| 大文件传输内存压力 | OOM | 分块传输 + 流式写入磁盘 |
| WS 断连后 Agent 继续执行 | 资源泄漏 | WS 断连触发 `abort`，Agent 检测中断标志 |

---

## 十、与现有架构的兼容性

### 10.1 不影响 TUI/CLI/JSON 模式

Web 模式是**新增的第四种入口模式**，与现有三种模式完全隔离：

```cangjie
// main.cj 入口分发
match (mode) {
    case "tui" => runTui(config)
    case "cli" => runCli(config)
    case "json" => runJson(config)
    case "web" => runWeb(config)  // 新增
    case _ => runTui(config)
}
```

### 10.2 复用 Agent 核心逻辑

Web 层**不重新实现 Agent 循环**，直接复用 `Agent.run(userInput)` 和三个回调。这意味着：
- 工具系统（bash/read_file/write_file/...）自动可用
- 插件系统（plugin.json + 事件钩子）自动可用
- MCP 协议支持自动可用
- 会话管理（树形会话/Compaction）自动可用
- 所有 Provider（OpenAI/DeepSeek/GLM/Ollama/Anthropic）自动可用

### 10.3 不引入新依赖

纯仓颉标准库实现，保持"单二进制零依赖"原则。

---

## 十一、验收标准

| # | 标准 | 验证方法 |
|---|------|----------|
| 1 | `cjh web` 启动 HTTP 服务器 | `curl http://localhost:8765/api/health` 返回 200 |
| 2 | 浏览器看到聊天界面 | 手动访问 `http://localhost:8765` |
| 3 | 发送消息收到流式响应 | 浏览器发送"hello"→看到 delta 逐字输出 |
| 4 | 工具调用状态实时展示 | 发送"用 echo 工具回显 hello"→看到 tool_start + tool_result |
| 5 | 多会话管理 | 新建/恢复/分支会话，刷新页面历史保留 |
| 6 | 模型切换 | 下拉切换模型，后续消息来自新模型 |
| 7 | 6 套主题切换 | 主题选择器切换，配色实时变化 |
| 8 | 移动端响应式 | 手机浏览器访问，布局自适应 |
| 9 | Markdown 渲染 | 发送 Markdown 内容，正确渲染标题/列表/代码块/表格 |
| 10 | 安全默认值 | 默认仅 127.0.0.1 可访问，远程需 auth_token |

---

## 十二、后续扩展方向

| 方向 | 说明 |
|------|------|
| **V2e IM 网关对接** | Web 服务器复用 Channel 抽象，Web 端成为 Channel 之一 |
| **多 Agent 协作可视化** | 前端展示 Agent 间消息流转 DAG |
| **工具执行沙箱可视化** | 实时展示 WASM 沙箱内的工具执行状态 |
| **文件编辑器集成** | Monaco Editor 展示 hashline_edit 的 diff |
| **会话回放** | 前端播放历史会话的 delta/tool 流 |
