# 移植工具使用指南

本文档详细介绍从 OMP 移植到 cjh 的 4 个工具：`glob`、`edit`、`task`、`ast_grep`。

## glob — 文件名模式匹配

### 功能

递归搜索目录树，返回匹配 glob 模式的文件路径。比 `list_dir` 逐层展开更高效，模型常需"找所有 .ts 文件"场景。

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `pattern` | string | 是 | Glob 模式 |
| `path` | string | 否 | 搜索根目录（默认 cwd） |

### 支持的通配符

- `*` — 匹配除 `/` 外的任意字符（不跨目录）
- `**` — 匹配任意层级目录（跨目录，含 0 层）
- `?` — 匹配单个字符

### 使用示例

```
glob(pattern="**/*.cj", path="src")
```

输出：
```
匹配 11 个文件（模式: **/*.cj）：
src/tools/builtin.cj
src/tools/edit.cj
src/tools/glob.cj
...
```

### 设计细节

- **gitignore 感知**：跳过 `.git`、`node_modules`、`target`、`.next`、`dist`、`build`、`.cache`、`__pycache__`、`.venv` 等常见忽略目录
- **路径规范化**：自动去掉 `./` 前缀和尾部 `/`
- **结果上限**：最多返回 200 个匹配，超出时显示截断提示
- **只读工具**：`isReadOnly()=true`，V2d 并发执行引擎可并发调用

### 错误处理

| 场景 | 错误信息 |
|------|---------|
| 缺少 pattern | "缺少参数: pattern" |
| pattern 为空 | "pattern 不能为空. 示例: '**\/*.ts' 匹配所有 .ts 文件." |
| 基础路径不存在 | "基础路径不存在: ${basePath}" |

---

## edit — str_replace 精确替换

### 功能

在文件中精确查找 `old_string` 并替换为 `new_string`。比 `hashline_edit` 行号锚点更直观，模型出错率更低。OMP 核心编辑工具。

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | string | 是 | 文件路径 |
| `old_string` | string | 是 | 要替换的文本（必须精确匹配，含缩进） |
| `new_string` | string | 是 | 替换后的文本 |
| `replace_all` | bool | 否 | 是否替换所有匹配（默认 false，即要求 old_string 唯一） |

### 使用示例

**单次替换**（old_string 唯一）：
```
edit(path="src/main.cj", old_string="let x = 1", new_string="let x = 2")
```

**批量替换**（多处匹配）：
```
edit(path="config.json",
     old_string="\"debug\": false",
     new_string="\"debug\": true",
     replace_all=true)
```

**多行替换**（old_string 含换行）：
```
edit(path="src/app.cj",
     old_string="func oldName() {\n    return 1\n}",
     new_string="func newName() {\n    return 2\n}")
```

### 安全机制

1. **唯一性校验**：`old_string` 必须在文件中唯一匹配，否则拒绝（防误改多处）
2. **replace_all 模式**：设 `replace_all=true` 时允许匹配多处，全部替换
3. **空值拒绝**：`old_string` 为空时拒绝（避免清空文件）
4. **相同值拒绝**：`old_string == new_string` 时拒绝（无意义操作）
5. **原子写入**：先写临时文件 `.cjh-tmp`，再 `mv` 原子替换，避免写一半崩溃损坏原文件

### 诊断错误信息

当 `old_string` 未匹配时，`edit` 返回**诊断信息**帮助模型定位问题：

| 诊断结果 | 错误信息 |
|---------|---------|
| 首行精确匹配，完整 old_string 不匹配 | "首行精确匹配, 但完整 old_string 不匹配. 可能原因: 多行后续行不匹配 / 换行符不一致" |
| 首行内容匹配但空白不一致 | "首行内容匹配但空白不一致. 可能原因: 缩进不匹配 (tab vs 空格) / 首尾空格不一致" |
| old_string 首行在文件中未找到 | "old_string 首行在文件中未找到. 可能原因: 内容不存在 / 不可见字符 (BOM, 零宽空格)" |

### 与 hashline_edit 的区别

| 特性 | edit | hashline_edit |
|------|------|---------------|
| 定位方式 | `old_string` 精确匹配 | 行号锚点 `@@N` |
| 模型友好度 | 高（直观） | 中（需算行号） |
| 多行支持 | 原生支持 | 需多个锚点 |
| 唯一性校验 | 有（防误改） | 无 |
| 适用场景 | 精确文本替换 | 行级编辑 |

---

## task — 派发子代理执行独立任务

### 功能

创建一个临时的"子 Agent"，用相同的 LLM provider 和工具集，独立执行一个子任务，然后把结果汇报给主 Agent。

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `description` | string | 是 | 3-5 词任务标签 |
| `prompt` | string | 是 | 完整任务指令 |
| `subagent_type` | string | 是 | `explore`（只读）或 `worker`（可写） |

### subagent_type 说明

| 类型 | 能力 | 适用场景 |
|------|------|---------|
| `explore` | 只读：读文件、grep、glob、只读 bash | 调查代码结构、定位 bug、收集信息 |
| `worker` | 可写：所有工具都可用 | 独立实现一个小功能、修一个孤立 bug |

### 使用示例

**只读调查**（explore）：
```
task(description="审查 hashline 工具",
     prompt="读取 src/tools/hashline.cj，检查 spec() 返回的 ToolSpec 描述风格是否与其他工具一致。只汇报发现，不修改文件。",
     subagent_type="explore")
```

**可写任务**（worker）：
```
task(description="修复 glob 路径规范化",
     prompt="src/tools/glob.cj 的 makeRelative 函数不处理 ./ 前缀。请修复：规范化 basePath，去掉 ./ 前缀和尾部 /。",
     subagent_type="worker")
```

**并行多个子任务**：
```
task(description="审查工具 A", prompt="...", subagent_type="explore")
task(description="审查工具 B", prompt="...", subagent_type="explore")
task(description="审查工具 C", prompt="...", subagent_type="explore")
```

### 设计细节

- **上下文隔离**：子代理有独立的 messages 历史，它的工具调用、中间推理不会污染主会话
- **迭代限制**：子代理 max 5 轮迭代，避免失控
- **回调注入解耦**：`TaskTool` 持有 `spawnFn` 回调，由 `entries.cj`（cjh 主包）注入实际实现，避免 `cjh.tools` ↔ `cjh.agent` 循环依赖
- **非只读工具**：`isReadOnly()=false`，子代理可能写文件，V2d 并发执行引擎串行执行

### 错误处理

| 场景 | 错误信息 |
|------|---------|
| 缺少 description/prompt | "缺少参数: description/prompt" |
| subagent_type 无效 | "无效的 subagent_type: '${subagentType}'. 有效值: explore (只读调查) 或 worker (可写, 完成任务). 默认 explore." |
| prompt 为空 | "prompt 不能为空. 请提供完整的子任务指令." |
| description 为空 | "description 不能为空. 请提供 3-5 词的任务标签." |
| 子代理执行异常 | "子代理任务失败: ${e}" |

### 适用 / 不适用场景

✅ **适用**：
- 并行处理多个**独立**子任务（如审查多个模块）
- 只读调查（`explore`）：不想让子任务修改文件
- 隔离执行：子任务的中间状态不该影响主会话

❌ **不适用**：
- 需要主会话上下文的任务（子代理看不到主会话历史）
- 需要用户交互/审批的任务（子代理无审批回调）
- 强依赖顺序的串行任务（直接让主 Agent 做更高效）

---

## ast_grep — AST 结构搜索

### 功能

用 AST（抽象语法树）模式搜索代码，比 `grep` 文本搜索更精准。重构时不可替代。

### 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `pattern` | string | 是 | AST 模式（ast-grep 语法） |
| `lang` | string | 是 | 语言：rust, typescript, python, go, java, c, cangjie 等 |
| `path` | string | 否 | 搜索根目录（默认 cwd） |
| `skip` | int | 否 | 跳过前 N 个匹配（分页用） |

### ast-grep 模式语法

| 语法 | 含义 | 示例 |
|------|------|------|
| `$NAME` | 捕获一个 AST 节点 | `fn $NAME($$$) { $$$ }` |
| `$$$` | 匹配零或多个节点 | `some($$$)` |
| `$_` | 匹配一个节点（不绑定） | `return $_` |

### 使用示例

**搜索所有 Rust 函数定义**：
```
ast_grep(pattern="fn $NAME($$$) { $$$ }", lang="rust", path="src")
```

**搜索所有 Python 函数定义**：
```
ast_grep(pattern="def $NAME($$$): $$$", lang="python", path=".")
```

**搜索所有 TypeScript const 声明**：
```
ast_grep(pattern="const $NAME = $$$", lang="typescript", path="packages")
```

**分页查看（跳过前 10 个）**：
```
ast_grep(pattern="fn $NAME($$$) { $$$ }", lang="rust", path="src", skip=10)
```

### 降级策略

| 场景 | 行为 |
|------|------|
| `sg` 命令存在 | 调 `sg run -p 'pattern' -l lang --json=stream path`，解析 JSON stream 输出 |
| `sg` 命令不存在 | 降级用 `grep -rn` 按字面 pattern 匹配 |
| `grep` 也失败 | 返回 "ast_grep 降级失败" 错误 |

降级时输出包含安装提示：
```
建议安装 ast-grep: https://ast-grep.github.io/
```

### 输出格式

```
ast-grep 匹配 3 处 (pattern=fn $NAME($$$) { $$$ }, lang=rust):
src/main.rs:1:0: fn main() {
    println!("hello");
}
src/lib.rs:5:0: fn add(a: i32, b: i32) -> i32 {
    a + b
}
src/lib.rs:10:0: fn sub(a: i32, b: i32) -> i32 {
    a - b
}
```

### 错误处理

| 场景 | 错误信息 |
|------|---------|
| 缺少 pattern/lang | "缺少参数: pattern/lang" |
| pattern 为空 | "pattern 不能为空. 请提供 AST 模式, 例如 'fn $NAME($$$) { $$$ }'." |
| lang 不支持 | "不支持的 lang: '${lang}'. 支持的语言: rust, typescript/ts, python/py, go, java, c, cpp, cangjie/cj, javascript/js. 如果是其他语言, 可以用 grep 工具做文本搜索." |
| 基础路径不存在 | "基础路径不存在: ${basePath}" |

### 安装 ast-grep

```bash
# macOS
brew install ast-grep

# Linux
cargo install ast-grep
# 或
npm install -g @ast-grep/cli
```

详见：https://ast-grep.github.io/

---

## 工具注册点

4 个移植工具在以下 4 个入口注册：

| 入口 | 文件 | 注册位置 |
|------|------|---------|
| CLI 模式 | `src/entries.cj` | `runCli()` 函数 |
| TUI 模式 | `src/entries.cj` | `runTui()` 函数 |
| Web 模式 | `src/entries.cj` | `runWeb()` 函数 |
| JSON 模式 | `src/entries.cj` | `runJson()` 函数 |

`task` 工具通过回调注入解耦：
- `TaskTool` 持有 `spawnFn: (String, String, String) -> TaskSpawnResult` 回调
- `entries.cj` 的 `spawnSubagent()` 函数实现实际派发逻辑
- 避免 `cjh.tools` ↔ `cjh.agent` 循环依赖

---

## 完整工具清单（移植后）

| 工具 | 来源 | 只读 | 说明 |
|------|------|------|------|
| `bash` | cjh 原有 | 否 | 执行 shell 命令 |
| `read_file` | cjh 原有 | 是 | 读取文件，大文件流式读取 |
| `write_file` | cjh 原有 | 否 | 写入文件（创建/覆盖） |
| `append_file` | cjh 原有 | 否 | 追加写入文件，OpenMode.Append 增量写 |
| `hashline_edit` | cjh 原有 | 否 | 行号锚点 `@@N` + 内容验证编辑 |
| **`edit`** | OMP 移植 | 否 | str_replace 精确替换 |
| `grep` | cjh 原有 | 是 | 目录树递归搜索，gitignore 感知 |
| **`glob`** | OMP 移植 | 是 | 文件名模式匹配，支持 `**` 跨目录 |
| **`ast_grep`** | OMP 移植 | 是 | AST 结构搜索，调 ast-grep CLI（sg），降级 grep |
| `list_dir` | cjh 原有 | 是 | 列出目录树 |
| `todo_write` | cjh 原有 | 否 | LLM 通过工具调用管理任务列表 |
| **`task`** | OMP 移植 | 否 | 派发子代理执行独立任务 |
| `web_search` | cjh 原有 | 是 | 联网搜索，多后端路由 |
| `web_fetch` | cjh 原有 | 是 | 抓取网页，三级降级链 + SSRF 防护 |
