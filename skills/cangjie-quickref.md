---
name: cangjie-quickref
description: "仓颉速查（踩坑清单）：字节/字符串转换、append(Byte) 十进制坑、lambda 与命名参数限制、Directory.walk 非递归、Mutex 必须 try/finally、块注释禁嵌套、测试约定"
---

# 仓颉速查（踩坑清单）

## 字节与字符串

- 字节流转 `String` **禁止逐字节** `String(Rune(byte))`：中文必坏（ASCII 测试全过，容易漏），必须整段按 UTF-8 解码；跨块要维护 pending 字节、按字符边界切分。
- 字符串迭代给 `Byte`：`for (b in s)` 与 `s[i]` 都是 `Byte`（=`UInt8`），比较写 `120u8`；字面量写 `0x41u8`。
- `StringBuilder.append(Byte)` 按**十进制整数**输出：拼接字节流必须整段 `String` 切片，不能逐字节 append。

## 语法与类型

| 规则 | 说明 |
|---|---|
| 零参 lambda 写 `{ => }` | 不能写 `{ }` |
| 普通参数按位置传 | 只有 `p!:` 支持命名参数；函数**没有**默认参数 |
| 捕获 `var` 的 lambda 必须**直接调用** | 不能作为参数传给别的函数；先用 `let` 接住不可变快照 |
| 块注释内禁 `/*` 序列 | 如 `**/*` 触发嵌套注释解析错误 |

## 标准库行为

| API | 注意 |
|---|---|
| `Directory.walk` | **非递归**；回调返回 `false` 会**终止整个遍历**——递归须显式实现 |
| `Directory.create` | **不幂等**：目录已存在即抛异常，建临时目录前先清理 |
| `Mutex.lock()` | 必须 `try { … } finally { unlock() }`；裸 lock/unlock 在临界区抛异常即**锁泄漏**（共享锁泄漏会让任务 park：CPU 0%、线程全 idle） |
| `spawn` 内未捕获异常 | 会额外向 stderr 打报告（污染 TUI），用结果载体收住异常 |

## 测试（cjpm test）

- **顶层** `@Test public func`；写在类里报 "not top level"。
- 临时文件放独立目录（如 `/tmp/<项目>_ut_*`）；`Directory.create` 不幂等，共享目录的用例开头要清残留。
- `@Assert(actual, enumValue)` 期望值是枚举时泛型推断失败 → 先 `match` 转 `Bool` 再断言。
