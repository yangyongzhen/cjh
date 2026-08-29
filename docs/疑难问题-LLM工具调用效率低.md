# 疑难问题：LLM 工具调用效率低

> **状态**：5.1 短期优化已实施并验证（prompt 已受控在 ~10K，压缩机制修复；剩余瓶颈在模型侧）
> **优先级**：高
> **最后更新**：2026-08-29
> **相关提交**：`61015d7` `b80253b` `950b048` `2032d96` `1e67c67`（第三轮优化在工作区，未提交）

## 一、问题描述

用 cjh 执行"优化 shooter 小游戏"任务时，LLM 花费大量轮次和 token，速度远慢于 AtomCode 完成同类任务。

**用户原话**："跟其他 agent，如 atomcode 做了个对比，发现 cjh 好慢啊，同样的任务处理了半天还没完，还在浪费 token。"

## 二、现状分析

### 2.1 采集方法

在 `Agent.run` 主循环的关键位置加 `Log.info` 日志：

- 轮次开始：iteration、消息数、历史 token
- 轮次完成：耗时、prompt/completion/cached tokens、toolCalls、textLen、truncated/timedOut
- 工具执行：工具名、耗时、结果大小、isError

设置 `CJH_LOG_LEVEL=INFO`，日志写入 `~/.cjh/logs/cjh.log`。

测试命令：

```bash
CJH_LOG_LEVEL=INFO bash -c \
  'echo "优化 /root/test/cj/cjh/target/release/bin/shooter/index.html 这个小游戏，提升画面效果和游戏体验" \
  | timeout 180 ./target/release/bin/main'
```

### 2.2 第一次采集（修复前）

采集到 90 行日志，28 轮调用，关键数据：

| 轮次 | 耗时 | prompt | completion | 工具 | 问题 |
|------|------|--------|------------|------|------|
| 1 | 1941ms | 3631 | 74 | read_file | 正常读文件 |
| 2-12 | 2-5s 各轮 | 3K→92K | 91-398 | read_file/bash | 逐轮读文件，历史累积 |
| 13 | **21674ms** | 10178 | 3381 | write_file | completion 突增，写大段 HTML |
| 14-19 | 11-22s 各轮 | 13K→25K | 101-2535 | append_file | 逐段追加，每轮 1 个工具 |
| 20-28 | 3-5s 各轮 | 27K→44K | 145-270 | bash/read_file | prompt 持续膨胀 |

**三个根因**：

1. **历史消息从不压缩**：`compactThreshold=0`（禁用），prompt 从 3K 涨到 44K，后期每轮 LLM 调用处理 44K token，耗时 5-22 秒。
2. **"Large file write strategy"让 LLM 过度拆分写入**：系统提示词引导"骨架 + 多段 append_file"，写一个 162 行 HTML 要 10+ 轮 append_file。
3. **每轮只调 1 个工具**：28 轮里每轮 toolCalls=1，AtomCode 一轮调多个工具并行。

### 2.3 已实施的修复

| 修复 | 提交 | 内容 |
|------|------|------|
| 历史压缩 | `950b048` | `compactThreshold` 默认 0→30，消息超 30 条触发 LLM 摘要压缩 |
| 简化写入策略 | `950b048` | 去掉"Large file write strategy"段，改为"一次 write_file 写完整文件，截断才 append" |
| 引导批量工具调用 | `950b048` | 系统提示词加"Batch tool calls"段 |
| 引导首选工具 | `1e67c67` | bash spec 加"Do NOT use bash to read files"；read_file spec 加"This is the PRIMARY way" |
| 防数字串幻觉 | `2032d96` | write_file/append_file 加 `isAsciiDigitGarbage` 校验 |
| 分段提示文案 | `61015d7` | appendHints 明确"你用了 offset+limit"，不是 read_file 截断 |

### 2.4 第二次采集（修复后）

采集到 75 行日志，23 轮调用，关键数据：

| 轮次 | 耗时 | prompt | completion | 工具 | 问题 |
|------|------|--------|------------|------|------|
| 1 | 1871ms | 3665 | 74 | read_file | 正常读文件 |
| 2 | 3376ms | 4083 | 253 | bash×2(并行) | **批量工具调用生效** |
| 3 | **29436ms** | 4788 | 3187 | bash | **completion 3187 token，LLM 在"思考"** |
| 4-9 | 2-5s 各轮 | 8K→57K | 157-560 | bash | 逐轮 bash，历史累积 |
| 10 | **15365ms** | 11075 | 1481 | bash | completion 1481，又在大段"思考" |
| 13 | 13967ms | 14483 | 1373 | bash×2(并行) | 批量调用，但 completion 高 |
| 21 | **23395ms** | 19068 | 2422 | bash | **耗时 23s，prompt 19K，completion 2422** |
| 22 | 15801ms | 21557 | 1738 | bash | 耗时 15s，prompt 21K |

**改善点**：
- ✅ 批量工具调用生效（第 2、13、17 轮出现 toolCalls=2 并行）
- ✅ 不再用 python3 分段读文件（改用 bash + read_file）

**残留问题**：
- ❌ **compaction 仍未触发**：prompt 涨到 28K，但 `compactThreshold=30` 是**消息条数**阈值，不是 token 阈值；消息条数没到 30，prompt 已爆炸
- ❌ **LLM 单轮"思考"耗时极高**：第 3 轮 29436ms、第 10 轮 15365ms、第 21 轮 23395ms——LLM 在单轮里生成大量 completion token（1481-3187），可能在写大段代码或做复杂推理
- ❌ **仍然每轮 1 个工具居多**：23 轮里只有 3 轮是 toolCalls=2

### 2.5 第三次采集（第三轮优化后）

第三轮优化（工作区未提交）实施内容与发现的新根因：

| # | 修复 | 文件 | 说明 |
|---|------|------|------|
| 1 | **压缩检查移入主循环** | `agent/loop.cj` | **关键 bug**：原 `maybeCompact()` 只在 `run()` 开头调一次，长任务几十轮内从不复查——修复前 48 轮 prompt 涨到 31K token 却一次都没压缩 |
| 2 | **token 触发改用真实 usage** | `agent/loop.cj` | 新增 `compactTokenThreshold`（默认 8000）+ `lastPromptTokens` 记录 provider 返回的真实 `usage.promptTokens`。字符估算 `/4` 严重低估（**实测 7x 偏差**：16 条消息估算 1910，真实 prompt 13099）——漏算了工具 JSON schema（~3.5K）+ 每条消息 JSON 序列化开销 |
| 3 | **compactKeep 12→6** | `loop.cj` / `config.cj` | keep=12 时压缩只删 0-4 条消息，prompt 无法重置（压缩后仍 8-13K 继续爬升）；6 条可重置到 3-4K |
| 4 | **压缩后重置 lastPromptTokens** | `agent/loop.cj` | 防止压缩后基于陈旧测量值（>阈值）下一轮再次压缩造成 churn |
| 5 | **bash 截断 8000→2000** | `agent/loop.cj` | 激进截断（完整结果仍落盘 spill 可回溯） |
| 6 | **系统提示词限制单轮输出** | `cjcfg/config.cj` | "Keep responses short"段：调工具时只写一行说明，禁止长篇推理/代码倾倒 |
| 7 | **工具描述去 skeleton 策略** | `tools/builtin.cj` | **发现残留**：`950b048` 只改了系统提示词，但 write_file/append_file 的**工具描述**仍教"骨架+多段 append_file"，LLM 每轮调用都会看到——这是 10+ 轮 append 行为持续存在的直接原因 |
| 8 | **mock 验证门修复** | `verify.cj` | mock provider 第 1 轮已改并行（read_file+grep=2 调用），`verify.cj` 仍断言 3 次 → 恒失败（基线即失败，与本次无关但顺手修复） |

**修复后基准**（同任务，240s 窗口）：

| 指标 | 修复前（48 轮/300s） | 修复后（15 轮/240s） |
|------|---------------------|---------------------|
| prompt 峰值 | 42.9K（无上限爬升） | **9.4K**（压缩后重置 5.2-7.3K） |
| 压缩触发 | 从不 | 每 ~5 轮，7 次 |
| 批量调用 | 偶发 | 偶发（tc=2/3 出现） |

**仍然存在的瓶颈（模型侧，属 5.2 中期项）**：
- 单轮 completion 仍可达 16K（= max_tokens 上限，71s/轮）——deepseek-v4-flash 生成大段内容时截断 → 触发续写循环
- 压缩摘要 LLM 调用本身耗时 10-100s（模型慢 + 代理慢）

## 三、根因深度分析

### 3.1 历史消息压缩阈值设计错误

`compactThreshold=30` 是**消息条数**阈值。但问题在于：

- 每轮产生 2-3 条消息（assistant + tool_result）
- 消息条数到 30 时，prompt token 已涨到 15-20K
- 压缩触发太晚，前 30 条消息已经占用大量上下文

**正确做法**：压缩应该基于 **prompt token**，而非消息条数。第三轮优化实测发现三个叠加问题：

1. **压缩检查只在 `run()` 开头执行一次**：单次任务跑几十轮，循环内从不复查 → 阈值设得再对也触发不了（48 轮 0 次压缩的直接原因）。修复：移入主循环每轮 LLM 请求前检查。
2. **字符估算 `/4` 严重低估**：实测 16 条消息估算 1910 vs 真实 prompt 13099（7x 偏差）。原因：漏算工具 JSON schema（全量工具注册表 ~3.5K token）+ 每条消息的 JSON 序列化开销。修复：直接采用 provider 返回的真实 `usage.promptTokens`（`lastPromptTokens`），首轮无测量时退回估算。
3. **compactKeep=12 过大**：token 阈值 8000 触发时历史仅 12-16 条，`size-keep` 只删 0-4 条，prompt 无法重置（压缩后 8-13K 继续爬升）。修复：默认 6，压缩后重置到 3-4K。

**结论**：压缩应基于 **prompt token 阈值（真实 usage）**，且检查必须**每轮**执行，keep 必须足够小让压缩真正重置 prompt。

### 3.2 LLM 单轮耗时极高

第 3 轮耗时 29436ms，completion 3187 token。这意味着 LLM 在单轮里生成了 3187 个 token 的输出（可能是大段代码或长篇推理）。

**对比 AtomCode**：AtomCode 的 LLM 单轮 completion 通常 <500 token（只调工具，不长篇大论）。

**可能原因**：
1. glm-5.3-flash 模型本身的生成速度慢（~150 token/s，3187 token 需要 21s）
2. LLM 在生成大量 reasoning_content（思考过程），占用 completion token
3. 系统提示词没有明确限制"每轮只调工具，不要长篇解释"

### 3.3 工具调用批量性不足

虽然加了"Batch tool calls"引导，但 glm-5.3-flash 仍然倾向每轮调 1 个工具。

**对比 AtomCode**：AtomCode 的系统提示词明确说"make all of the independent calls in the same block"，且 Claude/GPT 模型本身更擅长批量调用。

**可能原因**：
1. glm-5.3-flash 模型对"批量工具调用"的支持较弱
2. 系统提示词的引导力度不够，需要更具体的示例

## 四、测试用例

### 4.1 基准测试

```bash
# 设置日志级别，采集完整过程日志
export CJH_LOG_LEVEL=INFO

# 测试命令：优化 shooter 小游戏
echo "优化 /root/test/cj/cjh/target/release/bin/shooter/index.html 这个小游戏，提升画面效果和游戏体验" \
  | timeout 180 ./target/release/bin/main

# 查看日志
cat ~/.cjh/logs/cjh.log
```

### 4.2 关键指标

从 `~/.cjh/logs/cjh.log` 提取：

| 指标 | 提取方法 | 目标值 |
|------|----------|--------|
| 总轮次 | `grep "轮完成" \| wc -l` | <15 |
| 总耗时 | 首轮开始到末轮完成 | <60s |
| 总 prompt token | 末轮的 prompt 累计 | <30K |
| 单轮最大耗时 | `grep "轮完成" \| awk '{print $NF}'` | <10s |
| 批量调用轮次 | `grep "toolCalls 2" \| wc -l` | >5 |

### 4.3 对比测试

同一任务用 AtomCode 跑，记录：
- 总轮次
- 总耗时
- 总 token
- 单轮最大耗时

对比 cjh 的指标，找差距。

## 五、优化方向

### 5.1 短期（低风险，快收益）—— ✅ 已全部实施（2026-08-29，工作区）

1. **压缩阈值改为 token 触发**（已实施，比原方案更进一步）
   - 新增 `compactTokenThreshold`（默认 8000，settings.json 可配）
   - 触发信号用 provider 返回的**真实 `usage.promptTokens`**（`lastPromptTokens`），而非字符估算 `/4`——实测估算 7x 低估（漏算工具 schema + JSON 开销）
   - **压缩检查移入主循环每轮执行**（原实现只在 `run()` 开头调一次，长任务从不触发）
   - `compactKeep` 默认 12→6（否则压缩删不掉足够消息、prompt 无法重置）
   - 压缩成功后重置 `lastPromptTokens=0` 防 churn
   - 文件：`src/agent/loop.cj`

2. **系统提示词限制单轮输出**（已实施）
   - 新增 "## Keep responses short" 段：调工具时最多一行说明，禁止长篇推理/代码倾倒
   - 同时修复 **write_file/append_file 工具描述残留的 skeleton 策略**（`950b048` 只改了系统提示词，工具描述仍在教"骨架+多段 append"，是 10+ 轮 append 的直接原因）
   - 文件：`libs/cjcfg/src/config.cj`、`src/tools/builtin.cj`

3. **工具结果更激进地截断**（已实施）
   - bash 截断 8000→2000 字符（完整结果仍落盘 spill，可 read_file 回溯）
   - 文件：`src/agent/loop.cj` 的 `toolResultMaxChars()`

> 附：`verify.cj` mock 门修复（mock 第 1 轮已并行 read_file+grep=2 调用，断言 3→4）。新增 `src/agent/compact_test.cj` 5 个压缩阈值单测。

### 5.2 中期（需要验证）

4. **模型选择优化**
   - 测试 glm-4.6 等更强模型，看工具调用批量性是否更好
   - 测试不同 temperature 对工具调用行为的影响
   - 文件：`~/.cjh/settings.json` 的 `model` 字段

5. **流式输出的首 token 延迟优化**
   - 第 3 轮 29436ms 里，可能大部分是"首 token 延迟"（LLM 开始生成前的时间）
   - 优化 SSE 解析，减少缓冲，让首 token 更快到达
   - 文件：`libs/cjllm/src/sse.cj`

6. **compaction 压缩质量优化**
   - 当前压缩用 LLM 摘要，可能丢失关键上下文
   - 改为"保留所有 tool_call/tool_result，只压缩 assistant text"
   - 文件：`src/agent/loop.cj` 的 `maybeCompactForce()` 函数

### 5.3 长期（架构级）

7. **prompt 缓存优化**
   - 日志显示 `cached` token 持续增长（3584→28288），但 prompt 也在增长
   - 优化消息历史的 prefix 稳定性，提高缓存命中率
   - 文件：`libs/cjllm/src/openai.cj` 的请求构造

8. **工具调用并行度提升**
   - V2d 并发执行引擎已实现，但 LLM 不产生足够多的并行 tool_calls
   - 考虑在 LLM 不批量调用时，由 cjh 主动分析依赖关系，拆分执行
   - 文件：`src/agent/loop.cj` 的 `buildDependencyGraph()`

9. **模型路由策略**
   - 简单任务用 fast 模型，复杂任务用 capable 模型
   - 减少不必要的 token 消耗
   - 文件：`libs/cjcfg/src/config.cj` 新增 `modelRouting` 配置

## 六、已排除的方向

| 方向 | 排除原因 |
|------|----------|
| cjh 框架本身慢 | 日志显示工具执行耗时 <100ms，框架不是瓶颈 |
| 网络慢 | LLM 调用耗时 2-29s，但 SSE 流式输出正常，不是网络问题 |
| read_file 实现差 | 单元测试通过，输出格式正确，LLM 能用 |
| 工具结果截断导致重读 | read_file 已在白名单（Int64.Max），不截断 |

## 七、下一步行动

1. ~~实施 5.1 的三项短期优化~~ ✅ 已完成（含压缩检查移入循环、真实 usage 触发、keep 调优、工具描述去 skeleton）
2. ~~重新跑基准测试，对比指标~~ ✅ prompt 峰值 42.9K→9.4K，压缩机制生效
3. **实施 5.2 中期优化**（剩余瓶颈全在模型侧）：
   - 优先验证更快的模型（glm-4.6 等）——单轮 completion 16K/max_tokens 截断 + 71s 轮次是当前最大耗时项
   - compaction 摘要调用耗时 10-100s，可考虑摘要用快模型（模型路由，5.3）
4. 持续记录日志，追踪改善趋势

---

> **备注**：本文档随优化进展持续更新。每次修改后记录日期和变更内容。
> **2026-08-29 第三轮优化**：压缩机制修复（检查入循环 + 真实 usage 触发 + keep 6 + 防 churn）、bash 截断 2000、系统提示词限输出、工具描述去 skeleton、mock 门修复、5 个压缩单测。基准：prompt 峰值 42.9K→9.4K，15 轮/240s。剩余瓶颈为模型侧（单轮 16K completion 截断、摘要调用慢）。
