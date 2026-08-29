# cjh 项目指令（AGENTS.md）

> 本文件由 agent 自动加载注入 system prompt，人类开发者与 AI 开发者共同遵守。
> 版本：2026-08-29

## 强制门禁：单元测试（CI 红线）

**任何代码变更（新功能、bug 修复、重构、优化）交付前，必须满足：**

1. `cjpm test` 全绿（152+ 用例，`FAILED: 0`、`ERROR: 0`）——**唯一交付凭证**，禁止以"改动小/时间紧/测试环境问题"为由跳过。
2. **新增行为必须有对应测试**：
   - 新工具/新纯函数 → 至少覆盖主路径 + 错误路径 + 一个边界
   - bug 修复 → 先写复现该 bug 的测试（失败）再修复（转绿），防止回归
   - 工具类测试通过 `execute(args)` 公共 API 断言 `ToolResult`；纯函数直接断言
   - 只读测试放 `src/tests/`（package `cjh.tests`）；**根包 `cjh` 的函数测试必须放 `src/core_funcs_test.cj`**（executable 根包不能被 cjh.tests 导入）
3. `cjpm build` 通过 + `--mock` 端到端通过（工具调用链验证）。
4. 不允许"先交付后补测"——测试与代码同批交付。

## 测试编写规范

- 临时文件一律放 `/tmp/cjh_ut_*`，用 `testTempDir`/`removeTree` 辅助，**每个用例独立目录或先清理**（`Directory.create` 不幂等，对已存在目录抛异常）。
- 用例隔离：共享目录的测试类，每个 `@TestCase` 开头清理上一用例残留。
- 仓颉测试语法坑（已踩，勿重踩）：
  - 零参 lambda 写 `{ => }`；普通参数按位置传（`p!:` 才支持命名参数）；无默认参数
  - 字符串迭代给 `Byte`（比较用 `120u8`）；`text[i]` 也是 Byte；`StringBuilder.append(Byte)` 按**十进制整数**输出（大坑）
  - 块注释内禁写 `/*` 序列（如 `**/*`）触发嵌套注释解析
  - `Byte = UInt8` 别名，字面量写 `0x41u8`
- 工具类通过 `execute` 断言 observable 契约（isError/content），不测私有实现。

## 工程规范（对齐 memory.md）

- 循环依赖靠单向依赖 + 回调注入解决；可复用函数集中放独立工具文件（如 utf8.cj）
- `Directory.walk` **非递归**（只遍历直接子项），回调返回 `false` **终止整个遍历**——需要递归必须显式实现（见 grep/glob）
- 工具结果截断阈值：bash=2000、list_dir=4000、read_file=不截断（按需读取）
- compaction：token 触发用真实 `usage.promptTokens`（`lastPromptTokens`），非字符估算

## 交付检查清单

- [ ] `cjpm test` 全绿（含新增测试）
- [ ] `cjpm build` 通过
- [ ] `--mock` 端到端通过
- [ ] 行为变更同步更新 docs/（进度记录、踩坑记录）
