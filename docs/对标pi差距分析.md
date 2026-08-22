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
| 会话持久化 | **树形**（`/tree` 分支、任意回退） | 线性 JSON 历史（`--list`/`--resume`） | **缺分支树** |
| 会话分享 | `/export` HTML、`/share` gist URL | ❌ | 缺失 |
| **Compaction** | 接近上限自动摘要，可定制 | ❌ | **缺失** |
| **AGENTS.md** | 启动加载项目指令（多级目录） | ❌（仅全局 systemPrompt） | **缺失** |
| **SYSTEM.md** | 每项目覆盖系统提示 | ❌ | 缺失 |
| **Skills** | 按需加载能力包（不破缓存） | ❌（v2 规划 V2b） | 未实现 |
| **Prompt templates** | `/name` 展开 Markdown | ❌ | 缺失 |
| **动态上下文** | 扩展注入/过滤/RAG/长期记忆 | ❌（v2 规划 V2c） | 未实现 |
| **扩展系统** | TS 扩展 + 50+ 示例 + packages | ❌（v2 规划 V2b） | 未实现 |
| 子代理/计划模式 | 扩展实现（非内置） | ❌ | 缺失 |
| **权限/审批** | 明确**不内置**（靠容器/扩展） | ✅ **内置三域审批链**（V2a） | **cjh 领先** |
| 工具集 | bash/read/write/grep 等 | ✅ 5 工具 | 对齐 |
| **Steer/Follow-up** | Enter 转向、Alt+Enter 排队 | ❌（agent 运行中无交互） | **缺失** |
| Provider | **15+**（OpenAI/Anthropic/Google/Ollama/OpenRouter…） | 2 个（OpenAI 兼容 + Anthropic） | **差距大** |
| 本地模型 | Ollama 等 | ❌ | 缺失 |
| 四种模式 | 交互 / print-JSON / RPC / SDK | TUI + CLI 两种 | **缺 RPC/SDK** |
| 主题 | themes 可定制 | ❌ | 缺失 |
| 自修改 | `/reload` 自我定制 | ❌ | 缺失 |
| 分发 | npm 包（需 Node/Bun） | **单二进制零依赖** | **cjh 领先** |

## 三、最该补的差距（按价值排序）

1. **上下文工程**（Compaction + AGENTS.md/SYSTEM.md + Skills）—— pi 的核心卖点。
   没有它，长会话靠手动 `--resume`，上下文管理原始。对应 v2 路线图 **V2c 记忆分层**。
2. **树形会话** —— 目前只存线性历史，无法"回退到任意一轮重新分支"。v2 规划**未覆盖**，是新差距。
3. **Provider 生态** —— 只有 2 家，无本地模型（Ollama）无聚合网关。对应 **V3b 协议深化**。
4. **扩展/插件系统** —— pi 靠它实现一切（子代理/沙箱/MCP）；cjh 的 V2b 只规划了插件形态，
   扩展点（事件/快捷键/UI 钩子）设计未定。
5. **四种模式** —— `--mode json`（脚本用）/ RPC（集成用）对"agent 作为基础设施"很关键。

## 四、cjh 的差异化优势（不用对齐）

- **单二进制零依赖**：pi 要装 Node/Bun + npm 依赖树，cjh `./main` 直接跑（v2"分发"护城河）
- **内置最小权限**：pi 明确"无权限弹窗"，靠容器自担；cjh 把三域安全 + 审批链内置了——
  方向相反但更符合"事前最小权限"
- **鸿蒙原生位**：pi 永远到不了

## 五、落地顺序（已确认）

```
1. V2c 记忆分层（Compaction/AGENTS.md）   ← 上下文工程，pi 最核心
2. V2b 插件系统（Skills/扩展点）          ← 生态入口
3. 树形会话 + --mode json                ← 低成本高感知
4. V3b Provider 扩展（Ollama 本地模型）   ← 解锁离线场景（后续）
```

## 六、相关文档

- docs/进度记录.md — 已完成里程碑与当前 todo
- docs/方案与架构设计-v2.md — 三域安全/插件/记忆分层/IM 网关架构规划
- docs/模块规划.md — 可复用库拆分路线
