# cjh 对标 pi.dev（pi coding agent）差距分析

> 创建：2026-08-22
> 参考：https://pi.dev/ 官网能力清单（2026-08-22 抓取）+ cjh 进度记录 / v2 架构规划
> 用途：明确 cjh 与 pi 的能力差距与差异化优势，指导后续路线图优先级

## 一、结论摘要

- **cjh 领先项**：单二进制零依赖分发、内置三域安全 + 审批链（pi 明确不内置权限弹窗）、鸿蒙原生位
- **cjh 最大缺口**：pi 的"上下文工程"（Compaction / AGENTS.md / SYSTEM.md / Skills / 动态上下文）
  与"可扩展性"（扩展系统 / packages）两大理念，cjh 基本未对齐
- **已对齐**：交互 TUI（组件化参考 pi-tui 契约）、模型切换、会话持久化、基础工具集

## 二、能力对照表

| 能力 | pi | cjh 现状 | 差距 |
|---|---|---|---|
| 交互 TUI | 完整组件化 | ✅ 组件化（参考 pi-tui 契约） | 对齐 |
| 模型切换 | `/model` + `Ctrl+L`/`Ctrl+P` 收藏 | `/model`（列表+切换） | 缺快捷键 |
| 会话持久化 | **树形**（`/tree` 分支、任意回退） | ✅ 树形（`/tree` 列示、`/fork` 分支、parent 链） | **已对齐** |
| 会话分享 | `/export` HTML、`/share` gist URL | ❌ | 缺失 |
| **Compaction** | 接近上限自动摘要，可定制 | ✅ 自动 Compaction（`compactThreshold`/`compactKeep`）+ `/compact` 手动 | **已对齐** |
| **AGENTS.md** | 启动加载项目指令（多级目录） | ✅ `loadProjectInstructions()` 逐级向上查 AGENTS.md | **已对齐** |
| **SYSTEM.md** | 每项目覆盖系统提示 | ❌ | 缺失 |
| **Skills** | 按需加载能力包（不破缓存） | ✅ 技能即 Markdown（`~/.cjh/skills/<name>.md`），frontmatter 解析，`/skills` 列示 | **已对齐** |
| **Prompt templates** | `/name` 展开 Markdown | ❌ | 缺失 |
| **动态上下文** | 扩展注入/过滤/RAG/长期记忆 | ⚠️ AGENTS.md 注入 ✅ · 长期记忆/检索 ❌ | **部分对齐** |
| **扩展系统** | TS 扩展 + 50+ 示例 + packages | ⚠️ `DeclarativeTool` 声明式工具 ✅ · `plugin.json`/WASM/中心仓 ❌ | **部分对齐** |
| 子代理/计划模式 | 扩展实现（非内置） | ❌ | 缺失 |
| **权限/审批** | 明确**不内置**（靠容器/扩展） | ✅ **内置三域审批链**（V2a） | **cjh 领先** |
| 工具集 | bash/read/write/grep 等 | ✅ 7 工具（bash/read_file/write_file/hashline_edit/grep/list_dir/todo_write） | 对齐 |
| **Steer/Follow-up** | Enter 转向、Alt+Enter 排队 | ✅ 输入队列方案 B（执行期间入队 + 提示） | **已对齐** |
| Provider | **15+**（OpenAI/Anthropic/Google/Ollama/OpenRouter…） | 3 协议（OpenAI 兼容 + Anthropic + Ollama） | **部分对齐** |
| 本地模型 | Ollama 等 | ✅ Ollama provider | **已对齐** |
| 四种模式 | 交互 / print-JSON / RPC / SDK | ⚠️ TUI + `--mode json` 无头模式 ✅ · RPC/SDK ❌ | **部分对齐** |
| 主题 | themes 可定制 | ✅ 6 套主题 + `/theme` picker + 实时预览 | **已对齐** |
| 自修改 | `/reload` 自我定制 | ❌ | 缺失 |
| 分发 | npm 包（需 Node/Bun） | **单二进制零依赖** | **cjh 领先** |

## 三、最该补的差距（按价值排序）

> 更新：2026-08-25，V2c 记忆分层 / 树形会话 / `--mode json` / Ollama 本地模型 **均已完成**。
> 下面的优先级已调整，反映当前真实差距。

1. **V2b 插件系统完整形态**（★★★ 生态核心）—— 技能即 Markdown ✅、`DeclarativeTool` 声明式工具 ✅ 已可用；缺 `plugin.json` 元数据、WASM 工具形态、中心仓发布机制。这是 dsh 的护城河，cjh 必须对齐并超越（编译期类型安全）。
2. **V2d 并发引擎完整形态**（★★★ 速度硬指标）—— read-only `spawn` 并发 ✅ 已可用；缺工具 DAG 依赖分析、Provider 连接预热、性能基线测量。速度是产品体验的一部分。
3. **V3 信任链**（★★★ 与插件并行）—— 签名、校验和、发布者信任列表。供应链安全是 cjh 的差异化卖点，必须与插件生态同步落地。
4. **V3b 协议深化**（★★☆）—— Provider Registry（运行时注册任意兼容端点）、模型能力描述（上下文窗口/工具支持/费用，驱动 agent 自适应）。当前 3 协议（OpenAI 兼容 + Anthropic + Ollama）已覆盖主流场景。
5. **工具结果摘要**（★★☆ 大收益）—— `bash`/`read_file` 超长输出自动摘要后回填消息历史，减少后续轮次 prompt 长度 = 省 token = 省时间。对标 omp 的 `truncateToolResult`。
6. **V2e IM 网关**（★★☆ 远程协同）—— `--mode json` 无头模式 ✅ 已可用；缺 `Channel` 接口、HTTP/Web 渠道、IM 渠道接入（企微/钉钉/Telegram）。
7. **V4 多 agent 编排**（★☆☆ 远期）—— 子 agent 并行（研究/编码/审查分角色），基于仓颉 M:N 线程低成本实现。

## 四、cjh 的差异化优势（不用对齐）

- **单二进制零依赖**：pi 要装 Node/Bun + npm 依赖树，cjh `./main` 直接跑（v2"分发"护城河）
- **内置最小权限**：pi 明确无权限弹窗，靠容器自担；cjh 把三域安全 + 审批链内置了——
  方向相反但更符合事前最小权限
- **鸿蒙原生位**：pi 永远到不了

## 五、落地顺序（已确认，按真实状态调整）

```
已完成 ✅：
  V2a 安全升级（三域 capability + 审批链）
  V2c 记忆分层（Compaction + AGENTS.md 加载）
  树形会话（/tree + /fork + parent 链）
  --mode json 无头模式
  Ollama 本地模型（V3b 部分）
  技能即 Markdown + DeclarativeTool（V2b 部分）
  read-only 工具 spawn 并发（V2d 部分）

下一步 ★★★：
  1. V2b 插件系统完整形态（plugin.json + WASM + 中心仓）
  2. V2d 并发引擎完整形态（DAG 依赖分析 + 预热 + 性能基线）
  3. V3 信任链（签名 + 校验和 + 发布者信任列表）

后续 ★★☆：
  4. 工具结果摘要（省 token 大收益）
  5. V3b 协议深化（Provider Registry + 模型能力描述）
  6. V2e IM 网关（Channel 抽象 + HTTP/Web + IM 渠道）

远期 ★☆☆：
  7. V4 多 agent 编排
```

## 六、相关文档

- docs/进度记录.md — 已完成里程碑与当前 todo
- docs/方案与架构设计-v2.md — 三域安全/插件/记忆分层/IM 网关架构规划
- docs/模块规划.md — 可复用库拆分路线
