# cjcfg · 仓颉配置系统库

**cjh 的配置/安全/会话基础库**——settings.json 配置、auth 凭据、三域 capability 安全模型、工作区管理、会话持久化。

## 特性

| 特性 | 说明 |
|---|---|
| **分层配置** | settings.json（模型/端点/行为/Web 搜索等全量配置）+ auth.json（API keys，权限 600）+ 环境变量覆盖，读-改-写保留未知字段 |
| **跨平台路径** | Windows USERPROFILE / POSIX HOME 自动识别，平台路径分隔符编译期选择 |
| **三域 capability** | 命令/工具/资源白名单 + 审批链（`Capability`，默认宽松，声明即严格） |
| **工作区管理** | `WorkspaceManager`：多项目注册 + 最近访问排序 + 持久化（workspaces.json） |
| **会话持久化** | 树形会话（`SessionManager`：创建/恢复/分支/历史） |
| **进程 FFI** | `EnvFfi`：环境变量 + 运行时 chdir（切换工作目录） |

## 快速开始

```toml
[dependencies]
  cjcfg = { path = "../cjcfg" }
  cjllm = { path = "../cjllm" }     # cjcfg 依赖（ModelEntry 等）
```

```cangjie
import cjcfg.*

main() {
    // 构造即加载（CJH_CONFIG_DIR 可覆盖配置目录）
    let cfg = CjhConfig()

    // 读写配置
    println("model: ${cfg.model}, baseUrl: ${cfg.baseUrl}")

    // 环境变量 > 文件 > 默认 的优先级由库保证

    // 工作区 CRUD（最近访问排序）
    let ws = WorkspaceManager(cfg.configDir)
    ws.add("/home/user/proj-a", "proj-a")
    ws.save()
    for (w in ws.list()) {
        println("workspace: ${w.name} @ ${w.path}")
    }
}
```

## 模块

| 文件 | 内容 |
|---|---|
| `config.cj` | `CjhConfig` 全量配置 + `ModelEntry` + `McpServerConfig` + 读写/环境变量覆盖 |
| `capability.cj` | 三域安全模型（commands/tools/resources 白名单 + 审批） |
| `env_ffi.cj` | `EnvFfi`：getenv/chdir FFI + 跨平台 homeDir |
| `session.cj` | 树形会话管理 |
| `workspace.cj` | `Workspace` + `WorkspaceManager` |

## 依赖

- 仓颉 std + **官方 stdx**（encoding.json）
- cjllm（ModelEntry 类型）——本系列仓颉库

## 许可

MIT
