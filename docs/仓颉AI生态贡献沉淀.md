# 仓颉 AI 生态贡献沉淀（cjh）

> 面向仓颉 AI 生态的**可复用**贡献盘点。口径对齐比赛加分项：
> 「面向仓颉 AI 生态贡献可供其他开发者复用的 AI 工具、Skill、Agent、MCP 工具、工作流、提示模板、语料或示例能力」。
> 每项均锚定真实代码路径，可直接取用。版本基线：v1.3.13（2026-09-06）。

## 一、贡献总览

| 加分项口径 | cjh 对应资产 | 可复用性 |
|---|---|---|
| **MCP 工具** | MCP 客户端（`src/tools/mcp.cj`，565 行）+ 最小 MCP 服务器示例（`example/mcp/echo-mcp-server.sh`，60 行 bash） | 客户端可直接移植到任何仓颉应用；服务器示例可直接运行/改造成任意工具服务器 |
| **Skill** | Skills 子系统（`src/skills.cj`，453 行）+ 完整示例（`example/skills/example.md`） | Skill 文件格式开放（Markdown + frontmatter + 声明式工具），其他仓颉 Agent 可原样复用文件与解析器 |
| **Agent** | cjh 本体：全屏 TUI 编码 Agent（14 内置工具 + DAG 并发 + 后台异步 compaction + 树形会话 + 插件/MCP/Skills 扩展） | 整体可运行；`--mock` 无 API key 离线可验证全部工具链 |
| **AI 工具（可复用库）** | 5 个独立仓颉包：`cjterm` / `cjllm` / `cjcfg` / `cjutil` / `cjlog`（libs/，约 4000 行） | 零业务耦合，复制即用；规划发布为独立 cjpm 包贡献生态 |
| **提示模板** | 默认系统提示词 + 四层组装器 + compaction 摘要提示词 + 写入三件套引导（见 §四） | 模板与组装逻辑可直接移植 |
| **工作流** | CI 门禁（AGENTS.md）+ 发版流水线 + 双远端 pre-push 自动转发（见 §五） | 脚本/文档即取即用 |
| **示例能力** | `example/`：Skill / MCP 服务器 / 插件（含 SM2 签名插件、hook 插件）+ 跨平台静态发布包 + 完整测试语料（325 单测 + 15 PTY 场景） | 全部随仓库分发 |
| **语料（经验语料）** | 仓颉语言踩坑语料（30+ 坑，`docs/开发文档与踩坑记录.md`）+ 仓颉测试语法坑速查（AGENTS.md） | 仓颉开发者最稀缺的实战语料，已结构化成可查清单 |

---

## 二、MCP 工具

### 2.1 MCP 客户端（`src/tools/mcp.cj`）

完整的 **Model Context Protocol 客户端**，仓颉实现，协议版本 `2025-03-26`：

- **传输层**：stdio（`SubProcess.start` 启动子进程，stdin/stdout 交换，环境继承 + `config.env` 注入）
- **协议**：JSON-RPC 2.0，每行一条消息（`\n` 分隔）
- **生命周期**：`connect()`（initialize 握手 + `notifications/initialized`）→ `listTools()`（`tools/list` 解析 `McpToolDef`）→ `callTool(name, args)`（`tools/call` 转发，结果归一为 `ToolResult`）→ `disconnect()`（关闭子进程）
- **集成**：发现的 MCP 工具自动注册进 `ToolRegistry`，与内置工具、插件工具、Skill 声明式工具同池调度——Agent 无感调用
- **容错**：握手无 result / 未知方法 / 子进程异常均降级为 warn + 跳过，不拖垮主流程

**复用方式**：`McpClient` 仅依赖 `std.*` + `stdx.encoding.json` + `cjutil` + `cjcfg.McpServerConfig`，从 cjh 剥离成本极低，可作为独立包 `cjllm/mcp` 或直接拷贝进任何仓颉 LLM 应用。

### 2.2 最小 MCP 服务器示例（`example/mcp/echo-mcp-server.sh`）

60 行 bash + jq 的**完整可运行 MCP 服务器**，实现 `initialize` / `notifications/initialized` / `tools/list` / `tools/call` 四个方法，提供 `echo` 工具（含 `inputSchema` + `readOnlyHint` 注解）。

对生态的两层价值：
1. **给客户端开发者**：零依赖（仅需 jq）的调试靶子——任何仓颉 MCP 客户端（含 cjh）配一行 `mcp_servers` 即可端到端验证；
2. **给服务器开发者**：最小协议参考实现，注释标出关键坑（pipe 模式下 bash 全缓冲导致客户端读不到响应，须 `stdbuf -oL` 行缓冲）。

配置示例（`~/.cjh/settings.json`）：

```json
{
  "mcp_servers": {
    "echo": {
      "command": "bash",
      "args": ["example/mcp/echo-mcp-server.sh"],
      "transport": "stdio"
    }
  }
}
```

---

## 三、Skill（技能系统 + 示例）

### 3.1 Skills 子系统（`src/skills.cj`）

**"Skill 即文件"**——无需写代码，一个 Markdown 文件即为一个技能：

- **格式**：`~/.cjh/skills/<name>.md`，frontmatter（`name` / `description` / `tools`）+ 正文指令
- **正文**：注入 system prompt（"可用技能，按需使用"段）
- **`tools` 段**：声明式工具注册进 `ToolRegistry`——`command` 模板 + `${var}` 参数替换 + `args` 描述，模型可直接调用，零仓颉代码
- **开关**：`settings.json` 的 `enabled_skills` 数组（空 = 全部启用）
- **解析器**：`parseFrontmatter` 支持单行标量与多行块两种形态（多行块保留 JSON 数组字面量），不依赖任何 YAML 库

### 3.2 完整示例（`example/skills/example.md`）

展示完整形态：frontmatter 声明 2 个声明式工具（`echo_hi` 打招呼、`disk_usage` 查磁盘）+ 正文能力说明 + 用法示例。放入 `~/.cjh/skills/` 即生效，模型可直接说"用 disk_usage 查看 /tmp"。

**复用方式**：文件格式是开放 Markdown 子集，与业界主流 Agent 的 Skill 形态（Claude Code / Cursor 等）同构——其他仓颉 Agent 可直接复用这些 `.md` 文件，只需实现等价的"frontmatter 解析 + 正文注入 + 声明式工具注册"三步。

---

## 四、提示模板

| 模板 | 位置 | 内容 |
|---|---|---|
| **默认系统提示词** | `libs/cjcfg/src/config.cj:472` | 终端编码 Agent 基线：角色定位 + 工具清单描述 + 工具选择引导（`system_prompt` 可整段覆盖） |
| **四层提示词组装器** | `src/skills.cj:432` `buildSystemPrompt` | `base`（系统提示）→ `## 项目指令（AGENTS.md）`（向上 8 层查找）→ `## 可用技能`（启用中的 Skills）→ `## 项目记忆（上次会话）`（跨会话记忆注入）→ `## 工具结果截断`（回溯协议说明） |
| **compaction 摘要提示词** | `src/agent/loop.cj:1048` `requestSummary` | 长会话历史压缩：快模型路由 + 保留最近 N 轮 + 摘要替换早期消息（`compactKeep` 默认 6，实测 prompt 峰值 42.9K→9.4K） |
| **写入三件套引导** | 系统提示词 + 工具描述 | 对标 OMP 的写入协议引导：`write_file` 整段写入 / `append_file` 续写 / `edit_file` 行锚点编辑（hashline `@@N`），显著降低超长 content 截断率 |
| **工具结果截断与回溯提示** | `buildSystemPrompt` 尾部 | 告知模型"被截断的中间部分已存盘，用 read_file(offset, limit) 回溯"——对齐 Pi spill extension 模式 |

**沉淀经验（提示工程）**：
- 截断回溯必须**在提示词里告诉模型协议**，否则模型不知道省略标记里的路径可以读；
- 摘要保留条数（`compactKeep`）过小删不掉消息、过大压缩无效——实测 6 为中文长会话甜点值；
- 触发信号必须用**真实 `usage.promptTokens`**，字符估算实测低估 7x。

---

## 五、工作流（CI / 发版 / 协作）

### 5.1 CI 门禁（`AGENTS.md` + `scripts/`）

任何变更交付前的强制门禁，**文档即规范、脚本即凭证**：

```bash
./scripts/test.sh                # 325 单测全绿（自动切动态链接配置，结束后恢复）
python3 scripts/tui_pty_test.py  # 15 场景 49 断言（伪终端驱动真实 TUI）
cjpm build && ./cjh --mock       # 构建 + 无 key 离线端到端工具链验证
```

配套规范：**bug 修复先写复现测试（失败）再修（转绿）**；新工具/纯函数至少覆盖主路径 + 错误路径 + 一个边界；工具类走 `execute(args)` 公共 API 断言 observable 契约。

### 5.2 发版流水线（已固化为可执行步骤）

1. 版本号规则：重大更新递增中间位（v1.2.0→v1.3.0），小更新递增末位
2. 三处同步：`cjpm.toml` version + `libs/cjterm/src/logo.cj` `Logo.VERSION` + 标题栏注释
3. 双平台打包：Linux `cjpm build`（`--static --static-std`，单文件仅余系统库）；Windows `./scripts/winbuild.sh` 交叉编译（仓库内置 `docs/cangjie-stdx-windows-x64-1.0.5.1.zip`，zip = exe + 4 个 runtime/openssl DLL）
4. `dist/SHA256SUMS-v<ver>.txt` 生成并 `sha256sum -c` 自校验
5. 打 tag（annotated，含变更摘要）+ 推送

### 5.3 双远端协作钩子（`.git/hooks/pre-push`）

推 `origin`（gitcode）时自动转发同分支到 `github`（tag 除外，手动 `--tags`）；转发失败不阻断主推送、仅 stderr 提醒。脚本 30 行 POSIX sh，可直接拷给任何双托管项目。

---

## 六、示例能力（随仓库分发）

| 示例 | 路径 | 说明 |
|---|---|---|
| Skill 示例 | `example/skills/example.md` | frontmatter + 正文 + 2 个声明式工具完整形态 |
| MCP 服务器示例 | `example/mcp/echo-mcp-server.sh` | 最小可运行 MCP 服务器（见 §2.2） |
| 插件示例（hook） | `example/plugins/log-pruner/` | `plugin.json` + `on_tool_result` 钩子（超 1000 字符结果头 500 + 尾 500 截断，事件经 `CJH_HOOK_DATA` 环境变量 JSON 传递） |
| 插件示例（信任链） | `example/plugins/signed-demo/` | **SM2 国密签名插件**：`checksum`（SHA256）+ `publisher` + `pubkey` + `signature` 四字段，`require_signature: true` 时加载前验签 |
| 离线验证 | `--mock`（`src/verify.cj`） | 无 API key 完整跑通"用户输入 → Agent 循环 → 工具调用 → 结果回显" |
| 测试语料 | `src/tests/`（325 用例）+ `scripts/tui_pty_test.py`（49 断言） | 含真实事故数据的回归用例（锁泄漏停摆、UTF-8 切片炸协程、看门狗误杀前思考期等），可作为仓颉并发/终端开发的教学语料 |

### 插件信任链（V3，`src/tools/plugin.cj` 加载时验签 + `cjutil` SM2 原语）

面向生态分发的安全机制，**仓颉 `stdx.crypto` 原生 SM2**：

- **Step 1**：SHA256 checksum 完整性（防篡改）
- **Step 2**：SM2 签名验签（防伪造发布者）——`plugin.json` 三字段（`pubkey`/`checksum`/`signature`）齐全才验签，SM2 原语在 `cjutil`（`libs/cjutil/src/sm2.cj`），验签逻辑内联在 `plugin.cj` 加载路径
- **Step 3**：`require_signature` 配置开关（严格模式拒绝未签名插件）
- 其他仓颉生态（插件/模型/语料分发）可整体借鉴这套"checksum + 签名 + 配置开关"三段式信任模型。

---

## 七、可复用 AI 基础设施库（libs/，生态贡献主体）

5 个**零业务耦合**的独立仓颉包，纯 `std.*`/`stdx.*` FFI 自实现，复制即用，规划发布为独立 cjpm 包：

| 库 | 行数级 | 职责 | 关键可复用能力 |
|---|---|---|---|
| **cjterm** | ~2500 | 终端 UI 库 | ANSI 转义（含 `NO_COLOR`）、差分渲染引擎、`OutputView` 增量行缓存、termios/Win32 **跨平台终端层**、10 套主题（`Palette` 字段化 + `apply()` 写回）、`padBg` 整行背景卡片、Markdown 渲染器 |
| **cjllm** | ~1500 | LLM 协议库 | OpenAI/Anthropic/Ollama 三协议 SSE 流式、**预算竞速中断** `runWithBudget`（spawn + Future 轮询 + cancelChecker，connect/request 全窗口可中断）、**keep-alive 连接复用池**、`HttpStreamClient`、TokenUsage 归一、Mock |
| **cjcfg** | ~1000 | 配置库 | settings/auth 双文件、环境变量覆盖、**Capability 三域模型**（工具权限分级）、会话树持久化、`McpServerConfig` |
| **cjutil** | ~800 | 工具库 | **UTF-8 安全解码**（`safeFromUtf8`/跨块 pending 字节）、字节安全截断 `truncateUtf8`、SHA256/SM2、**截断 JSON 修复** `repairTruncatedJson`（max_tokens 截断容错）、BM25、SSRF 防护 |
| **cjlog** | ~300 | 异步日志库 | 级别控制、双文件落盘、异常堆栈提取、真实 sleep 节流 |

**对仓颉生态的独特价值**（不是"又一个 X 库"）：
1. **仓颉终端 UI 的完整参考实现**——仓颉目前缺乏成熟 TUI 库，cjterm 覆盖了差分渲染/原始模式/跨平台/主题全链路；
2. **仓颉 LLM 应用的传输层基建**——预算竞速与 keep-alive 复用是流式 LLM 客户端的刚需原语，仓颉生态内目前没有现成实现；
3. **UTF-8 字节流处理的标准答案**——`safeFromUtf8` 系列解决了"逐字节 `String(Rune(byte))` 必乱码"这一类高频 bug。

---

## 八、语料：仓颉实战踩坑沉淀

其他仓颉开发者最稀缺的不是代码而是**踩坑经验**，cjh 已把 30+ 个真实坑结构化成语料（`docs/开发文档与踩坑记录.md` §3.1–§3.19 + AGENTS.md 速查），节选高频项：

- **仓颉协程/锁**：`Mutex.lock()` 必须 `try/finally` 守护，裸 lock 在临界区抛异常即锁泄漏 → "无可运行协程" stop 路径（区别于忙等饿死，gdb 特征：主线程 `CJ_CJThreadMpark`、CPU 0%、全线程 idle）
- **spawn 任务**：未捕获异常会静默杀任务线程并向 stderr 打报告（污染 TUI）——必须用结果载体收住异常
- **UTF-8**：字节流→String 禁止逐字节 `String(Rune(byte))`（中文必坏、ASCII 测试全过，极难发现）；`String[0..N]` 字节切片校验 UTF-8 边界，中文上必炸
- **类型陷阱**：`StringBuilder.append(Byte)` 按十进制整数输出（替换/拼接字节必须整段 String 切片）
- **测试语法坑**：零参 lambda 写 `{ => }`；字符串迭代给 `Byte`（比较用 `120u8`）；块注释内禁 `/*` 序列触发嵌套注释
- **工具链坑**：`Directory.walk` 非递归且回调 `false` 终止整个遍历；`cjpm test` 静态链接下测试框架 double free（脚本自动切动态链接跑）；仓颉 SDK 无 Windows 静态 runtime（`--static` 仅 Linux 生效）
- **网络**：裸 `TcpSocket.connect`（DNS/TCP/TLS）无超时参数，黑洞地址挂死且 abort 空转——必须外包预算竞速

---

## 九、其他开发者快速上手

```bash
# 1. 跑起来（无 API key 离线验证）
cjpm build && ./cjh --mock

# 2. 配置真实模型
#    编辑 ~/.cjh/settings.json（首跑自动生成模板），填 base_url / api_key

# 3. 写一个 Skill（3 步，零代码）
#    复制 example/skills/example.md 到 ~/.cjh/skills/my-skill.md
#    改 frontmatter（name/description/tools）+ 正文指令
#    重启 cjh，模型自动获得该技能与声明式工具

# 4. 接入任意 MCP 服务器
#    settings.json 的 mcp_servers 加一条 {command, args, transport:"stdio"}
#    没有服务器可先跑 example/mcp/echo-mcp-server.sh

# 5. 复用基础设施库
#    复制 libs/cjterm（终端 UI）或 libs/cjllm（LLM 传输层）进你的项目
#    依赖关系单向：cjterm/cjllm ← cjcfg/cjutil/cjlog，按需取子集

# 6. 给 cjh 加插件
#    参照 example/plugins/log-pruner/（hook 插件）
#    或 example/plugins/signed-demo/（SM2 签名插件 + 验签流程）
```
