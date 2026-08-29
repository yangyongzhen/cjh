# cjlog · 仓颉原生日志库

**零依赖的异步日志库**——纯仓颉 std 实现，无任何第三方依赖。

级别化日志 + 异步队列落盘（不阻塞业务线程）+ 异常堆栈提取 + 环境变量控制。

## 特性

| 特性 | 说明 |
|---|---|
| **零依赖** | 仅仓颉 std（time/sync/fs/env/collection），`cjpm.toml` dependencies 为空 |
| **异步落盘** | 日志入队后后台线程批量写文件，业务线程零阻塞 |
| **分级控制** | FATAL/ERROR/WARN/INFO/DEBUG，`CJH_LOG_LEVEL` 环境变量控制写入级别 |
| **双文件** | 普通日志 `cjh.log` + 错误日志 `error.log`（ERROR/FATAL 单独落盘） |
| **异常友好** | `error(msg, e)` 重载自动提取堆栈（fileName:line @ function 格式，截断 20 帧） |

## 快速开始

```toml
[dependencies]
  cjlog = { path = "../cjlog" }   # 或发布后：cjlog = "0.1.0"
```

```cangjie
import cjlog.*

func main() {
    Log.info("cjh 启动完成")
    Log.warn("配置未设置，使用默认值")
    Log.error("操作失败", Exception("磁盘已满"))
    try {
        // ...
    } catch (e: Exception) {
        Log.fatal("不可恢复错误", e)
    }
    Log.shutdown()   // 刷新队列
}
```

## API

| API | 说明 |
|---|---|
| `Log.info/warn/error/fatal(msg)` | 级别日志（FATAL 最高） |
| `Log.info/warn/error/fatal(msg, e)` | 带异常的级别日志（自动提取堆栈） |
| `Log.debug(msg)` | DEBUG 级（`CJH_LOG_LEVEL=DEBUG` 时写入） |
| `Log.ensureInit()` | 初始化日志系统（首次调用自动） |
| `Log.shutdown()` | 停止后台线程并刷新队列（程序退出前调用） |

## 配置

- `CJH_LOG_LEVEL`：写入级别（`DEBUG` 启用 debug；默认 INFO 及以上）
- 日志文件：`cjh.log` / `error.log`（当前工作目录或配置目录，随宿主应用决定）

## 许可

MIT
