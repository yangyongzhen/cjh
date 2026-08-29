# cjh 项目指令（AGENTS.md）

> 本文件由 agent 自动加载注入 system prompt，人类开发者与 AI 开发者共同遵守。
> 版本：2026-08-29

## 强制门禁：单元测试（CI 红线）

**任何代码变更（新功能、bug 修复、重构、优化）交付前，必须满足：**

1. `./scripts/test.sh` 全绿（238+ 用例，`FAILED: 0`、`ERROR: 0`）——**唯一交付凭证**，禁止以"改动小/时间紧/测试环境问题"为由跳过。脚本自动切动态链接配置跑测试（cjpm.toml 默认静态链接，静态下测试框架 double free 崩溃，见 docs/开发文档与踩坑记录.md §3.10），结束后恢复静态。
   - TUI 改动另加：`python3 scripts/tui_pty_test.py` 全过（14 场景，伪终端驱动真实 TUI：启动/输入/补全/帮助/审批同意与拒绝）。
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

## 工程规范（项目长期约定，独立于任何本地文件）

**1. 代码组织原则**：高内聚、低耦合，满足软件设计六大原则（单一职责、开闭、里氏替换、接口隔离、依赖倒置、迪米特法则）。循环依赖靠**单向依赖 + 回调注入**解决，禁止"移包打补丁"破坏包内聚性——例：`TodoWriteTool` 留在 `cjh.tools` 包，通过函数回调操作 `Agent` 任务列表，避免 `cjh.tools ↔ cjh.agent` 循环。

**2. 可复用工具函数规范**：可复用的工具类函数集中放到独立工具文件里（如 `utf8.cj`），不要分散在多处重复定义；新增工具函数前先检查是否已有类似实现。跨包复用时，底层包（如 `cjllm`）独立实现，上层包（如 `cjh.tools`）可独立实现同逻辑函数，避免反向依赖。

**3. 包独立原则**：能独立的包要独立，不能只为了简单就妥协。通用基础设施（日志、UTF-8 安全解码等）抽取为独立底层包（如 `cjutil`），职责单一，供所有上层包复用，后续可贡献给仓颉生态。禁止把通用工具塞进业务包（如把 `Log` 放进 `cjcfg` 配置包）——违反单一职责，也阻碍复用。

**4. 设计评审标准（借力而非排斥）**：主流 agent 的成熟设计（插件生态、MCP、审批流、记忆管理等）应当借鉴、取长补短。评审关键不是"别人有没有做过"，而是：**借鉴之后，仓颉是否带来增量价值**。

**5. 版本号规则**：重大更新递增中间位（v1.2.0→v1.3.0），小更新递增最后位（v1.2.0→v1.2.1）。发版时同步更新 `cjpm.toml` version + `libs/cjterm/src/logo.cj` Logo.VERSION + 标题栏注释，打 tag 并推送。

**6. 关键技术经验（已踩坑）**：
- `Directory.walk` **非递归**（只遍历直接子项），回调返回 `false` **终止整个遍历**——需要递归必须显式实现（见 grep/glob）
- 工具结果截断阈值：bash=2000、list_dir=4000、read_file=不截断（按需读取）
- compaction：token 触发用真实 `usage.promptTokens`（`lastPromptTokens`），非字符估算
- LLM 生成 write_file 超长 content 时 tool_call JSON 会被 max_tokens 截断：`repairTruncatedJson` 必须**优先处理"字符串被截断"**（inString==true）——补 `"` 闭合被截断的 content 字符串再补 `}` 闭合 JSON；否则会截断到前一个完整字段、丢弃整个 content
- `StringBuilder.append(Byte)` 按十进制整数输出——替换/拼接字节必须整段 String 切片，禁止逐字节 append

## 交付检查清单

- [ ] `./scripts/test.sh` 全绿（含新增测试）
- [ ] `cjpm build` 通过
- [ ] `--mock` 端到端通过
- [ ] 行为变更同步更新 docs/（进度记录、踩坑记录）
