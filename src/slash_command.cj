package cjh

/**
 * TUI 斜杠命令分发（/help /new /resume /model /settings /skills /compact
 * /tree /fork /task /theme /provider /quit）
 *
 * 从 main.cj 抽出，降低单文件体积。所有函数都在 package cjh 内，跨文件调用无障碍。
 */

import std.collection.*
import std.convert.Parsable
import std.fs.*
import std.io.*
import cjh.agent.*
import cjh.tui.*
import cjterm.*
import cjcfg.*
import cjutil.*

/**
 * TUI slash 命令分发（对齐 pi 基础命令：/help /new /resume /quit /model /settings）
 */
func handleSlashCommand(input: String, agent: Agent, store: SessionStore, tui: TuiApp, cfg: CjhConfig): Unit {
    let cmd = input.trimAscii().split(" ", -1)[0]
    let args = input.trimAscii()
    match (cmd) {
        case "/help" =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用命令：" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /help          显示本帮助" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /new           开始新会话" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /resume [id]   恢复历史会话（无 id 时列出）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /model [id|#]  列出/切换模型" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /provider [name] [key]  切换 provider（deepseek/openai/glm/qwen/kimi/doubao/siliconflow/ollama；无参弹窗可配 custom 自定义端点+协议）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /skills        列出技能与启用状态" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /compact       手动压缩历史（LLM 摘要早期消息）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /tree          树形列示会话分支" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /fork          从当前会话分支新会话" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /settings      查看采样参数（temp/max_tokens）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /task          任务管理（add/done/doing/clear/list）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /theme [name] TUI 主题切换（starfrost|classic）" + Ansi.reset())
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  /quit          退出" + Ansi.reset())
        case "/provider" =>
            // provider 预设切换：/provider [name] [api_key]
            // name ∈ deepseek|openai|glm（预设 base_url+model，写回 settings.json）
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                let name = parts[1]
                var key = if (parts.size > 2) { parts[2] } else { "" }
                match (name) {
                    case "deepseek" =>
                        applyProvider(cfg, agent, tui, "DeepSeek", "https://api.deepseek.com/v1/chat/completions", "deepseek-chat", key, "openai")
                    case "openai" =>
                        applyProvider(cfg, agent, tui, "OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini", key, "openai")
                    case "glm" =>
                        applyProvider(cfg, agent, tui, "GLM", "https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash", key, "openai")
                    case "qwen" =>
                        applyProvider(cfg, agent, tui, "Qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", key, "openai")
                    case "kimi" =>
                        applyProvider(cfg, agent, tui, "Kimi", "https://api.moonshot.cn/v1", "moonshot-v1-8k", key, "openai")
                    case "doubao" =>
                        applyProvider(cfg, agent, tui, "Doubao", "https://ark.cn-beijing.volces.com/api/v3", "doubao-1-5-pro-32k-250115", key, "openai")
                    case "siliconflow" =>
                        applyProvider(cfg, agent, tui, "SiliconFlow", "https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3", key, "openai")
                    case "ollama" =>
                        // 本地 Ollama：无需 API Key，默认 llama3.2 模型
                        // 用法：/provider ollama [model] [api_key]
                        var ollamaModel = "llama3.2"
                        // key 当前 = parts[2]；若 parts[2] 像 model 名则视为 model，
                        // parts[3] 才是 apiKey。简化：parts[2] 存在 → model；parts[3] 存在 → apiKey
                        if (parts.size > 2 && parts[2].size > 0) {
                            ollamaModel = parts[2]
                            key = if (parts.size > 3) { parts[3] } else { "" }
                        } else {
                            key = ""
                        }
                        applyProvider(cfg, agent, tui, "Ollama", "http://localhost:11434/v1", ollamaModel, key, "openai")
                    case _ =>
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知 provider: ${name}；/provider 查看预设列表]" + Ansi.reset())
                }
            } else {
                // 无参数：弹出 provider 配置表单（参考 omp sign-in 弹窗）
                tui.showProviderDialog(cfg.baseUrl, cfg.model, cfg.apiKey, cfg.providerProtocol)
            }
        case "/model" =>
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                // /model <id|#n>：切换模型
                var target = parts[1]
                var idx: Int64 = -1
                // 支持 "#序号" 形式
                if (target.startsWith("#") && target.size > 1) {
                    try {
                        idx = Int64.parse(target[1..target.size])
                    } catch (e: Exception) {
                        idx = -1
                    }
                } else if (cfg.models.size > 0) {
                    // 按 id 匹配
                    for (i in 0..cfg.models.size) {
                        if (cfg.models[i].id == target) {
                            idx = i
                            break
                        }
                    }
                }
                if (idx >= 0 && idx < cfg.models.size) {
                    let entry = cfg.models[idx]
                    cfg.model = entry.id
                    if (entry.baseUrl.size > 0) {
                        cfg.baseUrl = entry.baseUrl
                    }
                    if (entry.apiKey.size > 0) {
                        cfg.apiKey = entry.apiKey
                    }
                    cfg.temperature = entry.temperature
                    cfg.maxTokens = entry.maxTokens
                    let mname = if (entry.name.size > 0) { entry.name } else { entry.id }
                    tui.setModel(mname)
                    // 重建 provider 并热切换（历史保留）
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已切换模型: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[切换模型失败: ${e}]" + Ansi.reset())
                    }
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知模型: ${target}；/model 查看列表]" + Ansi.reset())
                }
            } else {
                // 列出模型
                if (cfg.models.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[未配置 models 列表；当前: ${cfg.model} (temp=${cfg.temperature})]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "可用模型（/model <id|#序号> 切换）：" + Ansi.reset())
                    for (i in 0..cfg.models.size) {
                        let m = cfg.models[i]
                        let label = if (m.name.size > 0) { m.name } else { m.id }
                        let cur = if (m.id == cfg.model) { " ◀" } else { "" }
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  #${i} ${label} (${m.id})${cur}" + Ansi.reset())
                    }
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "当前: ${cfg.model} (temp=${cfg.temperature}, max_tokens=${cfg.maxTokens})" + Ansi.reset())
                }
            }
        case "/settings" =>
            // 查看/调整采样参数：/settings 或 /settings temp 0.9 /settings max_tokens 8192
            let parts = args.split(" ", -1)
            if (parts.size == 3 && parts[1] == "temp") {
                try {
                    cfg.temperature = Float64.parse(parts[2])
                    // 重建 provider 应用新参数
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[temperature = ${cfg.temperature}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else if (parts.size == 3 && parts[1] == "max_tokens") {
                try {
                    cfg.maxTokens = Int64.parse(parts[2])
                    try {
                        let np = makeProvider(cfg)
                        agent.setProvider(np)
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[max_tokens = ${cfg.maxTokens}]" + Ansi.reset())
                    } catch (e: Exception) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[应用失败: ${e}]" + Ansi.reset())
                    }
                } catch (e: Exception) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[无效数值: ${parts[2]}]" + Ansi.reset())
                }
            } else {
                tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "采样参数（/settings temp 0.9 或 /settings max_tokens 8192 调整）：" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  model       ${cfg.model}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  temperature ${cfg.temperature}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  max_tokens  ${cfg.maxTokens}" + Ansi.reset())
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "  base_url    ${cfg.baseUrl}" + Ansi.reset())
            }
        case "/new" =>
            // 清空会话：重开 agent 历史（保留 system）
            let history = agent.history()
            while (history.size > 1) {
                history.remove(history.size - 1..history.size)
            }
            // 清理当前会话的落盘文件（工具结果截断 spill）
            if (SessionState.current.size > 0) {
                let spillSessionDir = cfg.spillDir + "/" + SessionState.current
                try {
                    removeIfExists(spillSessionDir)
                } catch (e: Exception) {
                    // 清理失败不阻塞新会话
                }
            }
            SessionState.current = ""
            tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[新会话]" + Ansi.reset())
        case "/skills" =>
            // 列示技能（~/.cjh/skills/<name>.md）与启用状态
            listSkills(cfg.skillsDir, cfg.enabledSkills, tui)
        case "/compact" =>
            // 手动触发 Compaction：强制把早期历史压成 LLM 摘要
            // 无视 compactThreshold 阈值；compact_keep 仍生效
            tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "[压缩历史中…]" + Ansi.reset())
            spawn {
                let (done, before, after) = agent.compact(true)
                if (done) {
                    TuiBridge.output(Ansi.fg(Ansi.THEME_OK) +
                        "[历史已压缩：${before} → ${after} 条消息]" + Ansi.reset())
                } else {
                    TuiBridge.output(Ansi.fg(Ansi.THEME_MUTED) +
                        "[历史较短，无需压缩（${before} 条）]" + Ansi.reset())
                }
            }
        case "/task" =>
            // /task add <content> | /task done <id> | /task doing <id> | /task rm <id> | /task clear | /task list
            let parts = args.split(" ", -1)
            if (parts.size < 2) {
                // 无参数：列出当前任务
                let todos = agent.getTodos()
                if (todos.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无任务]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "Tasks:" + Ansi.reset())
                    for (item in todos) {
                        let marker = match (item.status) {
                            case TodoStatus.Completed => "✓"
                            case TodoStatus.InProgress => "▶"
                            case TodoStatus.Pending => "☐"
                        }
                        let color = match (item.status) {
                            case TodoStatus.Completed => Ansi.fg(Ansi.THEME_OK)
                            case TodoStatus.InProgress => Ansi.fg(Ansi.THEME_WARN)
                            case TodoStatus.Pending => Ansi.fg(Ansi.THEME_MUTED)
                        }
                        tui.appendOutput(color + "  ${marker} #${item.id} ${item.content}" + Ansi.reset())
                    }
                }
            } else {
                let sub = parts[1]
                match (sub) {
                    case "add" =>
                        // /task add <content...>
                        if (parts.size > 2) {
                            var content = ""
                            for (i in 2..parts.size) {
                                if (content.size > 0) { content += " " }
                                content += parts[i]
                            }
                            let id = agent.addTask(content)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已添加任务 #${id}: ${content}]" + Ansi.reset())
                        } else {
                            tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "用法: /task add <内容>" + Ansi.reset())
                        }
                    case "done" =>
                        // /task done <id>
                        if (parts.size > 2) {
                            let id = Int64.parse(parts[2])
                            agent.updateTaskStatus(id, TodoStatus.Completed)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[任务 #${id} → completed]" + Ansi.reset())
                        }
                    case "doing" =>
                        // /task doing <id>
                        if (parts.size > 2) {
                            let id = Int64.parse(parts[2])
                            agent.updateTaskStatus(id, TodoStatus.InProgress)
                            tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[任务 #${id} → in_progress]" + Ansi.reset())
                        }
                    case "clear" =>
                        agent.clearTodos()
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[已清空任务列表]" + Ansi.reset())
                    case "list" =>
                        let todos = agent.getTodos()
                        if (todos.size == 0) {
                            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无任务]" + Ansi.reset())
                        } else {
                            for (item in todos) {
                                let marker = match (item.status) {
                                    case TodoStatus.Completed => "✓"
                                    case TodoStatus.InProgress => "▶"
                                    case TodoStatus.Pending => "☐"
                                }
                                tui.appendOutput("  ${marker} #${item.id} ${item.content}")
                            }
                        }
                    case _ =>
                        tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[未知子命令: ${sub}；支持 add/done/doing/clear/list]" + Ansi.reset())
                }
            }
        case "/resume" =>
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                // /resume <id>：恢复指定会话
                let id = parts[1]
                let history = store.load(id)
                if (history.size > 0) {
                    // 清空当前历史后载入（保留 system）
                    let cur = agent.history()
                    while (cur.size > 1) {
                        cur.remove(cur.size - 1..cur.size)
                    }
                    agent.loadHistory(history)
                    SessionState.current = id
                    tui.appendOutput(Ansi.fg(Ansi.THEME_WARN) + "[resumed ${id} (${history.size} msgs)]" + Ansi.reset())
                } else {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "[会话 ${id} 不存在]" + Ansi.reset())
                }
            } else {
                // 列出会话
                let sessions = store.list()
                if (sessions.size == 0) {
                    tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无会话]" + Ansi.reset())
                } else {
                    // 进入交互式会话选择模式（上下箭头切换，Enter 恢复，Esc 取消）
                    tui.showSessionList(sessions)
                }
            }
        case "/tree" =>
            // 树形会话列示：按 parent 链展示分支（pi /tree 能力）
            let nodes = store.listTree()
            if (nodes.size == 0) {
                tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[暂无会话]" + Ansi.reset())
            } else {
                tui.appendOutput(Ansi.fg(Ansi.THEME_ACCENT) + "会话树（/resume <id> 恢复，/fork 从当前分支）：" + Ansi.reset())
                // 标记有子会话的节点（作为分支点）
                var childCount = HashMap<String, Int64>()
                for ((id, _, parent) in nodes) {
                    if (parent.size > 0) {
                        childCount.add(parent, (childCount.get(parent) ?? 0) + 1)
                    }
                }
                for ((id, summary, parent) in nodes) {
                    let depth = depthOf(id, store)
                    var indent = ""
                    for (_ in 0..depth) {
                        indent += "  "
                    }
                    let isFork = if (parent.size > 0) { " ↳" } else { "" }
                    let hasChild = if ((childCount.get(id) ?? 0) > 0) { " ◆" } else { "" }
                    var line = "  ${indent}${isFork} ${id}${hasChild}"
                    if (summary.size > 0) {
                        line += "  |  ${summary}"
                    }
                    if (SessionState.current == id) {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + line + Ansi.reset() + Ansi.fg(Ansi.THEME_MUTED) + " ◀" + Ansi.reset())
                    } else {
                        tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + line + Ansi.reset())
                    }
                }
            }
        case "/fork" =>
            // 分支：把当前历史保存为新会话，parent = 当前会话（或根）
            let curId = SessionState.current
            let history = agent.history()
            let newId = store.saveFork(history, curId)
            SessionState.current = newId
            tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[已分支为 ${newId}（parent=${curId}）]" + Ansi.reset())
        case "/quit" =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_MUTED) + "[再见]" + Ansi.reset())
            // 退出由主循环处理；先短暂刷新再退出
            spawn { tui.quit() }
        case "/theme" =>
            // /theme [name]：切换 TUI 主题（starfrost|classic）；无参数弹出交互式 picker
            let parts = args.split(" ", -1)
            if (parts.size > 1 && parts[1].size > 0) {
                let applied = Theme.apply(parts[1])
                // 写回 settings.json 持久化
                cfg.theme = applied
                cfg.saveTheme(applied)
                tui.appendOutput(Ansi.fg(Ansi.THEME_OK) + "[主题已切换: ${applied}]" + Ansi.reset())
                tui.markDirty()
            } else {
                // 无参数：弹出交互式主题选择 picker（上下键选择，Enter 确认）
                tui.showThemePicker(Theme.list(), Theme.current())
            }
        case _ =>
            tui.appendOutput(Ansi.fg(Ansi.THEME_ERR) + "未知命令: ${cmd}（输入 /help 查看）" + Ansi.reset())
    }
}
