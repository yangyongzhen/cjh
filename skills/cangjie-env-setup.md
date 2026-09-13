---
name: cangjie-env-setup
description: "仓颉工具链环境搭建与日常命令：envsetup.sh 注入 cjpm、build/test/run/clean、SDK 路径与版本、libs 子包独立测试、静态/动态链接差异——遇到 cjpm 不在 PATH、测试崩溃、库包测试不生效时看这篇"
---

# 仓颉环境搭建与工具链

## 环境注入（每个新 shell 都要做一次）

`cjpm` / `cjc` 不在默认 PATH，必须先引入 SDK 的环境脚本（路径随安装位置变化，本机 SDK 在 `/opt/cangjie/cangjie`）：

```bash
source /opt/cangjie/cangjie/envsetup.sh
cjpm -V && cjc -v
```

脚本化流程要把它写在脚本开头（cjh 仓库的 `scripts/test.sh` 就是这么做的）。

## 常用命令

| 目的 | 命令 |
|---|---|
| 构建 | `cjpm build` |
| 跑测试 | `cjpm test` |
| 运行 | `cjpm run`（参数透传：`cjpm run -- <args>`） |
| 清理 | `cjpm clean` |
| 版本 | `cjc -v`、`cjpm -V` |

## 工程结构约定

- `cjpm.toml` 是唯一工程描述：`[package]`（`name` / `version` / …）、`[dependencies]`、`compile-option` 等；
- **根目录 `cjpm test` 不会进入子包测试**：`libs/` 下的库包需单独执行 `cd libs/<lib> && cjpm test`；
- 静态链接与动态链接的构建、测试行为不同：测试框架在静态配置下可能有已知问题，此时改用动态配置跑测试，跑完记得还原工程配置。

## 常见问题速查

| 现象 | 处理 |
|---|---|
| `cjpm: command not found` | 没有 `source envsetup.sh` |
| 测试框架崩溃 / double free | 切动态链接配置后重跑测试 |
| 改了 `libs/*` 但产物行为没变 | 需要 `cjpm build` 重建——旧产物即使时间戳更新也可能仍是旧的 |
| 库包测试"没跑" | 根目录 `cjpm test` 不递归子包，需进子包目录跑 |
