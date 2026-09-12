# CHANGELOG

cjh 版本变更记录。依据 git tag 史 + 提交史整理；版本号规则：重大更新递增中间位（v1.2.0→v1.3.0），小更新递增最后位（v1.3.14→v1.3.15）。

> 注：v1.0.0 / v1.1.0（首个 tag 前）/ v1.2.2 / v1.3.0 / v1.3.5 等版本未打 tag，日期与内容按提交史还原，以「无 tag」标注。

## [v1.3.26] - 2026-09-12

### Fixed
- **大写字母被当成 Ctrl 组合 → 文本乱码 + 凭空回车/换行**（`libs/cjterm/src/term_windows.cj`）：控制键状态位掩码常量写错——`RIGHT_ALT_PRESSED` 误写 `0x4`、`RIGHT_CTRL_PRESSED` 误写 `0x10`（`0x10` 实为 `SHIFT_PRESSED`），旁附"与 RIGHT_CTRL 同值（Win32 历史怪癖）"的错误注释为其背书。`readKey()` 的 `if (ctrl) { … vk-64 … }` 分支由此把带 SHIFT 位的记录判成 Ctrl，`A..Z` 走 `vk-64`：`M`(0x4D)→13=`CR`、`J`(0x4A)→10=`LF`、`B`→2、`R`→18、`T`→20。Windows Terminal 粘贴大写字母（带 SHIFT 位）→ `Broker`→`\x02roker`、`Rust`→`\x12ust`，且 `M`/`J` 凭空造出回车/换行。修复：按 Win32 规范（wincon.h）改正位掩码（右 Alt `0x1`、左 Alt `0x2`、右 Ctrl `0x4`、左 Ctrl `0x8`、Shift `0x10`），并把判别抽到平台无关新文件 `libs/cjterm/src/win_mods.cj`（`WIN_*` 常量 + `winCtrlPressed/winAltPressed/winShiftPressed`），`term_windows.cj` 改为调用（本地错常量删除，留指向 `win_mods.cj` 的注释）
- **粘贴换行绕过守护直达应用 → 粘贴过程中自动提交**（`libs/cjterm/src/term.cj` 第 679 行）：`readRawStreamPaste()` 末尾早退分支原为 `return this.backend.readKey()`，绕过 `readGuardedRawKey()`（第 361 行：无输入返 `None`；命中 `isGuardedPasteEnter` 则记 `TERM GUARD-DROP` 并 continue）。drain 循环遇抬键记录（Windows 后端 `readKey()` 对抬键返回 `None`）即 `break`，此时 `count == 0` 落入该分支；Windows 裸流粘贴按帧投递（每帧 1~3 条、按下/抬起成对），粘贴文本里的 CR 恰紧跟抬键之后 → 被当真实回车直达应用 → 粘贴中多次自动提交。修复：第 679 行改为 `return this.readGuardedRawKey()`（第 304 行同名调用属另一路径，不动）
- **长文本裸流粘贴逐字逐帧爬行 → 单帧吃干**（`libs/cjterm/src/term.cj`）：真机 `cjh_keys.log`（v1.3.26，13:22 那轮）定量——bulk 窗口 `t=11893970→18502849`（≈6.6 秒）仅投递 **414 字符**（≈63 字符/秒）；标记计数 `TERM pending` **2939**、`TERM bulk` **422**、`mark-paste-stream` 183、`burst` 25、`rate-armed` 12、`GUARD-DROP` 1、`GUARD-MISS` 3；窗口内 14 个 CR 中 13 个折进粘贴文本、1 个被守护丢弃（未泄成真实回车）。根因：`readRawStreamPaste()` drain 循环原为 `while (count < BULK_PASTE_MAX)`，遇 `readKey()` 返 `None`（Windows 后端抬键记录）走 `else { break }` → 每次上层 `readKey()` 只吃 1~3 条记录；粘贴期「按下/抬起」成对投递、抬键紧跟字符之后 → 每帧基本只前进一个字。修复：`term.cj:167` 新增 `private let MAX_DRAIN_RECORDS: Int64 = 4096`（Windows 控制台输入缓冲约 64KB、单条 `INPUT_RECORD` 约 16~20B → 一帧记录总数数千条，4096 足以一次吃干；同时作硬预算兜底，病态后端即使 `hasInput()` 恒真且不消费记录也不会死循环）；`term.cj:652` 循环条件改 `while (count < BULK_PASTE_MAX && records < MAX_DRAIN_RECORDS)`、每轮 `records += 1`、**删除 `else { break }`**（`None` 视为已消费的抬键记录继续 drain 至 `hasInput()` 为假或预算耗尽）；仅 `count == 0` 回落 `readGuardedRawKey()`（`term.cj:701`，未动），`readGuardedRawKey()`（375 行）与 bracketed paste 分支（318 行）均未动

### Added
- `libs/cjterm/src/win_mods.cj`：Win32 控制键状态位掩码常量 + `winCtrlPressed/winAltPressed/winShiftPressed` 判定，作为**平台无关纯函数**（置于 `@When[os == "Windows"]` 之外，Linux 门禁方可覆盖）
- `libs/cjterm/src/win_mods_test.cj`（6 例）；`libs/cjterm/src/term_paste_fallback_test.cj`（用例 `TermPasteFallbackTest.testBulkFallbackKeyUpDoesNotLeakPasteCr`）
- `libs/cjterm/src/term_paste_drain_test.cj`（2 例）：`testSingleFramePasteDrainedInFewReads`（一帧投递 200 字符、每 5 字符插 1 抬键；断言文本完整且 `readKey()` 调用 `calls <= 4`）、`testSingleFramePasteFoldsCrWithKeyUps`（断言 `isPaste == true`、`isEnter == false`、CR 折进粘贴文本）
- **思考(thinking) 历史可回看**（`libs/cjterm/src/thinking_log.cj` 新建 + `libs/cjterm/src/outputview.cj` + `src/tui/app.cj` 接入，版本号沿用 v1.3.26）：原实现把思考存在单个 `String` 里，**新一轮思考开始即清空上一轮**、且超 8192 字符**只留尾部**（开头被丢弃）——历史无从回看、回看也看不到开头。现在改为多轮**保序缓冲**（`ThinkingLog`：逐轮 `text/done/tokens/omitted`，单轮超限做「头 + 省略标记 + 尾」**中间截断**（按 Rune 边界切分，中文不截半），轮数上限淘汰最旧、总量上限兜底但**永不淘汰当前轮**）；`OutputView` 折叠态单轮沿用原文案、多轮显示「（N 轮）」，展开态逐轮 `💭 思考 #n` 标题 + `› ` 内容行，**复用既有 `PageUp`/`Ctrl+U`、`PageDown`/`Ctrl+D` 滚动回看**（未加新键位）；已完成轮次行冻结缓存，每帧只重建进行中一轮。`src/tui/app.cj` 增加 `testThinkingRounds()/testThinkingActive()` 观测点，帮助页 `Ctrl+T` 一行补「展开后可上滚回看多轮历史」
- `libs/cjterm/src/thinking_log_test.cj`（8 例：逐轮累积 / 空增量与无轮 `setTokens` 不造轮 / 单轮中间截断（头尾都在、中段确实省略）/ 上限 1 字边界 / 轮数淘汰且编号单调 / 总量淘汰不淘汰当前轮 / `setCurrent` 同轮覆盖与 `clear` 归零 / token 落在当前轮）
- `src/tests/thinking_history_test.cj`（5 例：单轮文案契约不变 / 多轮折叠显示轮数 / 多轮展开逐轮标题与内容 / `scrollUp` 回看到被滚出窗口的更早轮次 / 轮数变化后冻结缓存整体重建）；`src/tests/tui_app_test.cj` 增 `TuiAppReasoningHistoryTest`（3 例：跨轮累积、同轮增量不另开轮、空增量忽略）

### Tests
- 红→绿：改前 `cd libs/cjterm && cjpm test` = **FAILED: 3**（`testShiftIsNotCtrl`、`testLockKeysAndEnhancedNotCtrl`、ABI 钉桩）；改后 **PASSED: 57, SKIPPED: 0, ERROR: 0, FAILED: 0**（exit 0）。根因 A 用例红阶段原文 `Assert Failed: (k.isEnter == false)  left: true`（FAILED: 1）
- 测试保真度局限：现有 `DribbleMockBackend` 对任何事件都返回 `Some`、`hasInput()` 恒等于可见队列长度，无法表达真机"消费抬键记录却返回 `None`"语义；故用组合包装（`PasteFallbackKeyUpBackend`）把抬键哨兵翻译为 `None`，否则第 679 行在纯 mock 下是死代码、构不出红用例
- 定性结论（详见 `docs/开发文档与踩坑记录.md` §3.29）：粘贴合成记录带**真实 scan 码**（粘贴产生的换行是 `vk=0xD scan=0x1C uChar=0xD`，与手按回车完全同构；只有 CJK 才是 `vk=0/scan=0`），故"用 `scan==0` 区分粘贴换行与真实回车"**不可用**，只能靠上下文/时序判据
- 滴灌修复红→绿（`libs/cjterm/src/term_paste_drain_test.cj` 2 例）：改前 `cd libs/cjterm && cjpm test` = `TOTAL: 59, PASSED: 57, FAILED: 2`（exit 1），失败断言原文 `Assert Failed: (k.isPaste == true)`、`Assert Failed: k.text != expected.toString()`；改后 `TOTAL: 59, PASSED: 59, SKIPPED: 0, ERROR: 0, FAILED: 0`（exit 0）
- 门禁：cjterm 59/59；`./scripts/test.sh` = `TOTAL: 359, FAILED: 0`（exit 0）；`cjpm build` exit 0；`--mock` exit 0（命中 6 条工具调用链）；PTY `56 通过 / 0 失败`（exit 0）
- 思考历史门禁（v1.3.26 复打追加）：`cd libs/cjterm && cjpm test` = **PASSED: 67, FAILED: 0**（59→67，新增 `ThinkingLogTest` 8 例）；`./scripts/test.sh` = **TOTAL: 367, FAILED: 0**（359→367，新增 `thinking_history_test.cj` 5 例 + `TuiAppReasoningHistoryTest` 3 例）；`tui_pty_test.py` 新增场景 15「思考历史：`Ctrl+T` 展开 + `Ctrl+U` 回看思考开头」5 项断言全过——展开后上滚能看到**最早的思考增量**，旧实现（8192 截尾只留尾部 + 新一轮清空上一轮）下结构上不可能；多轮轮次标题（`思考 #n` / `（N 轮）`）由单测锁死（mock 的工具轮之间无 content，多轮推理会合并成同一轮思考，PTY 层不断言轮数）

### Changed
- **按键追踪（`KeyTrace`）恢复默认关闭（opt-in）**：真机粘贴投递问题已定性闭环（见下方"实测确认"），诊断无需常驻——现在只有显式真值（`CJH_TRACE_KEYS=1`/`on`/`true`/`yes`/`y`/`enable`，大小写不敏感、容忍引号与空白）才记录；不设变量或设 `0`/`off`/`false`/`no`/`n`/`disable` 均不记录、`describe()` 静默，**正式使用零副作用**。无法识别的值按"不开启"处理（安全默认），但 `describe()` 会回显正确写法——既不误开，也不"设了却不生效"
- **实测确认（v1.3.26 复打包，真机 13:41 那次运行轨迹）**：`TERM bulk` 事件 **422 → 8**，每次进入 bulk 路径时队列积压 `pending=862~891`（此前每次 `readKey()` 只吃 1~3 条），单次 drain 即吃干整帧；83 个 CR 全部作为粘贴内容折进（`GUARD-DROP=0`、`GUARD-MISS=1` 为真实回车）；用户在 TUI 中观察到粘贴**折叠为 `[Paste #N]`**——折叠阈值是**单次 paste 事件** ≥400 码点或 ≥5 行，滴灌实现下结构上不可能触发，折叠本身即"整段一次性到达"的证据

### Build
- `dist/` 产物重建（**版本号沿用 v1.3.26，不升**）：`cjh-windows-x64.exe` 13,626,368 B、`cjh-linux-x64` 16,541,736 B、`cjh-v1.3.26-windows-x64.zip` 4,662,469 B、`cjh-v1.3.26-windows-x64-selfcontained.zip` 7,723,424 B；`SHA256SUMS` 4/4 OK；zip 内 exe 与 `dist/cjh-windows-x64.exe` 同哈希（前 16 位 `b79cade062b46490`）；selfcontained 四枚 DLL 取自 `dist/windows-v1.3.25/`（与已交付包逐字节一致）
- `dist/` 产物重建（第四十一轮追加，思考历史特性进入全部产物，**版本号沿用 v1.3.26 不升**）：`cjh-windows-x64.exe` 13,651,968 B（`scripts/winbuild.sh` 交叉构建）、`cjh-linux-x64` 16,571,744 B、`cjh-v1.3.26-windows-x64.zip` 4,671,601 B、`cjh-v1.3.26-windows-x64-selfcontained.zip` 7,732,764 B；`SHA256SUMS` 4/4 OK（exe 前 16 位 `a12d295ae0a8f365`、linux 前 16 位 `d81e695bed193e06`）；zip 内 exe 与 `dist/cjh-windows-x64.exe` 同哈希；`dist/cjh-linux-x64 --mock` exit 0（32 行、命中 `FINAL-DONE`）；**两个产物各 `grep -c "展开后可上滚回看多轮历史"` = 1**（确认改动真的进了产物，排除"改库后产物陈旧"，见 §3.33）；`ldd` 仅 6 项系统库、`cjpm.toml` 保持静态（winbuild 临时改动已还原）

### Known limitations
- 无（本轮已消化第三十九轮的遗留滴灌项，详见 `docs/开发文档与踩坑记录.md` §3.30）

## [v1.3.25] - 2026-09-12

### Changed
- **按键追踪（`KeyTrace`）改为默认开启、免配置**：诊断设施不该依赖"记得设环境变量"——v1.3.24 让用户按指引采集轨迹时只找到 `cjh.log`/`tui.log`，排查被迫先花一轮证明仪器是否启动。现在**每次运行都记录**，仅显式设置关闭值（`CJH_TRACE_KEYS=0`/`off`/`false`/`no`/`n`/`disable`，大小写不敏感、容忍引号与空白）才关。
  - **每次运行重置**：启动时以 `w` 打开并写头行（版本 + 启动时刻 + 实际落点），之后逐行追加——文件只保留最近一次运行、永不无界增长；头行同时让"文件存在"成为"追踪确实在写"的自证
  - 轨迹含键入键码（RAW 行 `uChar` 为十六进制码点），仅用于终端投递诊断；不需要时用上述关闭值关掉

### Fixed
- **按键追踪"设了变量却找不到文件"的两条成因**：
  - 值解析曾苛求字面量 `1`：cmd 的 `set CJH_TRACE_KEYS="1"` 会把**引号写进值里**，尾随空白同样常见 —— 旧实现直接比较必然不等 → 追踪静默不开启、无任何提示。现统一去首尾空白 + 去成对引号 + 大小写不敏感（`1/on/true/yes/y/enable`）；**无法识别的值按默认开启处理**，并由 `describe()` 回显写法——开关不再可能静默失效
  - 默认落点曾跟随**进程当前目录**（双击 exe 时即 exe 目录），与用户已知的 `cjh.log`（`~/.cjh/logs/`）/`tui.log`（`~/.cjh/`）不是一处，按日志位置翻必然落空。现默认落点改为 `${USERPROFILE|HOME}/.cjh/cjh_keys.log`（同目录）；父目录不存在自动创建；落点不可写时回退当前目录并在文件内留痕
- **TUI 启动面包屑**（`src/entries.cj`）：把实际落点写进 `cjh.log`，用户不必猜文件在哪（显式关闭时静默）

### Tests
- `libs/cjterm/src/trace_test.cj` +10 用例（cjterm **50/50** 全绿）：
  - 默认开启：未设任何环境变量 → 仍在记录，且头行落盘
  - 复现用例：带引号的值（`"1"`）→ 仍开启并落头行
  - 显式关闭：`CJH_TRACE_KEYS=0` → `describe()` 为空、`mark` 不落盘
  - 配置有误可自证：无法识别的值 → 按默认开启且 `describe()` 给出提示
  - 纯函数：`normalizeValue`（引号/空白/单字符/引号不配对边界）、`isTruthy`/`isFalsy`（大小写与多种写法）、`isRecognized`（垃圾值）、`defaultPathFor`（有/无家目录，含 Windows 路径）

### Build
- `dist/` 产物重建为 v1.3.25
- ⚠️ v1.3.24 的分帧粘贴修复仍待 Windows Terminal 真机确认；本版让轨迹采集不再受任何书写方式或落点差异影响

## [v1.3.24] - 2026-09-12

### Fixed
- **Windows Terminal 分帧投递的粘贴换行仍被当成真实 Enter 提交**（v1.3.23 守护窗实测未命中，用户复现）：v1.3.21 的 burst（`BURST_PENDING_MS = 4` / `BURST_ACTIVE_MS = 15`）与 v1.3.23 的守护窗 + 成串密度判据，前提都是"粘贴内容短时间**成串**到达"；WT 实测按**帧**分块投递（每帧 1~3 事件、帧间可达数十毫秒）时，每次聚合只看到 1 个候选字符 → `isPasteBurst` 恒假、密度恒不足、守护窗口永不置位 → 尾部/行间 `\r` 与用户手按 Enter 事件层同构（`KeyEvent(13,"\r")`）→ `InputBox` 立即提交。
- **判据从"时间窗口/积压"升级为"到达速率"**（`libs/cjterm/src/term.cj`）：新增 `notePasteCandidate()` 维护 300ms 滚动到达窗口 `(时刻, 是否换行)`，窗口内**非换行候选 ≥ `PASTE_STREAM_RATE_MIN = 12`** 且**换行数 × `PASTE_STREAM_RATE_NL_DIV = 3` < 字符数** → 认定处于粘贴流，持续刷新 `PASTE_ENTER_GUARD_MS = 200` 守护窗口（沿用 v1.3.23 的 `readGuardedRawKey()` 吞键）。不依赖任何单次间隙/瞬时积压。
  - 排除误判：人类打字 ≤10 字符/秒达不到 12/300ms；输入法逐字提交是"字+回车"交替（换行占比 ≈1:1，被换行占比条件排除）；held-key 连发（同字符 <10/300ms）同样达不到。
  - 影响面：仅裸流后端（Windows 控制台）；POSIX 走 bracketed paste 解析（`\r` 不会单独成键），行为不变。

### Added
- **`Clock` 时间源抽象**（`libs/cjterm/src/clock.cj`）：`Term` 新增 `init(injected: TerminalBackend, clock: Clock)` 注入点，粘贴守护窗口与到达速率窗口统一走 `this.clock.now()` —— 时间窗口逻辑可用虚拟时钟确定性验证，不再依赖真实 `sleep` 与机器速度（v1.3.21/23 的"测试全绿但实测复现"结构性成因之一）。
- **`KeyTrace` 按键轨迹诊断**（`libs/cjterm/src/trace.cj`）：`CJH_TRACE_KEYS=1` 时把每个 `INPUT_RECORD` 的 `down/vk/scan/uChar/ctrl` 与 Term 层决策（`pending/path/GUARD-DROP/GUARD-MISS/rate-armed`）逐行追加到 `cjh_keys.log`（`CJH_TRACE_FILE` 可覆盖输出路径），用于只在真机复现的终端投递问题定性；关闭时仅一次 Bool 判断，零开销。

### Tests
- `libs/cjterm/src/term_paste_rate_test.cj` +4 用例（cjterm 39 全绿）：新增 `FakeClock` + `DribbleMockBackend`（按帧投递 mock，帧间由测试 `frame(ms)` 推进、与 Term 共享虚拟时钟）——
  - 分帧粘贴（每帧 1 字符、帧间 16ms）尾部换行必须被吞（`None`），不得提交
  - 分帧粘贴正文含空行：行间换行同样被吞
  - 反例锁：人类打字节奏（400ms/字符）后回车照常提交
  - 反例锁：高频"字+回车"风暴（10ms/事件）回车照常提交（防输入法回归）
- `libs/cjterm/src/trace_test.cj` +3 用例：hex 字段格式化（0xD/0x1C/0xFFFF）/ 开启时逐行追加（含序号）/ 关闭时绝不落盘
- 敏感性验证：临时把 `PASTE_STREAM_RATE_MIN` 置 9999（等价关闭速率判据）→ 2 个复现用例转红；还原后全绿

### Build
- `dist/cjh-v1.3.24-windows-x64.zip`（单 exe）+ `dist/cjh-v1.3.24-windows-x64-selfcontained.zip`（exe + DLL）+ `dist/windows-v1.3.24/` + `SHA256SUMS`；Linux `dist/cjh-linux-x64`
- ⚠️ 真机复测状态：Windows Terminal 实测确认中；若仍复现，用 `CJH_TRACE_KEYS=1` 采集 `cjh_keys.log` 轨迹（含投递节奏与 `scan` 码）再定性

## [v1.3.23] - 2026-09-12

### Fixed
- **Windows 分块投递的粘贴换行仍被当成真实 Enter 提交**（用户实测复现，v1.3.21 burst 修复的残余场景）：conhost/Windows Terminal 把一次粘贴拆成多"波"写入输入缓冲，**波间间隙实测超出 burst 的 PENDING 4ms / ACTIVE 15ms 窗口**——剪贴板末尾换行一旦单独成一波，该波只含 1 个候选字符，`isPasteBurst` 的四条件（≥2 字符 + 含换行 + 含非空白 + 行长平均）必然不成立，旧实现原样返回裸 Enter → `InputBox` 立即提交（用户并未按回车）。该键与"用户手按 Enter"在事件层完全同构（conhost `VK_RETURN` `uChar=0x0D`），单键分类无解。
- **判据从"单键"升级为"上下文"**（`libs/cjterm/src/term.cj`）：新增**粘贴流守护窗口** `PASTE_ENTER_GUARD_MS = 200` —— 处于粘贴流时，紧随其后的裸 Enter 判为终端为粘贴补发的换行，直接吞掉并同帧继续读键，绝不作为提交键返回。
  - **置位条件 ①**：任一路径发出 `isPaste` 事件（`readRawStreamPaste` bulk 合并的两处 return / `tryAggregateBurst` 签名命中——bulk 路径最终 return 分支曾漏置位，测试当场抓出）。
  - **置位条件 ②**：成串输入密度达标（一次聚合内 ≥`PASTE_STREAM_MIN_CHARS = 8` 个非换行候选字符）——覆盖"波界恰好落在换行前、前半段无换行"的分块场景。人类打字/输入法提交不可能在 4/15ms 窗口内凑齐 8 字符，故该密度只对机器成串投递成立。
  - 窗口取 200ms：人手从 Ctrl+V 移到 Enter 通常 ≥300ms，故不长期吞真实 Enter；即便极端手速命中，最坏结果是需要再按一次 Enter（不丢内容、不误发）。
  - 仅作用于裸流后端（Windows 控制台）；POSIX 走 bracketed paste 解析（`\r` 不会单独成键），行为不变。

### Tests
- `libs/cjterm/src/term_paste_burst_test.cj` +5 用例（32 全绿）：新增**分块投递 mock** `ChunkedMockBackend`（虚拟时钟模拟 conhost 分波投递 + 波间延迟，修掉了旧 `MockBackend` "整块一次性可见"导致**测不出分块场景**的保真度缺口）——
  - 用户实测文本短版（burst 路径）+ 尾部补发 Enter 不得提交
  - 用户实测长文本（≥48 事件，bulk 路径）+ 尾部补发 Enter 不得提交
  - 波界恰落在换行前（无换行前半段 + 换行单独成波）不得提交
  - 反例锁：手敲 3 字符后 Enter 照常提交（不误吞）
  - 反例锁：守护窗口过期（真实 sleep 300ms）后 Enter 照常提交
- 修复前 3 个新用例红（复现确认）→ 修复后全绿；门禁：`./scripts/test.sh` 359 + cjterm 32 全绿 + `cjpm build` + `--mock` + PTY 56/56

### Build
- 发布 v1.3.23 双平台产物（同 v1.3.22 布局）：`dist/cjh-linux-x64`（静态，`ldd` 仅 6 系统库）+ `dist/cjh-v1.3.23-windows-x64.zip`（单 exe）+ `dist/cjh-v1.3.23-windows-x64-selfcontained.zip`（exe + runtime/openssl DLL）+ `dist/windows-v1.3.23/`；exe 导入表 7 DLL（stdx 静态链接，无 libstdx DLL），`dist/SHA256SUMS` 三产物校验全 OK

## [v1.3.22] - 2026-09-11

### Changed
- **atomcode 式 steer：忙时 Enter 只入队、不打断当前回合**（旧"强制插入发送"行为回归——commit `2cae3f1` 引入的忙时打断副作用大：当前 LLM 请求被 abort、半截响应丢弃）。新交互语义：
  - 忙时 **Enter** = 只入队（状态行"排队 N 条待发送"，不触发中断回调），Agent 每轮 LLM 请求前拉取队列注入 user 消息（本回合内处理，不产生新 turn）
  - 忙时 **Esc** = 中断当前回合并立即发送（保留队列，run 结束后作为新 turn 自动发送）
  - 忙时 **Ctrl+C** = 两级中断不变（第一次请求中断，第二次强制退出）
- **Agent 轮边界排队输入注入**（`src/agent/loop.cj`）：新增 `onRequestPendingInput: () -> Option<String>` 回调（默认 None=无排队），runLoop 每轮 LLM 请求前（`checkPendingCompact()` 之后，防新指令被 compact 摘要吞掉）while-let 排空队列注入 user 消息 + `[steer] 收到排队输入: …` 标记；轮顶 interrupt 检查在前 = 中断优先于注入（Esc 后 drain 跳过，剩余队列留给 run 后新 turn）。`entries.cj` 接线 `agent.onRequestPendingInput = { => tui.dequeueInput() }`。
- 帮助页快捷键更新：Esc 行补"忙时中断并立即发送排队消息"。

### Tests
- +7 单测：`src/agent/pending_input_test.cj`（drain 4 用例：轮顶注入位置/多条 FIFO 排空/工具完成后边界注入/中断跳过 drain）+ `tui_app_test.cj`（忙时 Enter 不打断回归锁/忙时 Esc 中断且队列保留/空闲 Esc 不误触发中断）
- PTY 场景10 改 steer 断言（入队提示 + "收到排队输入"标记 + 无"已中断" + FINAL-DONE 恰好一次）；新增场景11（Esc 中断 → 排队消息作新 turn 发送），原 11/12/13 顺延为 12/13/14
- 门禁：359 单测全绿 + `cjpm build` + `--mock` + PTY 56/56

### Build
- 发布 v1.3.22 双平台产物：`dist/cjh-linux-x64`（静态）+ `dist/cjh-v1.3.22-windows-x64.zip`（单 exe，4.6MB）+ `dist/cjh-v1.3.22-windows-x64-selfcontained.zip`（exe + `libcangjie-runtime.dll`/`libboundscheck.dll`/`libssl-3-x64.dll`/`libcrypto-3-x64.dll`，解压即用）；`SHA256SUMS` 重打校验。Windows exe 导入表 7 DLL（stdx 静态进 exe），与 v1.3.21 一致

## [v1.3.21] - 2026-09-11

### Fixed
- **Windows 粘贴带换行长文本直接触发提交修复**：根因 = 裸流合并路径遇第一个 `\r`（isEnter）停合并并丢弃 + 短粘贴（<48 事件）无聚合全程单键路径——多行粘贴的换行与用户 Enter 在 conhost 是同一事件（VK_RETURN `uChar=0x0D` → `KeyEvent(13,"\r")`），残留缓冲里的 `\r` 被主循环当真实 Enter 消费。修复对齐 atomcode `input/reader.rs` burst 检测器：长粘贴合并循环吸收裸 Enter 为内容换行 + burst 两级窗口聚合（PENDING 4ms 单键探测 + ACTIVE 15ms 桥接 conhost/WT 分块间隙）+ 粘贴签名四条件（防拼音 IME 逐字提交风暴误判）+ 重放队（非粘贴 burst 按序还回）+ `Term.init(injected:)` 测试注入点。

## [v1.3.20] - 2026-09-10

### Changed
- **输入框长粘贴软换行显示 + [Paste #N] 折叠恢复**：粘贴保留真实换行（CRLF→LF 归一化）并在光标处插入（保留已有前缀）；≥5 行（有效内容行）**或** ≥400 码点折叠为 `[Paste #N]` 原子 marker（多行 `+X lines`/单行 `X chars`，对齐 atomcode `PASTE_FOLD_LINES=5`/`PASTE_FOLD_CHARS=400`；原文存 pasteStore，Enter 展开原文提交、退格整体删、支持前缀+marker 混合展开）；未达阈值原文按显示宽度自动软换行（首行预算 `cols-提示符宽`、续行 `cols-2` 缩进、CJK=2 列），显示区最多 5 行、视口跟随光标；`TuiApp` 输入区改动态高度（`displayHeight()`）。修复粘贴光标错位（`wrappedLines` 截断 5 行后视口滚动读到过期首行段，改为返回全部行段按绝对行号取段）。

## [v1.3.19] - 2026-09-10

### Fixed
- **TUI 粘贴不折叠**：旧阈值按字节计 1000（中文 1 字 3 字节 ≈333 汉字才触发），改码点 200；折叠由整段替换 `text_`（静默丢前缀）改 `insertAtCursor` 追加。
- **Windows 长工作路径状态栏折行**：`StatusBar.render` 从不截断，超行宽终端自动折行挤乱布局。新增 `truncateContent`（ANSI 感知 + CJK=2 列 + 尾部 `…`），超 `width-5` 预算截断。
- **裸流粘贴合并（Windows）**：Windows 控制台不支持 bracketed paste，粘贴以离散 KEY_EVENT 涌入逐键处理卡顿。`TerminalBackend` 加 `supportsBracketedPaste()`（POSIX=true 走自身解析/Windows=false 走 Term 层合并）+ `readPendingBytes()`（POSIX=FIONREAD/Windows=待读事件数），`Term.readKey` 积压超阈值时连续吞读可打印字符合并为单个 `isPaste` 事件（`hasInput` 非阻塞守卫防冻结）。

## [v1.3.18] - 2026-09-09

### Fixed
- **InputBox 中文光标偏移（Windows）**：`render()` 用 rune 计数算光标位置，CJK 占 2 列致显示偏左（输入正确）。改用 `TuiCanvas.displayWidth()` 算显示列数。
- 附带修复 `InputBoxHistoryTest` 编译错误——仓颉 `@Test` 宏不支持 `for(i in 0..N)` 循环，改 `while`（踩坑 §3.22）。

## [v1.3.17] - 2026-09-08

### Fixed
- **Windows bash 工具 /bin/bash 不存在：Shell 降级 + 平台感知缺失**：`BashSession.ensureStarted()` 硬编码 `launch("/bin/bash", ...)`，Windows 上 `/bin/bash` 不存在导致 `ProcessException: Created process failed`；`BashTool` timeout 路径同理硬编码 `bash -c`。新增 `ShellProvider`（`term_util.cj`）平台感知 shell 解析器——Windows 通过 `OS=Windows_NT`/`windir` 环境变量检测，候选 Git Bash 三路径（系统级 ×2 + 用户级 portable）→ Unix 默认 `/bin/bash`；`CJH_SHELL` 环境变量可强制覆盖。`BashSession` 改用 `ShellProvider.shellPath`，`execute()` 命令模板按 `isBash` 分支（bash 保持 `{ cmd; }` 语法，PowerShell 用 `$LASTEXITCODE`）；`BashTool` timeout 路径按 `isBash` 分支（bash `timeout --kill-after=2s`，PowerShell `cmd.exe /c timeout`）。cjterm 包无法 import `std.fs`（构建范围限制），改为 launch 失败时报错提示。

### Tests
- Windows 交叉编译通过（winbuild.sh，PE32+ x86-64 Windows 控制台程序）

## [v1.3.16] - 2026-09-08

### Fixed
- **Windows TUI 框线混排根治**（v1.3.7 起遗留）：`isUtf8()` 旧判据仅 `GetConsoleOutputCP()==65001`，而 Windows Terminal 内部恒按 UTF-8 渲染、根本不读控制台代码页（中文系统 CP 仍 936）→ 误判 false → logo/标题栏/状态栏降级 ASCII，但 InputBox/StatusBar/TabBar/TasksPanel/markdown 表格边框硬编码 UTF-8 → 同屏混排（`╭─╮` 与 `+--` 并存）。修复三件套：
  - **判据补全**：新增 `isModernTerminalEnv()` 纯函数（`WT_SESSION`/`WT_PROFILE_ID`/`ConEmuANSI`/`ConEmuTask`/`CJH_FORCE_UTF8`），`isUtf8()` 改为「代码页 65001 ∪ 现代终端环境」双判据
  - **主动切代码页**：`WindowsTerminalBackend.enableRaw()` VT 开启成功后 `SetConsoleOutputCP(65001)`（能开 VT 的终端必支持 UTF-8，不依赖用户手动 `chcp`），`disableRaw()` 恢复原值——退出后用户控制台会话不受影响
  - **组件降级统一**：新增 `BoxChars` 统一边框字符集（圆角+直角+T 型），InputBox（`╰─ ❯`→`+-- >`、搜索图标 `🔍`→`?`）/StatusBar（`┌─`→`+--`）/TabBar（`│`→`|`）/TasksPanel（`╭╮╰╯`+`✓▶☐`→ASCII）/markdown 表格（`┌┬┐├┼┤└┴┘│`→`+`/`-`/`|`）/`titleBarFull` 全部按 utf8 标志选择；`TuiApp.run()` 在 enableRaw 后统一重设 8 个组件的 utf8 标志（消除 conhost 下「构造早于切代码页」的陈旧值混排）；Spinner/Box/ConfirmDialog/WelcomeView/FormDialog 补 `setUtf8` 接线
  - 新增 `TuiApp.isUtf8()` 透传 + `CJH_FORCE_UTF8` 环境变量（用户侧强制开关/排障手段）

### Tests
- +17 用例（`libs/cjterm/utf8_fallback_test.cj`：BoxChars 双形态、`isModernTerminalEnv` 5 场景、5 组件 UTF-8/ASCII 降级渲染断言——cjterm 首个测试文件）+ +2 用例（`tui_test.cj`：markdown 表格边框双形态）
- 门禁：根包 337 全绿 + cjterm 17 全绿 + `cjpm build` + `--mock` + TUI PTY 15 场景 49 断言全过 + **Windows 交叉编译通过**（winbuild.sh；首次踩坑：POSIX `setenv` FFI 无 `@When[os != "Windows"]` 守卫致 exe 链接失败）

## [v1.3.15] - 2026-09-06

### Fixed
- **回合统计 `0% cached` 统计缺口**：`StreamAccumulator` 只解析 DeepSeek 顶层 `prompt_cache_hit_tokens` 与 Anthropic `cache_read_input_tokens`，未解析 OpenAI 标准 / 智谱 GLM 等 OpenAI 兼容接口的**嵌套字段** `usage.prompt_tokens_details.cached_tokens`——跑 GLM/OpenAI 兼容 provider 时缓存命中恒为 0，状态条永远显示 `0% cached`（实际缓存可能已命中）。现按优先级解析：顶层两字段优先，嵌套字段兜底（仅当缓存值仍为 0 时读取），`prompt_tokens_details` 非对象时容错不抛异常。

### Tests
- +3 用例（`libs/cjllm/llm_test.cj`）：嵌套 `cached_tokens` 解析（GLM 真实形态 5300/12/4988）、命中为 0 与异常形态容错、顶层字段优先级
- 门禁：cjllm 34/34 + 根包 335/335 全绿 + build + --mock

## [v1.3.14] - 2026-09-06

### Added
- **V3 信任链 Step 3：信任管理 CLI**（`~/.cjh/trusted-publishers` + `cjh trust/untrust/trust-list`）：
  - 信任列表文件 `~/.cjh/trusted-publishers`（每行一个 publisher ID 或 SM2 公钥 hex，`#` 注释）
  - **空列表 = 开放模式**（默认，向后兼容）；**非空 = 严格模式**：签名插件 publisher/pubkey 必须命中列表，不匹配拒绝加载并提示 `cjh trust <publisher>`；无签名插件严格模式下同样拒绝
  - 信任列表随 `loadPlugins` 注入 `PluginManager`，与 Step 1 校验和 / Step 2 SM2 验签串联成完整信任链
- **第三方风格插件示例**（`example/plugins/`）：git-status 工具插件 + tool-result-banner 钩子插件，附加载/执行/钩子触发的单测（`example_plugins_test.cj`），锁住 plugin.json 加载契约

### Docs
- `docs/插件签名与贡献指南.md`：Step 2/Step 3 状态更新为已实现，补信任列表语义说明与信任链完整流程
- README（中英）：价值主张正面化 + 按受众价值总结表（源码注释完备、可读可学习）

### Tests
- +7 信任用例（`core_funcs_test.cj`：解析/增删/匹配/端到端强制加载——真实 SM2 签名插件在开放/严格×匹配/不匹配下行为）
- +3 插件示例用例（`example_plugins_test.cj`）
- 门禁 335 单测全绿 + `--mock` 端到端通过 + 信任 CLI 三命令实测

## [v1.3.13] - 2026-09-06

### Added
- **P2 OutputView 增量行缓存（优化提速方案 G4）**：render 每帧对全量缓冲 `split("\n",-1)`（O(总量)，长会话卡主循环）改 `lineCache` 增量维护——`append`/`appendDelta`/`ensureNewline` 走 O(本帧文本) 增量，`endStream` 全量重建；渲染输出逐位不变
- **P2b TUI 视觉层次美化**：状态栏边框 `+--` → Unicode `┌┐─` 实线；状态栏 bg234 / 用户回显 bg237 / 工具调用行 bg236 / 思考块 bg233 整行背景卡片（`padBg` 统一补 `cols-1`）；行内代码芯片（fg250+bg236）
- **`NO_COLOR` 支持**：设置后 TUI 全部颜色/样式转义返回空串（无障碍/管道场景）
- **TUI 主题扩至 10 套**：新增 dracula / nord / gruvbox / tokyo-night（v1.3.0 批次加入），`/theme` 实时切换
- 双平台发布包：`dist/linux/cjh-v1.3.13-linux-x64` + `dist/cjh-v1.3.13-windows-x64.zip` + SHA256SUMS

### Fixed
- **TUI 边框恒灰根治**：`Theme.apply()` 早已写回 `Ansi.THEME_BORDER = p.border`，但主题表无一处赋值 `.border` → 10 主题全部静默回退默认 244。修复：每个主题显式设 `.border`（同色系醒目色，如 starfrost 73 / dracula 177 / gruvbox 208），`/theme` 切换边框即时变色
- 整行背景卡片内 `Ansi.reset()` 断裂问题（`Logo.badge` 嵌入点改 `fg()` 重设）

### Changed
- 性能：流式长会话渲染 CPU 成本从 O(总量) 降至 O(本帧新增文本)

### Tests
- +12 用例（`outputview_linecache_test.cj`，行缓存与 `content().split` 逐位等价，含首/尾空串边界）；门禁 325 单测 + PTY 15 场景 49 断言全绿

## [v1.3.12] - 2026-09-04

### Fixed
- **粘贴中文乱码根治**：复制中文粘贴进 TUI 输入框变 `å¥½` 类 Latin-1 乱码。根因 = `readBracketedPaste` 逐字节 `Rune(Int32(byte))` 拼接（与 bash 输出乱码同款，bracketed paste 独立路径漏网）。修复：字节累积到 `ArrayList<Byte>` + 字节层结束标记匹配 + 整段 `safeFromUtf8` 解码（cjterm 新增 cjutil 依赖）

### Tests
- +8 单测（`TermPasteDecodeTest`）+ PTY 场景13（真实粘贴中文/emoji 进输入框）；290 单测全绿

## [v1.3.11] - 2026-09-04

### Fixed
- **长会话 TUI 主协程停摆 + 泄漏 bash/僵尸根治**：51 轮 43 分钟重 bash 会话后 TUI 停摆（按键无响应、画面冻结、终端停留 raw）。根因两条叠加：① 9 处裸 `Mutex.lock()` 未 `try/finally` 守护，持锁临界区抛异常即锁泄漏 → 主循环与流式回调双双 park → 仓颉"无可运行协程"stop 路径；② 退出路径不清理子进程 + `killSession` 只 terminate 不 wait → 僵尸 + 泄漏会话 bash
- 修复：全部裸 `lock()` 加 `try/finally` 守锁 + `run()` 每帧 try/catch 兜底 + `finally→restoreTerminal`；`killSession` 加 `wait(5s)` 回收；退出清理（close bash / disconnect MCP / `Log.shutdown`）；mock 加 `CJH_MOCK_BASH` 门控驱动真实会话

### Tests
- +3 回归用例 + 退出路径 PTY（无残留子进程、终端 raw=False）；282 单测全绿

## [v1.3.10] - 2026-09-03

### Fixed
- **TUI 假死/无法输入根治**：画面冻结无法输入但进程存活 CPU 100%。根因 = `cjlog.LogSink` 异步日志的空闲节流 `sleepMs` 写成纯整数忙等（`while (i < ms*1000)` 自增不耗时），sink 协程在仓颉主 worker 上满速自旋，饿死 TUI 渲染/输入主循环。修复：改真实 `sleep(Duration.millisecond * ms)`

### Tests
- +1 回归用例（耗时断言先红后绿，78µs 空转→真实 ~80ms）；280 单测全绿

## [v1.3.9] - 2026-09-03

### Fixed
- **工具输出中文乱码根治**：bash 会话 stdout 显示 `éè¯»...`（中文 UTF-8 字节被逐字节当 Latin-1 码点）。根因两处同类 bug：① `bash_session.readUntilMarker` 逐字节 `String(Rune(byte))` 拼 stdout；② `web_search.urlDecode` 的 `%XX` 逐字节转字符。修复：整段/字符边界 `safeFromUtf8` 解码（bash 路径维护跨块 pending 字节）

### Tests
- +4 回归用例（bash 中文跨 4096 读取边界先红后绿 + urlDecode 3 组）；279 单测全绿

## [v1.3.8] - 2026-09-03

### Fixed
- **"连续几轮会话总被打断"根治**：空闲看门狗误杀推理模型"前思考期"——用户反馈几乎没法用，连续对话被"模型 Ns 无响应"反复中断。curl 直连铁证：模型没停滞（300s 发 12269 帧全是 reasoning）。根因全在客户端：① `agentLastActivity` 跨 run 不重置（上轮旧帧污染新轮判定）② 空闲预算默认 60s 过激进（doc 写 180s）③ token 估算跨轮残留（0.0K 显示）。修复：run 启动 + onThinking 每轮重置锚点、默认 60→180s、`resetAgentTokens` 每轮清零

### Tests
- +3 回归用例 + 真实模型 PTY 连续 3 轮全通过（看门狗/强制插入 0 条）；275 单测全绿

## [v1.3.7] - 2026-09-02

### Fixed
- **双平台发布包修复**：打包时发现 HEAD 的 cjpm.toml 静态链接配置早被连带清空（README 声称默认静态，实际产动态二进制，v1.3.5~v1.3.7 连续 3 版无人察觉）；winbuild.sh 的 stdx 路径指向 dynamic/ 致 Windows exe 动态挂 12 个 libstdx DLL。修复：恢复 `--static --static-std --static-libs` + static/stdx 路径

### Changed
- **预算竞速下沉传输层**：`runWithBudget` 从 openai.cj 调用点下沉进 `HttpStreamClient.connect()/request()` 内部——anthropic/ollama/**未来任何复用传输层的新协议零改动自动获得保护**（connect 预算=idleTimeout 且重试一次、request 预算=writeTimeout 30s）

### Tests
- +1 黑洞地址回归用例（TEST-NET 实测裸 connect 8s+ 挂起 → 预算 1s 时 ~2s 抛 BudgetTimeoutException）；272 单测全绿

## [v1.3.6] - 2026-09-02

### Fixed
- **首个 LLM 请求 442s 卡死 + 8 次中断全部失效根治**：根因 = 仓颉裸 `TcpSocket.connect`（DNS/TCP/TLS）无超时参数 × `HttpStreamClient.abort()` 只 close 已建的 socket、connect 挂死期间 socket==None 空转。修复：新增 `cjutil.runWithBudget` 预算竞速原语（spawn + Future.get 轮询 + cancelChecker + 预算），openai.cj 四处窗口（connect×2 / request×2）全部包上

### Tests
- +5 cjutil 用例；272 单测全绿

## [v1.3.5] - 2026-09-02（无 tag）

### Fixed
- **TUI 僵尸忙态根治**（"Streaming… 永不结束 + 排队永不发送"事故）：根因 = 仓颉 `String[0..N]` 字节切片校验 UTF-8 边界 × spawn 未捕获异常静默杀任务线程——`summarizeForMemory()` 的 `task[0..60]` 在中文摘要上必炸，且调用点在 spawn 收尾块 try 之外 → `setAgentRunning(false)` 永不执行。修复：切片改 `truncateUtf8` + 收尾块独立 try/catch 兜底。**技术债"偶发 UTF-8 异常"正式闭环**

### Tests
- +3 回归测试（事故真实数据）；269 单测全绿

## [v1.3.4] - 2026-09-01

### Fixed
- **Streaming 卡死根治**：空闲预算 180→60s + timedOut 内容保留不重试（代理 keep-alive 不发完成标记时的"卡→重试→又卡"死循环）；事件级空闲预算（内容不再增长 + 时间流逝即结束回合）
- **粘贴自动发送修复**：启用 bracketed paste（`ESC[?2004h`）+ `readBracketedPaste` 连续空闲判定（原 1.5s 总超时漏闭合标记）
- 连按方向键残留字母（AAAA/BBBB）：CSI 序列 next 已是终结字母仍多读吞序列
- Windows 方向键识别加固（vkToKeyEvent 改 if-else——交叉编译 match 常量比较异常）
- markdown 表格底边框后另起一行

### Added
- 忙时 Enter 强制插入发送（打断当前回合 + 排队，对齐 omp followup）
- 帮助页补全（/provider /skills /compact /tree /fork /task /theme + 输入技巧 + 快捷键）且超屏可滚动
- 看门狗回归测试（keep-alive 空帧停滞场景）

### Tests
- 269 单测 + 46 PTY 全绿

## [v1.3.3] - 2026-08-31

### Fixed
- **流式传输根治**：finish_reason / 短读轮询 / 响应头轮询全阶段可中断（此前只包了部分阶段，中断在轮询窗口全失效）；大 chunk 越界修复
- markdown 渲染对齐 omp：ATX 标题主题色 / 表格完整边框 / python 内置函数高亮；思考块配色对齐 omp

### Added
- 轮次软顶（默认 100 + 收尾指令）
- 两级 Ctrl+C 兜底（任务中打断/强退，空闲一次退出）

### Tests
- 261 单测 + 41 PTY 全绿

## [v1.3.2] - 2026-08-29

### Added
- **bash 超时 + Ctrl+C 中断当前轮** + 持久 bash 会话（`BashSession` 跨轮复用）
- **跨会话项目记忆**（AGENTS.md 注入 + 会话存档）
- **摘要快模型路由**（compaction 走快模型，实测主模型摘要 10-100s → 快模型数秒）
- **429 备用 key 轮换**（`fallbackKeys` 自动切换）
- compaction 保留工具结果；read_file SQLite 支持；提示词优化

### Changed
- **静态链接单文件发布**：cjpm.toml 默认 `--static --static-std --static-libs`，Linux 产物单文件零依赖（含仓颉运行时+stdx）

### Tests
- 228 单测 + 36 PTY 全绿

## [v1.3.1] - 2026-08-29

### Fixed
- **LLM 效率三连修复**：① compaction 检查从 run() 开头移入每轮循环（原实现单次任务几十轮内从不复查）② 触发信号用真实 `usage.promptTokens`（字符估算实测 7x 低估）③ `compactKeep` 12→6（否则压缩删不掉足够消息）——prompt 峰值 42.9K→9.4K
- **10 个潜伏 bug 修复**：edit 替换毁文件（Byte 当十进制输出）、hashline FNV-1a 溢出、grep/glob 目录搜索不递归、append_file 静默创建、capability 资源检查缺口、会话 ID 毫秒碰撞、tool 消息丢 name、glob/list_dir 静态状态竞态等

### Added
- **单测纳入 CI 门禁**（AGENTS.md 项目指令：`cjpm test` 全绿为唯一交付凭证）
- 每轮过程日志（cjlog 独立异步日志库，双文件落盘）
- build.cj 产物改名 cjh（cjpm 固定输出 main，post-build 复制）

### Tests
- 单测扩至 182 全绿

## [v1.3.0] - 2026-08-28（无 tag）

### Added
- **Web 支持**：内置 HTTP Server + WebSocket 流式对话（`ChatRequest`→`tool_start`→`tool_result`→流式 `delta`→`done`）+ REST API（sessions/models/tasks/health）+ 前端 SPA（原生 JS + marked.js + DOMPurify + highlight.js）+ auth_token 鉴权中间件 + 启动安全审计日志
- **插件信任链**：SHA256 校验和（Step 1）+ SM2 国密签名验证（Step 2，仓颉 `stdx.crypto` 原生）+ `require_signature` 配置
- V2e IM 网关 Channel 抽象（Web 渠道重构）
- **4 套经典主题**：dracula / nord / gruvbox / tokyo-night（TUI 主题 6→10）
- Web 前端 skills/mcp 侧边栏 + settings 配置页 + 流式 Markdown 渲染优化

### Tests
- Web 协议端到端验证（python WS 客户端实测 28 帧流式）

## [v1.2.3] - 2026-08-24

### Added
- **OMP 风格写入架构**：write_file 整段写入 + append_file 续写 + hashline 行锚点编辑三件套，英文 prompt 引导工具选择
- **cjutil 底层包抽离**（通用工具独立：UTF-8 安全解码 / 字节安全截断）

### Fixed
- JSON 截断容错（repairTruncatedJson）+ write_file 工具描述改进
- UTF-8 安全解码防 TUI 崩（非法字节容错 U+FFFD）

## [v1.2.2] - 2026-08-24（无 tag）

### Added
- **回合总结条**：每轮结束 `✓ N rounds · M tools · Xs · Y tokens · Z% cached`（`ModelResponse.usage` 新增 `TokenUsage`，三协议 usage 解析）
- **/compact + /tree + /fork**：手动压缩 + 树形会话列示/分支
- **星霜青主题系统** + `/theme` 交互式选择器（方向键选择）

### Fixed
- 回复左右留白 + 空行分隔；状态栏边框输入框可见性

## [v1.2.1] - 2026-08-24

### Added
- 星霜青主题（品牌色 73）落地 + `/theme` 切换命令
- 功能清单文档（cjh功能清单.md）

## [v1.2.0] - 2026-08-23

### Added
- **V2d 并发执行引擎**：DAG 依赖分析（资源访问 `(path, isWrite)` 提取）+ 拓扑分组调度（同组 spawn 并发，组间串行）+ 性能基线三维统计（parallelBatches/parallelSavedMs/maxParallelism）
- **工具效率 P0-P2**：hashline 重设计（行号锚点 `@@N` + 内容验证编辑，借鉴 OMP）
- **V2c 记忆分层**：Compaction 摘要压缩 + AGENTS.md 项目指令加载
- **V2b 插件系统**：Skills 即文件（frontmatter + 声明式工具）+ plugin.json shell 工具插件
- **树形会话 + `--mode json`**：saveFork/parentOf/listTree 树形分支 + 无头 JSON 模式
- **V3b Ollama 本地模型**：复用 OpenAI SSE 协议，本地 HTTP 无 TLS
- Tasks 面板（Agent 任务列表 TUI 实时展示）

### Tests
- 单测扩至 152 全绿（read 边界/grep/glob/hashline/agent DAG+截断端到端/session/skills/utf8 等）

## [v1.1.0] - 2026-08-23

### Added
- 版本徽章 + 标题重命名（"Agent made by Cangjie"）
- TUI 组件补齐：Spinner / ConfirmDialog / MultiLineEditor / TabBar / Box
- compaction 初版 + AGENTS.md 加载 + provider 配置对话框

### Fixed
- 终端尺寸读取（C helper 绕过 FFI ioctl 问题 + stderr/stdin 兜底）
- TUI 审批结束后按键卡死（pendingApproval 残留吞按键）
- truncate CSI 序列处理

## [v1.0.0] - 2026-08-21（无 tag，首个提交）

### Added
- **P0 MVP**：Agent 核心（消息状态机 + 工具调用协议 + 迭代）
- **5 个内置工具**：bash / read_file / write_file / grep / list_dir
- 全屏 TUI（差分渲染 + ANSI + termios 原始模式，纯 libc FFI 自实现）
- OpenAI / Anthropic 双协议 SSE 流式 + 流式累加器
- 配置系统 + 会话持久化（首跑自动生成 auth.json/settings.json 模板）
- cjterm / cjllm / cjcfg 独立库拆分
- 静态编译 + DT_RPATH 内嵌（`./main` 无需 LD_LIBRARY_PATH）
- 非 UTF-8 终端 UI 自动降级 ASCII
