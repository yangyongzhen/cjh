
如果你受够了「AI 改错行」和「上下文里没有 IDE 能力」，omp 是当前终端编码 Agent 里最值得一试的那个——Hashline 哈希锚点编辑把改错文件变成小概率事件，LSP/调试器/Python+JS 双内核/并行子 Agent 全套内置且互相咬合，8 万行 Rust 让它在 macOS/Linux/Windows 上行为一致。它不是 Claude Code 的平替，而是技术设计更激进的「下一代」：代价是学习曲线和折腾成本。愿意投入的开发者，它不会让你失望；犹豫的人，先读完这篇再决定。
————————————————

原文链接：https://blog.csdn.net/qq8864/article/details/163777022

一个有趣的彩蛋：DeepSeek Harness（DSH） 的 LLM 层依赖 @earendil-works/pi-ai，而 omp 是 Pi 生态的旗舰应用——也就是说 omp 和 DSH 共享底层 LLM 运行时（都是 can1357 的 pi-ai 架构），但 DSH 走了"事件溯源 + 服务化插件 + Web GUI"的产品路线，omp 走了"终端单机全能 IDE"路线。二者更像是"兄弟项目"而非竞品。


## 为什么值得关注：它解决的是真问题

传统 Coding Agent 的痛点，omp 几乎逐个给了解法：

| 痛点 | 传统方案 | omp 的解法 |
| --- | --- | --- |
| 编辑频繁失败、重试烧 Token | str_replace 重打旧内容 | **Hashline**：内容哈希锚点，一次命中 |
| 读文件浪费上下文 | 全文 dump | **结构化摘要**：Tree-sitter 提取符号，按需展开 |
| Agent 对代码库的理解靠猜 | 无 | **LSP 14 种操作**：重命名、跳转、诊断走协议 |
| 排查 bug 全靠 print 调试 | 无 | **DAP 调试器**：lldb / dlv / debugpy |
| 数据分析弱 | 单一 Python 沙箱 | **Python + Bun 双持久内核**，可回调 Agent 工具 |
| 大任务串行慢 | 无 | **并行子 Agent**：隔离工作区、类型化返回 |
| 模型不守规矩 | 全靠 prompt 唠叨 | **流规则**：正则命中 → 中断流 → 注入规则 → 重试 |
| 每次会话失忆 | 无 | **Hindsight 记忆银行**（项目级） |
| 搜索慢、依赖外部二进制 | shell 调 rg | **进程内 ripgrep / glob / bash** |

### Hashline：技术含量最高的编辑机制

多数 Agent 用 `str_replace`（模型输出「旧内容 + 新内容」），问题在于：空白/引号错一个就拒，文件被改过锚点就失效，于是进入「拒绝 → 重试 → 拒绝」的 Token 燃烧循环。

omp 让模型**用内容哈希标识要改的行**，而不是重新打出那些行：

```
@@{a3f2}
-  const result = compute(x)
+  const result = compute(x, options)
```

`{a3f2}` 是目标行内容的哈希前缀。文件变了导致哈希对不上，patch 会被**拒绝而不是打错地方**。基准数据（官方实测，同权重同 Prompt）：

- **Grok Code Fast 1**：编辑成功率 6.7% → 68.3%（10 倍提升）
- **Gemini 3 Flash**：比 str_replace 高 5 个百分点，超过 Google 自己对该格式的最佳实现
- **Grok 4 Fast**：输出 Token 减少 61%（重试循环消失）
- **MiniMax**：通过率提升 2.1 倍


更高层还有 `ast_edit`（ast-grep 结构化重写，先出 proposed 预览卡片、Agent 写一行理由后 `xd://resolve` 才落盘，原子操作）和 `ast_grep`（50+ 语言 Tree-sitter 结构化查询）。

### read：统一读取接口，省一半 Token

`read` 不只是读文件——**返回的是 Tree-sitter 结构化摘要**（函数名、类名、重要注释），需要细节时 Agent 再调用 `read` 展开具体行段。而且**所有东西都是路径**：

```
read src/auth/login.ts            # 文件 → 结构化摘要
read src/                         # 目录 → 树形概览
read data/app.db                  # SQLite → 表/行
read https://arxiv.org/pdf/…      # 论文 PDF → 结构化 Markdown
read pr://can1357/oh-my-pi/1428   # GitHub PR 就是路径
read issue://can1357/oh-my-pi/142 # Issue 也是路径
```

「GitHub 只是另一个文件系统」——不用学一堆 `gh_issue_view` 之类的专用工具参数，一个接口走天下。

### 原生 Rust：搜索、shell、高亮全部进程内

其他 Agent shell 出去调 rg/grep/find/bash，每次都是 fork-exec 往返；omp 把真实实现**链接进进程**：ripgrep、glob、find 进程内；`bash` 是内嵌的 brush shell（持久会话，跨调用保留环境变量和工作目录），58+ 个命令行工具（ls、sed、sort、xargs、jq…）移植进 builtins crate。同一个二进制原生跑 macOS/Linux/Windows，不需要 WSL 桥。

### LSP 与 DAP：IDE 知道的，Agent 都知道

**14 个 LSP 操作**：diagnostics、hover、definition、references、rename、code_action、completion、signature_help、document_symbols、workspace_symbols、format、range_format、implementation、type_definition。重命名走 `workspace/willRenameFiles`，re-export、barrel 文件、别名导入全部同步更新——不是文本替换。

**28 个 DAP 操作**：C/C++/Rust 用 lldb-dap，Go 用 dlv，Python 用 debugpy，Node 用内置 inspector。C 程序段错误？attach 调试器、看调用栈、读帧、`debug.evaluate("*ptr")`——不用再满代码撒 print。

### eval：Python + JavaScript 双持久内核

大多数 Agent 只给一个 Python 沙箱。omp 跑**两个持久内核**，且任一内核都能回调 Agent 自己的工具：

```python
# Python 内核里调用 Agent 的 read 工具
df = pd.read_csv(tool.read("data/sales.csv"))
print(df.describe())
```

```javascript
// 同一个 eval 会话切到 Bun 内核
const top = tool.read("data/sales.csv").split("\n").slice(1)
  .map(l => l.split(",")).sort((a, b) => +b[2] - +a[2]).slice(0, 5);
console.table(top);
```

两个内核共享 prelude，Python 处理数据、JS 画图，全程一个连续会话。

### 子 Agent：并行、隔离、类型化返回

`task` 把任务拆给并行子 Agent：**平台原生文件系统快照隔离工作区**（macOS APFS clone、Linux reflink/overlayfs、Windows projfs），互不干扰、无合并冲突；每个子 Agent 返回 **schema 校验过的结构化对象**，父 Agent 用路径语法直接取字段：

```
read agent://<subagent-id>/findings.0.path
```

子 Agent 之间还能通过 IRC 短消息协调分工。`Alt+A` 打开 Agent Hub 看每个子 Agent 的实时状态、活体转录、成本，还能中途发消息或杀掉卡住的 worker。

### 流规则：模型不听话的实时纠正

传统做法把所有规范塞进 System Prompt，每次对话付全量 Token，模型还可能无视。omp 的规则是**睡着的**，直到触发：

1. 正则监听模型的流式输出
2. 命中即**中断当前流**（mid-token 级别）
3. 把规则作为系统提醒注入上下文
4. 从同一位置重新生成
5. 注入的规则在上下文压缩后依然存活

例如「禁止在 Rust 生产代码用 `Box::leak`」，模型一旦写到就触发纠正为 `Arc<str>`。用 `/omfg` 用自然语言生成规则：

```
/omfg 不要在任何地方用 any 类型，要求用具体的类型定义或 unknown
```

### Hindsight：项目级跨会话记忆

Agent 运行中主动用 `retain` 写入记忆、`recall` 检索、`reflect` 综合；每次会话结束自动压缩成「心智模型」，下次会话第一轮就加载。**项目级作用域**——A 项目学到的东西不泄漏到 B 项目。用一段时间后，omp 自己就知道：项目用什么技术栈、模块怎么分工、哪些文件是「地雷区」。

### 模型路由：60+ 提供商、10 个角色

用**角色**而非模型名调度：「对的任务用对的模型」。`default` 日常、`smol` 廉价探索、`slow` 深度推理、`plan` 计划模式，另有 vision/designer/task/advisor/commit/tiny。启动时 `--smol` / `--slow` / `--plan` 覆盖，会话中 `/model` 或 `Ctrl+P` 切换。

支持 OAuth 一键登录（Anthropic、Codex、Gemini、Perplexity、Cursor、Copilot…）、Coding Plan 订阅路由、API Key、本地模型（Ollama/LM Studio/vLLM），还能自定义任意 OpenAI 兼容提供商、配 fallback 链（429 自动切换）、路径级模型绑定、多 Key 轮转。

### 其他值得说的

- **/collab**：把会话放上中继，甩个链接+二维码，队友浏览器就能围观/协作，密钥不出本机
- **/commit**：读整个工作树，把不相关改动拆成按依赖排序的原子 commit，循环依赖直接拒绝
- **/review**：专用 reviewer 子 Agent 并行扫描，问题按 P0-P3 分级+置信度评分
- **配置继承**：自动读取 `.cursor/rules/*.mdc`、`CLAUDE.md`、`.clinerules`、`AGENTS.md`、Copilot applyTo 等 8 种现有格式，零迁移
- **ACP/SDK/RPC**：`omp acp` 接入 Zed；Node SDK 内嵌会话；`--mode rpc` stdio 驱动
- **插件**：TypeScript 模块、与内置工具同一套 API、热重载

## 与主流工具对比

| 维度 | Claude Code / 同类 | omp |
| --- | --- | --- |
| 编辑格式 | str_replace（易错） | Hashline（内容哈希锚点） |
| 文件读取 | 全文 dump | 结构化摘要 + 按需展开 |
| LSP | 无或有限 | 完整 14 操作 |
| 调试器 | 无 | 完整 DAP（lldb/dlv/debugpy） |
| 代码执行 | Python 沙箱 | 持久 Python + Bun 双内核 |
| 子 Agent | 无或有限 | 并行 + 隔离 + 类型化返回 |
| 搜索 | shell 调 ripgrep | 进程内 ripgrep，零 fork/exec |
| 行为纠正 | 靠 prompt | 流规则：中断注入重试 |
| 跨会话记忆 | 无 | Hindsight（项目级） |
| 技术栈 | 纯 JS/Python | ~8 万行 Rust 核心 + TypeScript |
?
?
一句话定位
Oh My Pi（命令行简称 omp）是一个终端优先的开源 AI 编程 Agent：不依赖 IDE、全屏 TUI 运行，内置 31 个工具、完整 LSP/DAP 集成、Python+JS 双执行内核、并行子 Agent、跨会话记忆，底层是约 8 万行 Rust 原生实现——搜索、shell、AST、高亮全部进程内完成，零 fork/exec。
它由 Can B?lük fork 自 Mario Zechner 的 Pi，在 GitHub 上已有 24.8k+ stars，MIT 开源。核心理念一句话：工具不应该只是「连上去」，而要被打磨到极致——每个工具都经过基准测试调优，编辑命中率、搜索速度、LSP 集成力求同类最优。


Oh My Pi（简称omp）作为终端优先的开源AI编程Agent，之所以被称为终端里最能打的AI编程Agent，核心在于它没有停留在"把工具简单对接起来"的表层方案，而是从开发者日常编码的真实痛点出发，把每一项能力都打磨到同类工具的极致水平，它解决了传统Coding Agent长期没能处理好的8个核心真问题：

1. 彻底解决编辑频繁失败、重试烧Token的痛点
传统Agent普遍使用str_replace方案，需要模型完整重打旧内容，只要空白、引号出现一点偏差就会编辑失败，容易进入反复重试的Token燃烧死循环。omp独创的Hashline内容哈希锚点机制，让模型用目标行的内容哈希前缀来标识要修改的位置，不需要重打整行内容，官方实测在Grok Code Fast 1上编辑成功率从6.7%暴涨到68.3%，实现了10倍提升，同时Grok 4 Fast的输出Token直接减少61%，从根源上消除了无效重试循环。

2. 告别读文件浪费上下文的问题
传统Agent读取文件是直接全文dump进上下文，非常占用宝贵的上下文窗口空间。omp会返回基于Tree-sitter提取的结构化摘要，仅保留函数名、类名、重要注释等核心符号信息，等Agent需要查看具体细节时再按需展开对应行段，能直接节省一半的上下文Token占用。

3. 让Agent真正看懂代码库，不再靠猜理解项目
绝大多数传统Coding Agent没有对接LSP能力，完全靠文本猜代码结构。omp原生支持14种LSP操作，重命名、定义跳转、代码诊断等操作全部走标准LSP协议完成，哪怕是re-export、别名导入这类复杂场景也能同步正确更新，不再是简单粗暴的文本替换，实现了IDE级别的代码理解能力。

4. 摆脱排查bug全靠print调试的低效模式
传统Agent没有集成调试能力，排查问题只能靠让用户修改代码加打印信息，调试效率极低。omp内置完整的28项DAP调试操作，不同语言自动适配对应调试器：C/C++用lldb-dap，Go用dlv，Python用debugpy，Node用内置inspector，遇到程序段错误可以直接挂载调试器、查看调用栈、读取栈帧变量、动态评估表达式，完全不用手动在代码里撒print语句。

5. 打破单一沙箱的数据分析能力局限
普通Agent往往只提供单一Python沙箱，处理多语言混合数据分析场景非常掣肘。omp同时提供Python和Bun两个持久化执行内核，并且任意一个内核都能回调Agent自身的工具，比如Python内核可以直接调用read工具读取CSV文件处理数据，JS内核可以直接读取同一份数据完成排序可视化，两个内核共享预定义库，全程在一个连续会话里完成数据处理全流程，能力边界大幅拓宽。

6. 大任务不再串行执行，效率直接飙升
传统Agent处理复杂大任务时只能串行一步步执行，耗时很长。omp支持并行子Agent能力，依托平台原生的文件系统快照（macOS APFS clone、Linux reflink/overlayfs、Windows projfs）实现完全隔离的工作区，多个子Agent并行执行任务不会产生冲突，且每个子Agent返回经过Schema校验的结构化对象，父Agent可以直接通过路径语法提取结果，还支持通过Agent Hub实时查看子Agent状态、中途下发指令或终止卡住的任务。

7. 解决模型不守规矩、无视提示约束的问题
传统方案需要把所有行为规范塞进System Prompt，不仅占用大量Token，模型还经常无视这些规则。omp的流规则机制采用"静默监听"模式，在模型流式输出过程中通过正则命中违规内容，直接在token生成中途中断当前流，把规则注入上下文后从断点位置重新生成，注入的规则在上下文压缩后依然可以存活，从根本上杜绝模型输出不符合规范的内容。

8. 告别会话失忆，实现项目级长期记忆
传统Agent每次会话结束就会清空所有上下文，新会话需要重新梳理项目信息，重复做大量无用工作。omp内置Hindsight记忆银行，支持项目级跨会话记忆，Agent运行过程中主动写入、检索、综合项目相关信息，每次会话结束会自动压缩生成项目"心智模型"，下次启动时第一轮就自动加载，使用一段时间后它就会自主记住项目的技术栈、模块分工、需要规避的高风险文件，不用每次重复向它同步项目背景。

除了这8项针对性的痛点解法之外，omp底层是约8万行Rust原生实现，搜索、shell、语法高亮全部在进程内完成，零fork/exec调用，同一个二进制可以在macOS、Linux、Windows上原生运行，不需要WSL桥接，全平台行为完全一致，同时支持60+大模型提供商、自定义OpenAI兼容接口、本地模型运行，还能自动继承8种主流AI编程工具的配置规则做到零迁移，是当前终端AI编码Agent中工程化程度极高的标杆项目。
它在GitHub上已有24.8k+ stars，采用MIT开源协议，由Can B?lük fork自Mario Zechner的Pi项目演进而来，核心理念始终坚持：工具不应该只是"连上去"，而要被打磨到极致，让每一项能力都能给开发者带来实打实的效率提升。