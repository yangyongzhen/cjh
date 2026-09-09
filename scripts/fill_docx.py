# -*- coding: utf-8 -*-
"""填写 cjh 作品提交 docx：保留模板格式，精准插入/重写内容。"""
import zipfile, re, shutil, sys

SRC = 'docs/仓颉生态创新开发挑战赛作品提交.docx'
DST = 'docs/仓颉生态创新开发挑战赛作品提交.docx'  # 原地更新

def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

z = zipfile.ZipFile(SRC)
xml = z.read('word/document.xml').decode('utf-8')
names = z.namelist()
others = {n: z.read(n) for n in names if n != 'word/document.xml'}
z.close()

def para_bounds(xml, key):
    """定位包含 key 文本的 <w:p> 段落，返回 (start, end)。key 须在该段拼接文本中。"""
    # 逐段扫描
    for m in re.finditer(r'<w:p[ >].*?</w:p>', xml, re.S):
        texts = re.findall(r'<w:t[^>]*>(.*?)</w:t>', m.group(0), re.S)
        if key in ''.join(texts):
            return m.start(), m.end()
    raise SystemExit(f'段落未找到: {key[:30]}')

def get_pPr(para):
    m = re.search(r'<w:pPr>.*?</w:pPr>', para, re.S)
    return m.group(0) if m else ''

def get_first_rPr(para):
    m = re.search(r'<w:r>(?:(?!</w:r>).)*?<w:rPr>(.*?)</w:rPr>(?:(?!</w:r>).)*?<w:t', para, re.S)
    return m.group(1) if m else ''

def make_run(text, rPr, bold=True):
    r = rPr or ''
    if bold and '<w:b/>' not in r:
        r = (r + '<w:b/>') if r else '<w:b/>'
        rPr2 = f'<w:rPr>{r}</w:rPr>'
    else:
        rPr2 = f'<w:rPr>{r}</w:rPr>' if r else ''
    return f'<w:r>{rPr2}<w:t xml:space="preserve">{esc(text)}</w:t></w:r>'

def make_para(text, pPr, rPr, bold=True):
    return f'<w:p>{pPr}{make_run(text, rPr, bold)}</w:p>'

def set_para_text(xml, key, new_text):
    s, e = para_bounds(xml, key)
    para = xml[s:e]
    pPr = get_pPr(para)
    rPr = get_first_rPr(para)
    return xml[:s] + f'<w:p>{pPr}{make_run(new_text, rPr, bold=False)}</w:p>' + xml[e:]

def insert_after(xml, key, texts):
    s, e = para_bounds(xml, key)
    para = xml[s:e]
    pPr = get_pPr(para)
    rPr = get_first_rPr(para)
    new = ''.join(make_para(t, pPr, rPr, bold=True) for t in texts)
    return xml[:e] + new + xml[e:]

def fill_table_cell(xml, label, value):
    """在标签为 label 的表格行中，向值单元格（含空 <w:p> 的 w:tc）插入 value。"""
    m = re.search(r'<w:tr[ >].*?</w:tr>', xml, re.S)
    for row_m in re.finditer(r'<w:tr[ >].*?</w:tr>', xml, re.S):
        row = row_m.group(0)
        texts = ''.join(re.findall(r'<w:t[^>]*>(.*?)</w:t>', row, re.S))
        if label not in texts:
            continue
        # 行内所有 tc
        tcs = list(re.finditer(r'<w:tc>.*?</w:tc>', row, re.S))
        if len(tcs) < 2:
            raise SystemExit(f'行 {label} 单元格不足')
        vcell = tcs[1].group(0)
        # 值单元格内的空段落
        pm = re.search(r'<w:p[ >](?:(?!</w:p>).)*?</w:pPr>(?:(?!</w:p>).)*?</w:p>', vcell, re.S)
        if not pm:
            raise SystemExit(f'{label} 值单元格段落未找到')
        p = pm.group(0)
        rPr = ''
        # 用标签单元格的 rPr 作参照
        lcell = tcs[0].group(0)
        lm = re.search(r'<w:rPr>(.*?)</w:rPr>', lcell, re.S)
        if lm:
            rPr = re.sub(r'<w:b/>', '', lm.group(1))
        pPr = re.search(r'<w:pPr>.*?</w:pPr>', p, re.S)
        pPr = pPr.group(0) if pPr else ''
        new_p = f'<w:p>{pPr}{make_run(value, rPr, bold=False)}</w:p>'
        new_row = row[:row.find(p, 0) - row_m.start()] if False else None
        # 替换该行内的该段落
        abs_s = row_m.start() + row.find(p)
        abs_e = abs_s + len(p)
        return xml[:abs_s] + new_p + xml[abs_e:]
    raise SystemExit(f'表格行未找到: {label}')

# ============ 基础信息表 ============
xml = fill_table_cell(xml, '赛事作品名称', 'cjh —— 用仓颉语言实现的终端 AI Coding Agent（含 5 个配套仓颉工具库：cjllm / cjterm / cjutil / cjlog / cjconfig）')

# ============ 作品类型 / 使用环境 勾选 ============
xml = set_para_text(xml, '□ 技术课题 □ 通用工具库',
    '□ 技术课题 □ 通用工具库 □ UI组件库 □ 算法数据库 □ 网络请求库 □ 数据解析库 □ IoT适配库 □ 性能优化库 □ 安全加密库 ☑ 应用框架')
xml = set_para_text(xml, '□ 其他___________\n'[:0] or '□ 其他',
    '☑ 其他：终端 AI Coding Agent（纯仓颉实现的 Agent 应用 + 配套可复用库包生态）')
xml = set_para_text(xml, '□ 仓颉原生环境',
    '☑ 仓颉原生环境 □ 鸿蒙系统适配 ☑ 服务端场景 ☑ 客户端场景 □ 跨端场景')
xml = set_para_text(xml, '□ 其他___________',
    '□ 其他___________')

# ============ 一、项目概述 ============
xml = insert_after(xml, '1. 项目一句话定位', [
    '本作品以 cjh —— 一个完全用仓颉语言实现的终端 AI Coding Agent 为核心，提供一套通用 AI Agent 框架（多轮工具循环、流式对话、任务管理、审批流、插件与 MCP 扩展点、插件信任链）和 5 个可独立复用的仓颉工具库包（cjllm 大模型接入、cjterm 终端渲染、cjlog 异步日志、cjutil 通用工具、cjconfig 配置管理）。面向仓颉开发者构建 AI 工具与 Agent 应用的场景，解决当前仓颉生态缺少现成 AI Agent 框架与终端 UI / LLM 接入库的问题，提供全开源、全测试（369 个单元测试）、可运行的参考实现与一组可直接复用的底层库包。'])
xml = insert_after(xml, '2. 项目开发背景', [
    '仓颉语言生态处于早期，AI 开发方向的三方库基本空白：终端 UI（TUI 渲染/输入）、大模型协议接入（OpenAI 兼容/Anthropic/SSE 流式）、UTF-8 流安全处理、通用日志与配置等基础设施，均无成熟通用仓颉库可用；现有主流 Agent 实现均为 TypeScript / Rust / Python，仓颉开发者自建 Agent 只能从零手写全部基础设施（SSE 解析、工具协议、终端 raw 模式、UTF-8 流解码等）。',
    '在实际研发中，我们踩通并解决了一系列仓颉生态的深层问题：UTF-8 字节边界截断、字节流解码乱码、spawn 任务异常静默死亡、并发锁泄漏、socket 连接无超时导致永久挂起等——全部沉淀为防御性原语（safeFromUtf8 / truncateUtf8 / runWithBudget 等）+ 回归测试，可被其他仓颉项目直接复用。',
    '研发初衷：以「用仓颉实现一个完整 Agent」为实践载体，把通用部分沉淀为 5 个独立库包（独立开源发布：LICENSE、README、examples、CI 齐备），把踩坑经验沉淀为仓颉生态公共资产（配套《仓颉语言开发踩坑记录》文档开源），为生态提供「可读、可跑、可复用」的参考实现。'])
xml = insert_after(xml, '3. 项目核心目标', [
    '基础功能目标（已实现）：① 多轮工具循环（含并行工具批、用户中断、预算超时）；② 12+ 内置工具（文件读写/搜索、Shell 会话、Web 搜索、任务管理、子代理等）+ 插件系统 + MCP 客户端（stdio + JSON-RPC 2.0）；③ 终端 TUI（主题系统、流式渲染、增量行缓存）与 Web 双入口；④ 配置管理、会话管理（含 fork/恢复）、审批流；⑤ 插件信任链（SHA256 校验和 + SM2 国密签名 + 信任列表 CLI，三步全部实现）。',
    '进阶创新目标（已实现）：① 异步并发——工具并行批次、后台异步 compaction（不阻塞主循环）、预算竞速中断（LLM 请求任一阶段不挂死）；② 可靠性——369 单元测试 + mock 端到端门禁，零第三方运行时依赖（纯仓颉标准库/stdx 实现）；③ 生态化——5 个库包独立开源发布（v0.1.0），双平台（Linux/Windows 交叉编译）构建与发布。'])

# ============ 二、需求分析与适用人群 ============
xml = insert_after(xml, '1. 目标用户精准定位', [
    '仓颉语言开发者与团队（构建自有 AI 工具/Agent 产品：直接复用 cjllm/cjterm/cjutil，或以 cjh 为参考实现）；企业内部工具团队（在受控环境构建内部编码助手，代码全开源可审计）；学生与开源贡献者（源码注释完备、可读可学习的完整参考实现，5 个独立发布库包作为生态贡献起点）；终端应用开发者（复用 TUI 渲染/主题/双平台输入能力开发其他终端应用）。'])
xml = insert_after(xml, '2. 行业开发痛点分析', [
    '① 无终端 UI 库：仓颉没有通用 TUI 渲染/输入库，终端应用需手写 termios/raw 模式/屏幕管理，双平台（POSIX/Windows）成本更高；② 无 LLM 接入库：SSE 流式解析、多协议（OpenAI 兼容/Anthropic/Ollama）、token 统计（多协议缓存字段）、429/5xx 重试均需从零手写；③ UTF-8 流处理无标准答案：按字节截断中文抛异常、字节流逐字节解码必乱码、mojibake 修复——全是深坑且无库可复用；④ 无日志/配置/通用工具库：日志级别管理、配置模板兜底、hex/SHA256/SM2 等基础设施散落缺失；⑤ AI 请求挂死无解法：仓颉裸 socket 无 connect 超时（1.0.5 实测），一次挂死=整个 Agent 永久卡死且用户无法中断；⑥ 插件生态无信任机制：第三方脚本插件缺校验和/签名/信任列表闭环，无法安全开放扩展。'])
xml = insert_after(xml, '3. 库解决方案', [
    '① → cjterm：画布式渲染 + 增量行缓存（渲染复杂度从 O(全部行) 降到 O(变化行)）+ 主题系统（内置 6 主题）+ 双平台输入（POSIX termios / Windows 控制台 API，@When 条件编译隔离）；② → cjllm：三协议 provider + SSE 解析器 + token 统计（DeepSeek/Anthropic/OpenAI 嵌套缓存字段全解析）+ 429/5xx 重试 + 乱码整体修复（MojibakeFix）；③ → cjutil：safeFromUtf8（非法字节容错 U+FFFD 不抛异常）/ truncateUtf8（字符边界回退截断）/ mojibake 修复，配中文样本全覆盖单测矩阵；④ → cjlog（异步分级日志）/ cjconfig（配置管理 + 模板兜底）/ cjutil（hex、SHA256、字符串安全工具）；⑤ → runWithBudget 预算竞速原语（下沉传输层：connect/write/read 全有界可中断，新协议复用传输层即天然继承）；⑥ → 信任链三步：SHA256 目录校验和（Step 1）+ SM2 国密签名验证（Step 2，stdx.crypto 原生、零外部依赖）+ 信任列表 CLI（Step 3，cjh trust/untrust/trust-list，空列表开放模式/非空严格模式）。'])

# ============ 三、核心能力 ============
xml = set_para_text(xml, '（1）能力一：',
    '（1）能力一：Agent 多轮工具循环（Agent Loop）。功能介绍：LLM→工具调用→结果反馈的完整多轮对话循环，支持并行工具批次（同轮独立只读工具并发执行）、用户中断（Ctrl+C 优雅退出当前轮）、预算超时（单轮/单请求有界）、后台异步 compaction（长会话自动摘要换装，不阻塞主循环）、超长输出截断与自动续写。适用开发场景：任意 AI 助手、编码 Agent、自动化任务编排。调用方式简述：Agent(provider, toolRegistry, config).run(prompt)，流式/任务变更/回合结束均回调驱动（onDelta/onTodosChanged/onRunComplete）。实现效果与价值：稳定支撑数十轮长会话，回合级统计（token 用量/缓存命中率/耗时）实时展示，全部行为被单元测试锁定，--mock 模式可离线验证完整工具链。')
xml = set_para_text(xml, '（2）能力二：',
    '（2）能力二：终端 TUI 渲染与输入。功能介绍：画布式终端渲染引擎、增量行缓存（只重绘变化行）、内置主题系统（starfrost/classic/dracula 等 6 主题、按主题变色的输入框边框）、流式文本渲染、双平台输入（含 bracketed paste、UTF-8 中文输入、快捷键体系）。适用开发场景：需要高密度信息展示的终端应用（编码助手、运维工具、数据看板）。调用方式简述：cjterm 库（渲染/主题/输入）+ TuiApp 事件循环；平台差异代码用 @When[os == "Windows"] 条件编译隔离，业务代码零平台分支。实现效果与价值：长会话（数十轮/数千行输出）渲染与输入流畅，双平台经交叉编译 + strings 符号级验证（Windows 产物无 termios 符号、Linux 产物无 GetConsoleMode 符号）。')
xml = set_para_text(xml, '（1）创新点一：',
    '（1）创新点一：UTF-8 安全流处理体系。创新详情：字符边界安全截断（truncateUtf8/tailUtf8，切点回退到最近合法边界、绝不抛异常）、字节流按字符边界解码（safeFromUtf8 + 跨块 pending 字节累积）、mojibake 整体修复（MojibakeFix 识别「字节被当作独立码点」类乱码并整段还原）——三者构成覆盖「取/切/拼/数」全场景的防御体系，配中文样本全覆盖单测（ASCII 全过 ≠ 中文对，测试必须含中文）。相较同类仓颉库的核心优势：现有仓颉库中无系统解决流式 UTF-8 问题的方案，该体系已抽为 cjutil 独立包可被任何仓颉项目直接复用，配套踩坑记录文档（26 条坑 + 排查方法论）开源，是可直接取用的生态公共资产。')
xml = set_para_text(xml, '（2）创新点二：',
    '（2）创新点二：可靠性工程——预算竞速中断 + 后台异步 compaction。创新详情：runWithBudget 原语以 spawn 子任务执行 + 主线程轮询预算（超时抛明确异常、可接收用户取消检查器），LLM 请求的 connect/写/读三阶段全有界（实测：裸 connect 挂死 442s 不可中断 → 预算化后 2s 内可中断），且原语下沉到传输层内部，新协议复用传输层即天然有界可中断；compaction 在轮末按真实 usage.promptTokens 触发后台摘要（读快照 spawn，不阻塞主循环），下一轮请求前换装或顺延，失败静默重试再回退同步路径。相较同类仓颉库的核心优势：解决了 AI 应用「单次请求挂死=全系统冻结」这一普遍可靠性难题，异步 compaction 保证长会话下主循环始终流畅，两者均为仓颉生态内的原创实现。')

# ============ 四、仓颉特性应用 ============
xml = set_para_text(xml, '1. 应用仓颉特性1：',
    '1. 应用仓颉特性1：静态类型系统与 Option/match 模式。技术实现与封装逻辑：全程无 null 指针，统一 Option<T> + Some/None（JSON 字段取值 if (let Some(v) <- obj.get(k))）；JSON 形态判断用 match (v.kind()) 穷举（JsonKind.JsString/JsObject/...）；信任操作结果建模为枚举（TrustResult：Added/AlreadyTrusted/Removed/NotTrusted/EmptyEntry），调用方 match 穷举处理。落地优势与效果：从编译器层面消灭空指针与形态判断遗漏两类错误；每个枚举分支都有对应单测，行为可锁定、可回归。')
xml = set_para_text(xml, '2. 应用仓颉特性2：',
    '2. 应用仓颉特性2：异步并发（spawn / Mutex / 结构化任务）。技术实现与封装逻辑：Agent 执行（主线程渲染 + agent 线程流式回调）、并行工具批次、后台 compaction 摘要均用 spawn 任务；共享状态（输出视图/审批态/任务列表）由 Mutex 保护，全部 lock() 采用 try/finally 守护模式（临界区抛异常不泄漏锁）；跨线程取消用标志位（主线程设置、agent 线程轮询）。落地优势与效果：「主循环渲染 + 流式回调 + 后台摘要」多任务并发长期稳定运行，锁泄漏、僵尸进程等并发缺陷全部有回归测试锁定（含 gdb 停摆现场的定性方法论沉淀）。')
xml = set_para_text(xml, '3. 应用仓颉特性3：',
    '3. 应用仓颉特性3：模块化包系统 + 回调注入。技术实现与封装逻辑：全工程组织为 6 个独立包（cjh 主体 + cjlog/cjconfig/cjutil/cjterm/cjllm），依赖严格单向（底层 cjutil/cjlog → 中层 cjterm/cjllm/cjconfig → 主体 cjh）；循环依赖用回调注入解决而非移包——如 TodoWriteTool 留在 tools 包，通过函数回调操作 agent 的任务列表，避免 tools ↔ agent 循环；FFI 用 foreign 顶层声明 + 类内静态方法包装（termios/Windows 控制台互操作）。落地优势与效果：每包单一职责、可独立编译/测试/发布（5 个库包已独立开源发布 v0.1.0），满足生态复用粒度；包边界即文档，新人可读包名即懂架构。')
xml = insert_after(xml, '开发技术栈与工具：明确填写开发语言', [
    '开发语言：仓颉 Cangjie（1.0.5，stdx 1.0.5.1）；开发工具：cjpm（包管理/构建/测试，source /opt/cangjie/cangjie/envsetup.sh 加载工具链）；编译环境：Linux x86_64（主开发）+ x86_64-pc-windows-gnu（交叉编译）；适配系统版本：Linux x86_64 / Windows x86_64；第三方依赖：零第三方运行时依赖——全部由仓颉标准库与 stdx 实现（含 SM2 国密、SHA256、HTTP 流式传输等，SM2 走 stdx.crypto.keys 原生实现）；测试工具：仓颉内置测试框架（@Test/@TestCase/@Assert）+ 伪终端 TUI 测试脚本（python 驱动 14 场景）+ --mock 离线端到端门禁。'])

# ============ 五、性能与兼容性 ============
xml = insert_after(xml, '1. 性能优化设计', [
    '① 渲染性能：P2 增量行缓存（OutputView.cachedLines 增量维护，与全量 split 等价性有专项单测锁定），渲染复杂度从 O(全部行) 降到 O(变化行)，长会话无卡顿无闪屏；② 吞吐：并行工具批次（同轮独立只读工具并发 spawn）、后台异步 compaction（摘要与主对话并行，主循环零阻塞，实测触发→应用延迟可控）；③ 连接：传输层连接复用 + 全阶段预算超时（挂起连接被及时释放，不再占资源）；④ 部署：静态链接单文件二进制（双平台发布包），无运行时环境依赖、冷启动快；⑤ 内存：超大工具结果截断阈值保护（bash 2000/list_dir 4000 字符）+ 完整内容落盘可回溯，避免大 buffer 常驻。'])
xml = insert_after(xml, '2. 兼容性设计', [
    '仓颉语言版本：1.0.5（cjpm.toml cjc-version 锁定，API 面经真实项目验证）；操作系统：Linux x86_64（主平台）+ Windows x86_64（x86_64-pc-windows-gnu 交叉编译）；平台差异用 @When[os == "..."] 内置条件编译隔离（POSIX termios 后端 / Windows 控制台 API 后端互斥编入），交叉编译后用 strings 符号级验证平台后端确实被排除（Windows 产物无 tcgetattr/termios、Linux 产物无 GetConsoleMode/ReadConsoleInputW）；配置全部置于 ~/.cjh/settings.json（支持 provider/model/主题/压缩阈值等），关键路径支持环境变量覆盖（CJH_CONFIG_DIR 等）；无特定发行版系统级依赖（仅 bash、标准 libc 能力）。'])
xml = insert_after(xml, '3. 稳定性与容错设计', [
    '① 异常捕获：关键路径全兜底——spawn 任务闭包不裸奔（收尾关键路径必 try/catch，关键实参先 let 接住再进 try）、Mutex 临界区全部 try/finally 守护（泄漏锁=全停摆，已沉淀审计法）、主事件循环单帧异常不得终止循环（终端 raw 恢复放 finally）；② 容错解码：非法 UTF-8 字节转 U+FFFD 不抛异常、JSON 数值字段兼容 Int/Float/String 三形态、异常结构字段（如 prompt_tokens_details 非对象）容错不抛；③ 参数校验：工具层输入校验（路径/命令白名单）+ 输出截断保护 + 超长 LLM 工具参数 JSON 截断修复（repairTruncatedJson 优先闭合被截断字符串）；④ 进程治理：退出路径显式回收子进程（terminate 后必 wait，僵尸回收有测试观测器），Log/MCP/Shell 会话独立 try/catch 关闭；⑤ 测试门禁：369 单元测试 + TUI 伪终端 14 场景 + --mock 端到端，bug 修复必须先写红测试再修复（红绿流程），杜绝回归。'])

# ============ 六、使用说明 ============
xml = insert_after(xml, '1. 快速接入说明', [
    '整应用接入：git clone https://gitcode.com/qq8864/cjh.git && cd cjh；source /opt/cangjie/cangjie/envsetup.sh；cjpm build；./target/release/bin/cjh（首运行引导配置 provider 与 model）。库包接入（任意仓颉项目）：在 cjpm.toml 加 git tag 依赖即可（例：cjllm = { git = "https://gitcode.com/qq8864/cjllm.git", tag = "v0.1.0" }），无需本地 path 依赖、零第三方运行时依赖、纯 stdx 实现。离线验证：./target/release/bin/cjh --mock（无需网络与密钥，自动跑通 read_file+grep 并行→grep→list_dir→最终答复的完整工具链）。'])
xml = insert_after(xml, '2. 落地应用场景', [
    '① 自建 AI 编码助手/Agent：以 cjh 为参考实现或直接复用 cjllm（LLM 接入）+ cjterm（终端 UI）+ cjutil（通用工具）；② 终端 AI 运维助手/数据看板：复用 TUI 渲染 + 主题 + LLM 流式接入；③ 插件/MCP 扩展自定义能力：第三方脚本插件（工具插件 + 钩子插件）与 MCP stdio 工具，已提供示例插件与信任链（校验和+SM2 签名+信任列表）支撑安全开放扩展；④ 仓颉生态学习与实训：源码注释完备（关键文件注释密度 15%–26%）、369 个单测与踩坑记录文档可作学习材料，5 个独立发布库包可作生态贡献起点；⑤ 受控环境内部工具：零第三方运行时依赖、代码全开源可审计，适合对依赖链有管控要求的企业场景。'])
xml = insert_after(xml, '3. 核心价值', [
    '开发价值：Agent 循环、LLM 接入、TUI 渲染、UTF-8 安全、日志配置等通用能力全部库化封装，仓颉开发者无需重复造轮子；参考实现源码注释完备、可读可学习，显著降低仓颉 AI 开发门槛。生态价值：5 个库包独立开源发布（LICENSE + README + 发布指南 + examples + CI），补齐仓颉生态 AI/终端领域的三方库品类空白；《仓颉语言开发踩坑记录》（26 条实战坑 + 排查方法论）将语言真实经验沉淀为生态资产。创新价值：预算竞速中断、后台异步 compaction、插件信任链（SM2 国密走 stdx.crypto 原生、零外部依赖）均为 Agent 领域共性问题的仓颉原创解法，为生态后续 AI 工具开发提供可参照的实现范式。'])

# ============ 七、可行性 ============
xml = insert_after(xml, '1. 技术可行性', [
    '全部功能已稳定落地运行：当前版本 v1.3.15，历经 28 轮迭代开发，369 单元测试 + build + --mock 端到端门禁全绿（FAILED: 0 / ERROR: 0）；代码统一工程规范（6 包单向依赖、回调注入解循环依赖）、注释完备（关键文件注释密度 15%–26%）、逻辑清晰可复用；零第三方运行时依赖（纯仓颉标准库/stdx），无技术壁垒，构建产物双平台可复现。'])
xml = insert_after(xml, '2. 落地可行性', [
    '主体工程与 5 个库包均已开源（gitcode 公开仓库），库包按 git tag 独立发布（v0.1.0），任何仓颉项目可一行依赖直接引用；文档体系完整（中英双 README、开发文档与踩坑记录、插件签名与贡献指南、进度记录、发布指南）；具备长期迭代与生态推广价值：有明确路线图（连接池、IM 网关、插件 WASM + 中心仓）、版本号规则（重大递增中间位/小更新递增最后位）与发版流程（版本号三处同步 + tag + 双远端推送）。'])
xml = insert_after(xml, '3. 开发进度规划', [
    '已完成：核心功能（Agent 循环/TUI/12+ 工具/插件/MCP/信任链/异步 compaction/双平台）开发与调试完毕，性能优化（增量行缓存/预算超时/并行批次）落地，文档与测试门禁全部交付，当前 v1.3.15 已发版（tag + 双远端）。后续计划：P3 传输层连接池 1→N（多协议并发提速）；V2e IM 渠道网关（Channel 抽象接入聊天渠道）；V2b 插件 WASM 沙箱与中心仓；单轮 completion 瓶颈中期优化（快模型验证 + 请求批量化）；按生态反馈持续补全库包能力并按版本号规则持续发版。'])

# ============ 八、总结与展望 ============
xml = insert_after(xml, '1. 项目总结', [
    'cjh 是纯仓颉语言实现的终端 AI Coding Agent（含 5 个配套库包，约 5.5 万行仓颉代码、369 个单元测试、Linux/Windows 双平台）。核心能力：多轮工具循环（并行/中断/预算超时）、12+ 内置工具 + 插件 + MCP 扩展、TUI 渲染（增量行缓存/主题系统）、后台异步 compaction、插件信任链（SHA256 校验和 + SM2 国密签名 + 信任列表 CLI 三步闭环）。技术优势：零第三方运行时依赖（纯标准库/stdx，SM2 走 stdx.crypto 原生）、UTF-8 安全流处理体系、预算竞速中断（请求全阶段不挂死）、模块化包架构（单向依赖 + 回调注入）。解决的核心痛点：仓颉生态缺 AI Agent 框架、缺终端 UI 库、缺 LLM 接入库、缺流式 UTF-8 安全方案。参赛亮点：完整的仓颉 Agent 参考实现（双平台、全测试、全文档、可读可学习）；5 个独立发布的可复用库包（生态即插即用）；开源的《仓颉语言开发踩坑记录》作为生态公共资产。'])
xml = insert_after(xml, '2. 未来展望', [
    '① 性能：传输层连接池 1→N（host:port 键多槽，主+摘要 provider 交替省建连）、单轮 completion 瓶颈优化（快模型验证 + 请求批量化）；② 生态：推动库包进入仓颉官方仓库收录、适配鸿蒙生态工具链、插件 WASM 沙箱与中心仓（V2b Step 3）；③ 功能：IM 渠道网关（V2e Channel）、多代理协作深化、记忆系统（项目记忆/压缩摘要）增强；④ 文档与推广：持续更新中英双语文档、补充更多示例工程与插件示例、通过技术社区持续开源推广；⑤ 兼容性：跟踪仓颉 1.x 新版本演进、扩展更多平台（ARM、鸿蒙端）。'])

# ============ 九、AI 生态贡献加分申请 ============
xml = set_para_text(xml, '申请情况（必选）',
    '申请情况（必选）：□ 不申请仓颉AI生态贡献加分  ☑ 申请仓颉AI生态贡献加分')
xml = set_para_text(xml, '贡献成果名称：',
    '贡献成果名称：cjh 仓颉 AI Coding Agent 及配套仓颉库包生态（cjllm / cjterm / cjutil / cjlog / cjconfig）')
xml = set_para_text(xml, '贡献类型：',
    '贡献类型：☑ 工具  □ Skill  ☑ Agent  ☑ MCP工具  □ 工作流  □ 提示模板  □ 语料  ☑ 示例  □ 其他')
xml = set_para_text(xml, '解决的问题、目标用户与适用场景：',
    '解决的问题、目标用户与适用场景：解决仓颉生态缺少 AI Agent 框架、LLM 接入库、终端 UI 库的问题（详见第二、三部分），并把仓颉 UTF-8 流安全、并发挂起、socket 无超时、插件信任等实战深坑沉淀为可复用解法与开源文档；目标用户为仓颉语言开发者与构建 AI 工具/Agent 的团队；适用于 AI Agent、终端工具、LLM 应用的开发场景。')
xml = set_para_text(xml, '与仓颉开发、仓颉AI生态及参赛作品的关系：',
    '与仓颉开发、仓颉AI生态及参赛作品的关系：参赛作品本身即为仓颉 AI 生态贡献——cjh 是纯仓颉完整可运行的 AI Agent（内置 MCP 客户端与插件扩展点，任何仓颉项目可复用其 Agent 框架与 5 个库包）；开发过程沉淀的 Agent 循环、工具协议、SSE 流式、信任链实现与《仓颉语言开发踩坑记录》均为开源的仓颉 AI 开发示例与经验资产，与参赛作品同源、同仓。')
xml = set_para_text(xml, '贡献代码仓库或PR链接：',
    '贡献代码仓库或PR链接：https://gitcode.com/qq8864/cjh（主体工程 + 5 库包 + 示例 + 测试 + 文档）；库包独立仓库：https://gitcode.com/qq8864/cjllm 、https://gitcode.com/qq8864/cjterm 、https://gitcode.com/qq8864/cjutil 、https://gitcode.com/qq8864/cjlog 、https://gitcode.com/qq8864/cjconfig（均已打 v0.1.0 tag）。')
xml = set_para_text(xml, '安装或配置方式：',
    '安装或配置方式：git clone https://gitcode.com/qq8864/cjh.git && cd cjh；source /opt/cangjie/cangjie/envsetup.sh（仓颉 1.0.5 工具链）；cjpm build（零第三方运行时依赖，标准库/stdx 直接编译）。库包复用：在任意仓颉项目 cjpm.toml 加 git tag 依赖（例：cjllm = { git = "https://gitcode.com/qq8864/cjllm.git", tag = "v0.1.0" }）。真实对话仅需在 ~/.cjh/settings.json 配置 provider 与 model。')
xml = set_para_text(xml, '运行、调用或复用步骤：',
    '运行、调用或复用步骤：① 离线验证（无需网络/密钥）：./target/release/bin/cjh --mock，自动执行 read_file+grep 并行 → grep → list_dir → 最终答复的完整工具链；② 真实对话：配置 provider/model 后 ./target/release/bin/cjh，TUI 交互（多轮工具调用/审批/任务面板/回合统计）；③ 插件扩展：参照 example/plugins/（signed-demo 签名插件、git-status 工具插件、tool-result-banner 钩子插件）放置 plugin.json + 脚本，cjh trust/untrust/trust-list 管理信任列表；④ 测试门禁：./scripts/test.sh（根包 335 用例）+ cd libs/cjllm && cjpm test（34 用例）+ python3 scripts/tui_pty_test.py（14 个伪终端 TUI 场景）。')
xml = set_para_text(xml, '核心示例及预期结果：',
    '核心示例及预期结果：示例 1：cjh --mock → 预期输出「✅ 验证通过：工具调用链完整（read_file+grep 并行 → grep → list_dir → 最终答复）」；示例 2：cjh trust github:alice → 预期输出「已信任: github:alice」，此后严格模式仅加载受信任发布者的签名插件（信任链三步闭环）；示例 3：在任意仓颉项目引用 cjllm v0.1.0，用 OpenAiProvider 完成 SSE 流式对话与工具调用（库包 examples 目录有可运行示例）。')
xml = set_para_text(xml, '测试结果、运行截图或演示视频等材料路径/链接：',
    '测试结果、运行截图或演示视频等材料路径/链接：均在仓库内可复现——scripts/test.sh（一键全量测试门禁，根包 335 用例 FAILED: 0 / ERROR: 0）；python3 scripts/tui_pty_test.py（14 个伪终端 TUI 场景：启动/输入/补全/帮助/审批同意与拒绝等）；src/tests/ 与 libs/*/src/*_test.cj（测试源码）；docs/进度记录.md（28 轮开发记录、各版本测试数据与事故排查记录）；docs/仓颉语言开发踩坑记录.md（26 条实战坑 + 排查方法论）；发版 tag v1.3.15 可直接 checkout 复现全部结果。')
xml = set_para_text(xml, '代码、文档、示例及必要测试材料完整性说明：',
    '代码、文档、示例及必要测试材料完整性说明：代码完整（全部源码 + cjpm 构建配置 + CI 工作流，无遗漏文件）；文档完整（中英双 README、开发文档与踩坑记录、插件签名与贡献指南、进度记录、发布指南、仓颉语言开发踩坑记录）；示例完整（example/plugins/ 共 4 个插件覆盖工具/钩子/签名三类，各库包 examples/ 有独立可运行示例）；测试完整（369 单元测试 + TUI 伪终端测试 + --mock 端到端门禁，仓库内一键复现）；无敏感信息（全部测试密钥/账号均为 mock，配置示例不含真实密钥，已按要求脱敏）。')
xml = set_para_text(xml, '真实性确认：',
    '真实性确认：☑ 贡献成果与仓颉生态相关  ☑ 成果能够安装、运行或复用  ☑ 所提交代码与材料真实、完整、可核验')

# ============ 十、补充说明 ============
xml = insert_after(xml, '可补充作品功能架构图', [
    '补充材料（均在仓库内，路径可直接核验）：架构与设计 → docs/开发文档与踩坑记录.md（各子系统设计与事故排查全过程）；性能优化记录 → docs/进度记录.md（P2 增量行缓存/预算超时/异步 compaction/连接池规划及各版本测试数据）；测试报告 → scripts/test.sh 运行输出（根包 335 用例全绿 + cjllm 34 用例 + TUI 伪终端 14 场景）；代码结构 → 6 包架构（cjh 主体 + cjlog/cjconfig/cjutil/cjterm/cjllm，单向依赖），见 libs/README.md；插件生态 → docs/插件签名与贡献指南.md（信任链三步 + 签名流程 + 贡献指引）；生态贡献 → docs/仓颉AI生态贡献沉淀.md 与 docs/仓颉语言开发踩坑记录.md。'])

# ============ 写回 ============
out = {}
for n, b in others.items():
    out[n] = b
out['word/document.xml'] = xml.encode('utf-8')
with zipfile.ZipFile(DST, 'w', zipfile.ZIP_DEFLATED) as zo:
    for n in names:
        zo.writestr(n, out[n])
print('OK: 已写入', DST)
