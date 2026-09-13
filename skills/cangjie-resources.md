---
name: cangjie-resources
description: "仓颉生态资源地图：官网、文档、SDK 下载、中心仓、AtomGit/GitCode 组织与示例、语料与技能仓、OpenHarmony——要查资料、找示例、找工具时先看这里"
---

# 仓颉资源地图

> 链接可用性实测于 2026-09-12。注意 `https://cangjie-lang.cn/api.html` 已失效（HTTP 500），文档入口用下方 `docs`。

## 官方入口

| 用途 | 地址 |
|---|---|
| 官网 | https://cangjie-lang.cn/ |
| 文档（语言 / 标准库 / 工具链） | https://cangjie-lang.cn/docs |
| SDK 下载 | https://cangjie-lang.cn/download |
| 中心仓（包托管；SPA 站点，正文建议走搜索或 API） | https://pkg.cangjie-lang.cn/ |

## 代码、语料与技能仓

| 用途 | 地址 |
|---|---|
| 官方组织 | https://atomgit.com/Cangjie |
| SIG 组织（生态 / 技能项目） | https://atomgit.com/Cangjie-SIG |
| TPC 组织（三方组件） | https://atomgit.com/Cangjie-TPC |
| 官方示例 | https://atomgit.com/Cangjie/Cangjie-Examples |
| 语料库 | https://atomgit.com/Cangjie/CangjieCorpus |
| 技能库（AI Coding，含 cangjie-coding / code-review / build-diagnose） | https://atomgit.com/Cangjie-SIG/CangjieSkills |
| OpenHarmony 适配 | https://gitcode.com/Cangjie/OpenHarmony |
| GitCode 组织 | https://gitcode.com/Cangjie |

其余自动化工具（如 `x2cj`）在 `Cangjie-SIG` 组织下按名称检索即可（`/Cangjie-SIG/x2cj` 实测 404，路径以组织页为准）。

## 查资料的推荐顺序

1. **语言 / 标准库 / 工具链用法** → 先查本地知识层（`~/.cjh/cangjie-ref/`，有 `cangjie_ref` 工具时优先用它），再 `web_fetch` 官网 `docs`；
2. **找示例代码** → Cangjie-Examples、CangjieCorpus；
3. **需要领域技能（知识库 / 审查 / 构建诊断）** → CangjieSkills 的三个技能；
4. **包与依赖** → 中心仓 `pkg.cangjie-lang.cn`。
