# cjh 集成指南（进程外 web 模式）

> 给想把 cjh（仓颉 Coding Agent Harness）集成进自己应用的人。
> 语料来源：cjh 仓 `src/web/{rest_api,protocol}.cj`（协议权威定义）+
> lingqu / cj-tauri `examples/ai-chat` / cjnote 三个已验证的集成实现 +
> lingqu `AGENTS.md` §4 的实测坑。**协议以 cjh 仓源码为准，本文是接入视角的导览。**

---

## 0. 三种集成形态，为什么选进程外 web 模式

| 形态 | 结论 |
|---|---|
| 进程内嵌 cjh 为库 | **不可行**：cjh 是 executable 根包（仓颉限制：根包不能被导入）；且 agent 崩溃面会耦合进 UI |
| 自己写 mini-agent | 丢掉 cjh 的技能/审批/压缩/工具/MCP 生态，得不偿失 |
| **进程外 `cjh web` 子进程**（选用） | REST + WS（`127.0.0.1:8765`）；崩溃隔离；可换 cjh 版本；TUI/浏览器/桌面共享同一 agent 与工具链。已有三个验证实现：cj-tauri `examples/ai-chat`（33KB 托管代码可直接抄）、cjnote、lingqu |

---

## 1. 拉起与收尾：六条语义（D-003，照抄不会错）

宿主应用对 cjh 子进程的生命周期管理，实测沉淀为六条：

1. **就绪判据只有一条**：`GET /api/health` 返回 200。没有"看着像起来了"这种模糊态；等待口径 100ms × 10s，超时**不算成功**（留进程等重试）。
2. **复用优先，不抢不杀**：8765 上已有活的 cjh（可能是用户自己开的）就复用，退出时**也不动它**。
3. **只收自己拉起的**：宿主记录"本应用拉起"标志（如 `owned=true`），只有 owned 的实例在退出时终止。
4. **拉起方式必须隐藏窗口**：宿主是 GUI 子系统时，`std.process.launch` 类调用会给子进程配黑窗口（Windows），要用 `launchHidden`（`CreateProcessW` + `DETACHED_PROCESS`）。
5. **只绑回环**：自己拉起的一律加 `--bind 127.0.0.1`——cjh web 默认绑 `0.0.0.0` 且默认无鉴权。
6. **收尾用守护线程**：新形态应用常没有 onExit 钩子；守护线程 `waitForExit()` 后收，且收 5 轮以覆盖"秒关窗口"的抢跑。

```bash
# 最小拉起命令
cjh web --port 8765 --bind 127.0.0.1
```

---

## 2. REST API（`/api/*`）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/health` | GET | 健康检查 → `{status, version, web_port}`；**接入第一件事就是轮询它** |
| `/api/capabilities` | GET | 服务端能力自述（引擎支持什么） |
| `/api/sessions` | GET | 历史会话列表 |
| `/api/sessions/{id}` | GET/… | 单会话详情（`{id, title, created_at, messages, corrupted, defects}`）；支持重命名/删除 |
| `/api/models` | GET | 可用模型列表 |
| `/api/model/switch` | POST | 切换模型 |
| `/api/skills` | GET | 已装技能列表 |
| `/api/mcp` | GET | MCP 服务器配置 |
| `/api/tasks` | GET | 当前任务列表 |
| `/api/settings` | GET/POST | 读取/写回 settings.json（GET 对 apiKey 脱敏） |
| `/api/workspaces` | GET/POST/DELETE | 工作区管理 |
| `/api/workspaces/switch` | POST | 切换工作区（真正生效） |
| `/api/fs/list?path=` | GET | 目录列表（前端目录选择器用） |

- **鉴权**：配置了 token 后 `/api/*` 都必须携带（`src/web/auth.cj`）。
- **settings 与密钥分离**：模型/温度在 `~/.cjh/settings.json`，**API Key 在 `~/.cjh/auth.json`**——
  改 settings 不会丢密钥，但 POST 回写会重排 JSON 格式，**改前先备份**。
- 前端**不要直接出网**打这些端点（CORS + 能力清单开口子问题）——宿主后端代理转发。

---

## 3. WebSocket 协议（帧式 JSON，每帧带 `type`）

连接：`ws://127.0.0.1:8765/ws`（或 cjh 输出的实际路径）。所有帧是单行 JSON 对象。

### 客户端 → 服务端

| type | 载荷 | 说明 |
|---|---|---|
| `chat` | `{message}` | 发起回合（回合 = 一次完整 agent 循环） |
| `abort` | — | 中断当前回合 |
| `switch_model` | `{model, ...}` | 切换模型 |
| `new_session` | — | 新建会话 |
| `resume_session` | `{session_id}` | 恢复历史会话（`done.summary.session_id` 接住后重连时用） |
| `compact` | — | 压缩当前上下文 |
| `approval_response` | `{request_id, allow}` | 回执审批（request_id 原样回传） |

### 服务端 → 客户端

| type | 载荷 | 说明 |
|---|---|---|
| `delta` | `{text, ...}` | **流式文本增量**（注意：text 是裸字符串字段，见 §4 坑 1） |
| `tool_start` | `{name, args, ...}` | 工具调用开始（可选 agent 身份字段，缺省=父回合） |
| `tool_result` | `{name, content, is_error, ...}` | 工具结果；**认 `is_error`** 渲染错误态 |
| `done` | `{summary}` | 回合结束；`summary.finish_reason`：`stop`（正常）/`cancelled`（被中断）/`error`（异常）；`summary.session_id` 用于续接 |
| `ack` | `{action, session_id}` | 控制指令回执 |
| `cancelled` | `{session_id, was_running}` | 中断确认 |
| `approval_request` | `{request_id, tool, ...}` | **危险操作审批请求，回合在此阻塞**；等 `approval_response`，超时按拒绝收场 |
| `error` | `{message, code, request_id?}` | 错误（审批类错误带 request_id） |
| `tasks` | `{tasks:[{id,content,status}]}` | 任务清单（status: pending/doing/done） |
| `history_messages` | `{session_id, messages}` | 恢复会话时的历史回放 |

---

## 4. 实测坑（三个集成方都踩过的）

### 坑 1：帧解包必须先认 `p.type`（头号坑）

`delta` 帧自带 `text` **裸字段**——先按"包装体 `{data:...}`"去 `JSON.parse` 会抛异常。
顺序固定：**`p.type` → `p.text` → `p.data` → 字符串 parse**。cjnote 与 lingqu 踩过同一坑。

### 坑 2：审批卡不会自己冒出来

cjh **默认宽松模式**（settings.json 无 `capability` 段 = 所有工具放行）。要开发/验证审批流，
需临时设 `capability.enabled=true` + `approval:["*:*"]`，**验完必须恢复**（密钥在
`auth.json` 不在 settings.json，但仍先备份——回写会重排格式）。

### 坑 3：UI 状态只信 `ws:state` 类连接态事件

自动连接 + 退避重连 + `session_id` 接住后发 `resume_session`——不要用"发消息没报错"当连接判据。

### 坑 4：宿主后端代理，前端不直连

前端直接 `fetch('http://127.0.0.1:8765/api/...')` 会撞 CORS，还会绕过宿主的能力白名单。
正确姿势：宿主后端提供命令（如 lingqu 的 `t2h:cjh_models`），前端走 IPC。

---

## 5. 能力与审批（宿主可选的严格化）

- 默认宽松：无 `capability` 段 = 全放行，适合个人工具。
- 严格模式：`settings.json` 的 `capability` 段 `{enabled: true, allow:[...], approval:["*:*"]}`——
  工具白名单 + 危险操作审批。宿主集成给第三方用户时**建议默认严格**。
- 服务端能力自述可经 `/api/capabilities` 动态探测，不要硬编码。

## 6. 分发与校验（随包引擎）

- 随包 cjh 二进制必须过 **SHA256** 校验，验不过**绝不解包也不执行**（D-004；供应链防线）。
- lingqu 的做法：`vendor/cjh/<platform>/cjh` + `SHA256SUMS` 入库，拉起前逐文件校验。
- 多平台产物各自入库（win-x64 / linux-x64 / ohos——注意鸿蒙端 cjh 无 ws 能力位，
  对话通道需另设计，见 lingqu 会话交接）。

## 7. 最小接入清单（照做即通）

1. 拉起 `cjh web --port 8765 --bind 127.0.0.1`（hidden），轮询 `/api/health` 到 200
2. WS 连接，发 `{type:"chat", message:"..."}`，按 §4 坑 1 的顺序解帧
3. 渲染：`delta` 节流累积 → `tool_start/tool_result` 出工具卡（认 `is_error`）→
   `done` 认 `finish_reason` 并存 `session_id`
4. `approval_request` 出审批卡，超时按拒绝回 `approval_response`
5. 重连时先 `resume_session`
6. 退出时只收自己拉起的实例（守护线程，多轮收尾）

> 现成参考实现：`cj-tauri/examples/ai-chat/src/cjh_host.cj`（托管六条语义的完整仓颉实现，
> lingqu 即由此移植）；前端帧处理参考 cjnote 与 lingqu `assets/ui/index.html`。
