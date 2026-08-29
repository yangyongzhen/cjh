# cjconfig · 仓颉通用分层配置库

**环境变量 > 配置文件 > 默认值**的三层配置读取，声明式字段 + 类型安全访问 + 自动模板 + 保留用户扩展字段。零第三方依赖（仅官方 stdx.json）。

对标 Go viper / Rust config 的轻量版，专为仓颉生态设计。

## 特性

| 特性 | 说明 |
|---|---|
| **声明式字段** | `defineStr/defineInt/defineFloat/defineBool/defineJson` 集中声明：key + 默认值 + 环境变量映射 + 说明 |
| **三层优先级** | 环境变量（实时读取）> 配置文件 > 默认值，免手写覆盖逻辑 |
| **类型安全读取** | `getStr/getInt/getFloat/getBool/getJson`，环境变量自动按字段类型转换（非法值忽略回退） |
| **保留用户扩展** | 读-改-写合并：用户手写的未知字段不被覆盖 |
| **自动模板** | 首次 save 生成带 `_说明` 的 config.json（字段描述自动附带） |
| **跨平台路径** | `~/.<app>/config.json`（Windows USERPROFILE / POSIX HOME 自动识别，路径分隔符编译期选择） |
| **零第三方依赖** | 仅仓颉 std + 官方 stdx.encoding.json |

## 快速开始

```toml
[dependencies]
  cjconfig = { path = "../cjconfig" }   # 或发布后：cjconfig = "0.1.0"
```

```cangjie
import cjconfig.*

main() {
    let cfg = ConfigStore("myapp")            // ~/.myapp/config.json
    // 声明字段：key / 默认值 / 环境变量 / 说明
    cfg.defineStr("model", "gpt-4o-mini", "MYAPP_MODEL", "LLM 模型")
    cfg.defineInt("max_iters", 10, "MYAPP_MAX_ITERS", "最大迭代")
    cfg.defineBool("verbose", false, "MYAPP_VERBOSE", "详细输出")
    cfg.load()

    // 读取：环境变量 > 配置文件 > 默认值
    let model = cfg.getStr("model")          // MYAPP_MODEL 优先
    let iters = cfg.getInt("max_iters")
    if (cfg.getBool("verbose")) { /* ... */ }

    // 修改 + 保存（保留用户手写的其他字段）
    cfg.setStr("model", "deepseek-chat")
    cfg.save()                                // 首次自动生成模板
}
```

## API

### 字段声明

| API | 说明 |
|---|---|
| `defineStr(key, default, envName?, desc?)` | 字符串字段 |
| `defineInt(key, default, envName?, desc?)` | 整数字段 |
| `defineFloat(key, default, envName?, desc?)` | 浮点字段 |
| `defineBool(key, default, envName?, desc?)` | 布尔字段 |
| `defineJson(key, default, envName?, desc?)` | 通用 JSON 字段（数组/对象） |

（envName/desc 省略用 2 参重载；环境变量命名建议 `<APP>_<KEY>`）

### 读写

| API | 说明 |
|---|---|
| `load()` | 加载：默认值 + 配置文件（重复调用幂等） |
| `getStr/getInt/getFloat/getBool/getJson(key)` | 类型安全读取（env > 文件 > 默认） |
| `set/setStr/setInt/setBool(key, value)` | 内存修改 |
| `save()` | 写回（保留未知字段；首次生成模板） |
| `configPath()/configDir()` | 配置路径/目录 |

## 设计要点

- **环境变量实时读取**：get 时查 env，无需重新 load；非法 env 值（如 `max_iters=abc`）自动忽略回退文件/默认
- **模板即默认值**：首次 save 生成的 config.json 含全部字段默认值 + `_说明`，用户可直接编辑
- **跨平台**：Windows 用 USERPROFILE（无 HOME）、路径分隔符 `\`；POSIX 用 HOME、`/`——编译期 `@When[os]` 选择

## 测试

```bash
cjpm test    # 6 用例：默认值/环境变量覆盖/往返持久化/模板生成/保留未知/类型安全
```

## 许可

MIT
