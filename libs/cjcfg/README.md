# cjcfg · cjh 配置/安全/会话层（内部库）

> **定位：cjh 应用专属配置层，非独立可发布库。** 详见 ../README.md 的分类说明。

## 为什么在 libs/（架构必要）

仓颉 executable 根包（`cjh`）不能被其他包 import，而 `cjh.web`（REST API / WebServer）、`cjh.tui` 等子包都需要 `CjhConfig` 类型——配置层必须在根包外的可导入位置，即 libs/。

## 内容

| 文件 | 内容 | 性质 |
|---|---|---|
| `config.cj` | `CjhConfig`（settings.json 全量配置 + 环境变量覆盖 + 读改写）、`ModelEntry`、`McpServerConfig` | cjh 专属 schema |
| `capability.cj` | 三域安全模型（命令/工具/资源白名单 + 审批） | cjh 安全设计 |
| `session.cj` | 树形会话管理 | cjh 会话设计 |
| `workspace.cj` | `Workspace` + `WorkspaceManager`（最近访问排序 + 持久化） | 通用性中等，暂留 cjh |

## 通用能力已剥离

| 能力 | 去向 |
|---|---|
| `EnvFfi`（getenv / chdir / 跨平台 homeDir） | **cjutil**（通用 FFI 工具） |
| 分层配置机制（默认 > 文件 > env + 保留未知 + 模板） | **cjconfig**（通用配置库） |

## 依赖

`cjllm`（ModelEntry 类型）+ `cjutil`（EnvFfi）+ 官方 stdx（encoding.json）

## 测试

库内单测：`cjpm test`（capability/workspace 等）；cjh 全量经 `scripts/test.sh`。
