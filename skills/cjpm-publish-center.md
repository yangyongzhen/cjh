---
name: cjpm-publish-center
description: "把仓颉包发布到中心仓的准备与自检：cjpm.toml 元数据、版本号规则、README/LICENSE、构建测试前置、发布入口与失败排查"
---

# 发布到中心仓

> 入口：https://pkg.cangjie-lang.cn/　文档：https://cangjie-lang.cn/docs
> 中心仓是 SPA 站点，**具体页面/命令以官网《包管理 / 发布》章节为准**：动手前先查官方指南（本地知识层优先，其次 `web_fetch` 官方 `docs`），不要凭记忆操作；与官网不一致时以官网为准，并把实际生效的做法记进项目文档。

## 一、前置条件

| 项 | 要求 |
|---|---|
| 可构建 | `source <SDK>/envsetup.sh && cjpm build` 通过 |
| 可测试 | `cjpm test` 通过（根包与 `libs/*` 子包分别跑） |
| 元数据 | `cjpm.toml` 的 `[package]` 写全 `name` / `version` / `description`，依赖写进 `[dependencies]` |
| 版本号 | 语义化版本；已发布版本号**不复用**（发布即不可变） |
| 文档 | README 写清用途、安装、最小示例 |
| 许可 | 含 `LICENSE`，与包元数据一致 |
| 依赖可获取 | 依赖能在中心仓解析（本地能构建 ≠ 远端能拉取） |

## 二、元数据要点

`[package]` 至少含 `name` / `version` / `description`，`cjc-version` 与实际 SDK 对齐，`output-type` 取 `executable` 或 `library`；依赖统一放 `[dependencies]`。

## 三、提交前自检

- [ ] `cjpm build` / `cjpm test` 全绿（记录命令与结果）
- [ ] `cjpm.toml` 的 name / version / description 与 README 一致
- [ ] README 安装步骤在干净环境可复现（含 `envsetup.sh` 前置）
- [ ] 包内无构建产物、无本地绝对路径、无 token / 私钥
- [ ] 版本号不在已发布列表中；CHANGELOG / release note 写清本版变化

## 四、失败排查顺序

1. 名称冲突或版本已存在 → 换版本号（或改名）；
2. 元数据缺失 / 格式错误 → 对照第一节逐项核对；
3. 依赖在远端不可解析 → 先发布依赖或固定到可用版本；
4. README 缺安装与最小用例 → 补齐再提；
5. 本地能构建、包内却混入产物或本地路径 → 清理 `.gitignore` 与打包脚本。
