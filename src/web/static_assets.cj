package cjh.web

/**
 * 静态资源：前端 HTML/CSS/JS 嵌入为仓颉字符串常量
 *
 * 设计原则：单二进制零依赖
 *   - 前端代码编译期嵌入 cjh 二进制
 *   - HTTP Server 直接 serve 字符串常量
 *   - 无需运行时读取外部文件
 *
 * 文件来源：src/web/frontend/（开发用，修改后需同步到本文件）
 */

/**
 * 静态资源容器
 */
public class StaticAssets {
    /**
     * 聊天界面 HTML
     */
    public static let indexHtml: String = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>cjh · Web</title>
    <link rel="stylesheet" href="/assets/styles.css">
    <!-- Markdown 渲染：marked.js + highlight.js + DOMPurify（CDN，离线降级为纯文本） -->
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/dompurify@3/dist/purify.min.js"></script>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github-dark.min.css">
    <script src="https://cdn.jsdelivr.net/npm/highlight.js@11/lib/common.min.js"></script>
</head>
<body data-theme="starfrost">
    <div class="app-container">
        <!-- 顶部栏 -->
        <header class="app-header">
            <div class="header-left">
                <span class="logo">cjh</span>
                <span class="logo-sub">· Harness made by Cangjie</span>
            </div>
            <div class="header-right">
                <select id="model-selector" class="model-selector">
                    <option value="">加载中...</option>
                </select>
                <select id="theme-selector" class="theme-selector">
                    <option value="starfrost">星霜青</option>
                    <option value="classic">经典亮青</option>
                    <option value="catppuccin">Catppuccin</option>
                    <option value="rose-pine">Rose Pine</option>
                    <option value="solarized">Solarized</option>
                    <option value="monokai">Monokai</option>
                </select>
            </div>
        </header>

        <!-- 主体区 -->
        <main class="app-main">
            <!-- 会话侧边栏 -->
            <aside class="sidebar">
                <div class="sidebar-header">
                    <span>会话</span>
                    <button id="new-session-btn" class="btn-icon" title="新建会话">+</button>
                </div>
                <div id="session-list" class="session-list">
                    <div class="loading">加载中...</div>
                </div>
            </aside>

            <!-- 对话区 -->
            <section class="chat-area">
                <div id="messages" class="messages">
                    <div class="welcome">
                        <h2>👋 欢迎使用 cjh Web</h2>
                        <p>在下方输入框开始对话</p>
                    </div>
                </div>

                <!-- 任务面板（折叠式） -->
                <div id="task-panel" class="task-panel collapsed">
                    <div class="task-panel-header" onclick="toggleTaskPanel()">
                        <span>任务列表</span>
                        <span id="task-count">0</span>
                    </div>
                    <div id="task-list" class="task-list"></div>
                </div>

                <!-- 输入区 -->
                <div class="input-area">
                    <textarea id="message-input"
                              class="message-input"
                              placeholder="输入消息... (Enter 发送, Shift+Enter 换行)"
                              rows="1"></textarea>
                    <button id="send-btn" class="send-btn" title="发送">➤</button>
                    <button id="abort-btn" class="abort-btn hidden" title="中断">⏹</button>
                </div>

                <!-- 回合总结条 -->
                <div id="round-summary" class="round-summary hidden"></div>
            </section>
        </main>
    </div>

    <script src="/assets/app.js"></script>
</body>
</html>
"""#

    /**
     * 前端 JavaScript（WebSocket 连接 + 消息渲染）
     */
    public static let appJs: String = #"""
'use strict';

// ====== 全局状态 ======
let ws = null;
let currentSessionId = null;
let isExecuting = false;

// ====== WebSocket 连接管理 ======
function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = protocol + '//' + window.location.host + '/ws';

    ws = new WebSocket(wsUrl);
    ws.onopen = function() {
        console.log('[WS] 连接已建立');
    };
    ws.onmessage = function(event) {
        handleServerMessage(JSON.parse(event.data));
    };
    ws.onerror = function(error) {
        console.error('[WS] 连接错误:', error);
        showError('WebSocket 连接错误');
    };
    ws.onclose = function() {
        console.log('[WS] 连接已关闭，3秒后重连');
        setTimeout(connectWebSocket, 3000);
    };
}

// ====== 消息发送 ======
function sendMessage(text) {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
        showError('WebSocket 未连接');
        return;
    }
    const msg = { type: 'chat', message: text };
    ws.send(JSON.stringify(msg));
    setExecuting(true);
}

function sendAbort() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: 'abort' }));
}

// ====== 服务器消息处理 ======
function handleServerMessage(msg) {
    switch (msg.type) {
        case 'delta':
            appendDelta(msg.text);
            break;
        case 'tool_start':
            appendToolStart(msg.name, msg.args);
            break;
        case 'tool_result':
            appendToolResult(msg.name, msg.content, msg.is_error);
            break;
        case 'done':
            handleDone(msg.summary);
            break;
        case 'error':
            showError(msg.message);
            setExecuting(false);
            break;
        case 'tasks':
            renderTaskList(msg.tasks);
            break;
        default:
            console.warn('[WS] 未知消息类型:', msg.type);
    }
}

// ====== 对话渲染 ======
function appendDelta(text) {
    let messages = document.getElementById('messages');
    let lastMsg = messages.lastElementChild;

    // 如果最后一条消息不是 assistant 类型，创建新的
    if (!lastMsg || !lastMsg.classList.contains('message-assistant')) {
        let msgDiv = document.createElement('div');
        msgDiv.className = 'message message-assistant';
        msgDiv.innerHTML = renderMarkdown(text);
        messages.appendChild(msgDiv);
        enhanceCodeBlocks(msgDiv);
    } else {
        // 追加到现有消息（简化：直接拼接纯文本）
        let content = lastMsg.querySelector('.message-content');
        if (content) {
            content.innerHTML += escapeHtml(text);
        }
    }
    scrollToBottom();
}

function appendToolStart(name, args) {
    let messages = document.getElementById('messages');
    let toolDiv = document.createElement('div');
    toolDiv.className = 'tool-call';
    let argsStr = args ? JSON.stringify(args) : '';
    toolDiv.innerHTML = '<span class=\"tool-icon\">▶</span> ' +
                        '<span class=\"tool-name\">' + escapeHtml(name) + '</span>' +
                        (argsStr ? ' <span class=\"tool-args\">' + escapeHtml(argsStr) + '</span>' : '');
    messages.appendChild(toolDiv);
    scrollToBottom();
}

function appendToolResult(name, content, isError) {
    let messages = document.getElementById('messages');
    let resultDiv = document.createElement('div');
    resultDiv.className = 'tool-result' + (isError ? ' tool-result-error' : '');
    resultDiv.innerHTML = '<span class=\"tool-icon\">↳</span> ' +
                          '<span class=\"tool-name\">' + escapeHtml(name) + ':</span> ' +
                          '<span class=\"tool-content\">' + escapeHtml(content) + '</span>';
    messages.appendChild(resultDiv);
    scrollToBottom();
}

function handleDone(summary) {
    setExecuting(false);
    if (summary) {
        let summaryDiv = document.getElementById('round-summary');
        let cachedPct = summary.cached > 0 ? Math.round(summary.cached * 100 / summary.tokens) : 0;
        summaryDiv.textContent = '✓ ' + summary.rounds + ' rounds · ' +
                                  summary.tools + ' tools · ' +
                                  (summary.duration_ms / 1000).toFixed(1) + 's · ' +
                                  summary.tokens + ' tokens · ' + cachedPct + '% cached';
        summaryDiv.classList.remove('hidden');
    }
}

// ====== 辅助函数 ======
function escapeHtml(text) {
    let div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function renderMarkdown(text) {
    // 优先用 marked.js + DOMPurify 做完整 Markdown 渲染
    if (typeof marked !== 'undefined' && typeof DOMPurify !== 'undefined') {
        marked.setOptions({
            breaks: true,
            gfm: true,
            highlight: function(code, lang) {
                if (typeof hljs !== 'undefined' && lang && hljs.getLanguage(lang)) {
                    try { return hljs.highlight(code, {language: lang}).value; } catch (e) {}
                }
                return code;
            }
        });
        var raw = marked.parse(text);
        var clean = DOMPurify.sanitize(raw);
        return '<div class=\"message-content\">' + clean + '</div>';
    }
    // 离线降级：纯文本 + 转义
    return '<div class=\"message-content\">' + escapeHtml(text) + '</div>';
}

/**
 * 给所有 <pre><code> 块添加复制按钮
 * 在 renderMarkdown 之后调用
 */
function enhanceCodeBlocks(container) {
    var pres = container.querySelectorAll('pre');
    for (var i = 0; i < pres.length; i++) {
        var pre = pres[i];
        // 已添加过按钮则跳过
        if (pre.querySelector('.copy-btn')) continue;
        var btn = document.createElement('button');
        btn.className = 'copy-btn';
        btn.textContent = '复制';
        btn.addEventListener('click', function(e) {
            var code = e.target.parentElement.querySelector('code');
            if (!code) return;
            var text = code.textContent;
            // 用 navigator.clipboard 写入剪贴板
            if (navigator.clipboard) {
                navigator.clipboard.writeText(text).then(function() {
                    e.target.textContent = '已复制';
                    setTimeout(function() { e.target.textContent = '复制'; }, 1500);
                });
            } else {
                // 降级：用 execCommand
                var ta = document.createElement('textarea');
                ta.value = text;
                document.body.appendChild(ta);
                ta.select();
                try { document.execCommand('copy'); } catch (err) {}
                document.body.removeChild(ta);
                e.target.textContent = '已复制';
                setTimeout(function() { e.target.textContent = '复制'; }, 1500);
            }
        });
        pre.appendChild(btn);
    }
}

function scrollToBottom() {
    let messages = document.getElementById('messages');
    messages.scrollTop = messages.scrollHeight;
}

function setExecuting(executing) {
    isExecuting = executing;
    let sendBtn = document.getElementById('send-btn');
    let abortBtn = document.getElementById('abort-btn');
    if (executing) {
        sendBtn.classList.add('hidden');
        abortBtn.classList.remove('hidden');
    } else {
        sendBtn.classList.remove('hidden');
        abortBtn.classList.add('hidden');
    }
}

function showError(message) {
    let messages = document.getElementById('messages');
    let errorDiv = document.createElement('div');
    errorDiv.className = 'message message-error';
    errorDiv.textContent = '❌ ' + message;
    messages.appendChild(errorDiv);
    scrollToBottom();
}

function renderTaskList(tasks) {
    let taskList = document.getElementById('task-list');
    let taskCount = document.getElementById('task-count');
    taskList.innerHTML = '';
    taskCount.textContent = tasks.length;

    tasks.forEach(function(task) {
        let taskDiv = document.createElement('div');
        taskDiv.className = 'task-item task-' + task.status;
        let icon = task.status === 'done' ? '✓' : (task.status === 'doing' ? '▶' : '○');
        taskDiv.innerHTML = '<span class=\"task-icon\">' + icon + '</span> ' +
                            '<span class=\"task-content\">' + escapeHtml(task.content) + '</span>';
        taskList.appendChild(taskDiv);
    });

    if (tasks.length > 0) {
        document.getElementById('task-panel').classList.remove('collapsed');
    }
}

function toggleTaskPanel() {
    document.getElementById('task-panel').classList.toggle('collapsed');
}

// ====== 事件绑定 ======
document.addEventListener('DOMContentLoaded', function() {
    connectWebSocket();

    // 发送按钮
    document.getElementById('send-btn').addEventListener('click', function() {
        let input = document.getElementById('message-input');
        let text = input.value.trim();
        if (text) {
            sendMessage(text);
            input.value = '';
            input.style.height = 'auto';
        }
    });

    // 中断按钮
    document.getElementById('abort-btn').addEventListener('click', sendAbort);

    // 输入框：Enter 发送，Shift+Enter 换行
    let input = document.getElementById('message-input');
    input.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            document.getElementById('send-btn').click();
        }
    });

    // 自动调整输入框高度
    input.addEventListener('input', function() {
        this.style.height = 'auto';
        this.style.height = Math.min(this.scrollHeight, 200) + 'px';
    });

    // 新建会话
    document.getElementById('new-session-btn').addEventListener('click', function() {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'new_session' }));
        }
        document.getElementById('messages').innerHTML =
            '<div class=\"welcome\"><h2>👋 新会话</h2><p>开始新的对话</p></div>';
    });

    // 主题切换
    document.getElementById('theme-selector').addEventListener('change', function() {
        document.body.setAttribute('data-theme', this.value);
        localStorage.setItem('cjh-theme', this.value);
    });

    // 恢复保存的主题
    let savedTheme = localStorage.getItem('cjh-theme');
    if (savedTheme) {
        document.body.setAttribute('data-theme', savedTheme);
        document.getElementById('theme-selector').value = savedTheme;
    }
});
"""#

    /**
     * 前端 CSS（6 套主题 CSS 变量 + 布局）
     */
    public static let stylesCss: String = #"""
/* ====== 主题 CSS 变量 ====== */
:root, [data-theme="starfrost"] {
    --bg-primary: #0a1628;
    --bg-secondary: #111d33;
    --bg-tertiary: #1a2942;
    --text-primary: #e0e6ed;
    --text-secondary: #8a9bb0;
    --accent: #4dd0e1;
    --accent-dim: #2a6a75;
    --border: #1f3050;
    --success: #66bb6a;
    --error: #ef5350;
    --warning: #ffa726;
}

[data-theme="classic"] {
    --bg-primary: #001122;
    --bg-secondary: #002233;
    --bg-tertiary: #003344;
    --text-primary: #00ffcc;
    --text-secondary: #00aa88;
    --accent: #00ffcc;
    --accent-dim: #008866;
    --border: #004455;
    --success: #00ff66;
    --error: #ff4444;
    --warning: #ffaa00;
}

[data-theme="catppuccin"] {
    --bg-primary: #1e1e2e;
    --bg-secondary: #181825;
    --bg-tertiary: #313244;
    --text-primary: #cdd6f4;
    --text-secondary: #a6adc8;
    --accent: #89b4fa;
    --accent-dim: #45575a;
    --border: #45475a;
    --success: #a6e3a1;
    --error: #f38ba8;
    --warning: #f9e2af;
}

[data-theme="rose-pine"] {
    --bg-primary: #191724;
    --bg-secondary: #1f1d2e;
    --bg-tertiary: #26233a;
    --text-primary: #e0def4;
    --text-secondary: #908caa;
    --accent: #ebbcba;
    --accent-dim: #524f67;
    --border: #2a2740;
    --success: #9ccfd8;
    --error: #eb6f92;
    --warning: #f6c177;
}

[data-theme="solarized"] {
    --bg-primary: #002b36;
    --bg-secondary: #073642;
    --bg-tertiary: #586e75;
    --text-primary: #93a1a1;
    --text-secondary: #839496;
    --accent: #268bd2;
    --accent-dim: #1a5680;
    --border: #073642;
    --success: #859900;
    --error: #dc322f;
    --warning: #b58900;
}

[data-theme="monokai"] {
    --bg-primary: #272822;
    --bg-secondary: #2e2f28;
    --bg-tertiary: #3e3d32;
    --text-primary: #f8f8f2;
    --text-secondary: #75715e;
    --accent: #a6e22e;
    --accent-dim: #5a7020;
    --border: #3e3d32;
    --success: #a6e22e;
    --error: #f92672;
    --warning: #e6db74;
}

/* ====== 全局重置 ====== */
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

html, body {
    height: 100%;
    overflow: hidden;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg-primary);
    color: var(--text-primary);
    font-size: 14px;
    line-height: 1.5;
}

/* ====== 布局 ====== */
.app-container {
    display: flex;
    flex-direction: column;
    height: 100vh;
}

.app-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 16px;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
}

.header-left {
    display: flex;
    align-items: baseline;
    gap: 8px;
}

.logo {
    font-weight: bold;
    color: var(--accent);
    font-size: 16px;
}

.logo-sub {
    color: var(--text-secondary);
    font-size: 12px;
}

.header-right {
    display: flex;
    gap: 8px;
}

.model-selector, .theme-selector {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    border: 1px solid var(--border);
    padding: 4px 8px;
    border-radius: 4px;
    font-size: 13px;
    cursor: pointer;
}

.app-main {
    display: flex;
    flex: 1;
    overflow: hidden;
}

/* ====== 侧边栏 ====== */
.sidebar {
    width: 240px;
    background: var(--bg-secondary);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
}

.sidebar-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
    font-weight: bold;
}

.btn-icon {
    background: var(--accent-dim);
    color: var(--accent);
    border: none;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 16px;
    line-height: 1;
}

.session-list {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0;
}

.session-list .loading,
.session-list .empty {
    padding: 16px;
    text-align: center;
    color: var(--text-secondary);
}

/* ====== 对话区 ====== */
.chat-area {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.messages {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
}

.welcome {
    text-align: center;
    padding: 60px 20px;
    color: var(--text-secondary);
}

.welcome h2 {
    color: var(--accent);
    margin-bottom: 12px;
}

.message {
    margin-bottom: 16px;
    padding: 12px 16px;
    border-radius: 8px;
    max-width: 85%;
}

.message-user {
    background: var(--accent-dim);
    margin-left: auto;
}

.message-assistant {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
}

.message-error {
    background: var(--error);
    color: white;
}

.message-content {
    white-space: pre-wrap;
    word-wrap: break-word;
}

/* ====== Markdown 代码块 + 复制按钮 ====== */
.message-content pre {
    position: relative;
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 12px 12px 12px 12px;
    overflow-x: auto;
    margin: 8px 0;
}

.message-content code {
    font-family: 'SF Mono', Menlo, Consolas, monospace;
    font-size: 13px;
}

.message-content pre code {
    background: none;
    padding: 0;
}

.message-content :not(pre) > code {
    background: var(--bg-tertiary);
    padding: 2px 4px;
    border-radius: 3px;
}

.copy-btn {
    position: absolute;
    top: 4px;
    right: 4px;
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    border: 1px solid var(--border);
    padding: 2px 8px;
    border-radius: 3px;
    font-size: 11px;
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.15s;
}

.message-content pre:hover .copy-btn {
    opacity: 1;
}

.tool-call, .tool-result {
    margin: 4px 16px;
    padding: 6px 12px;
    font-size: 13px;
    color: var(--text-secondary);
    background: var(--bg-secondary);
    border-left: 3px solid var(--accent);
    border-radius: 0 4px 4px 0;
}

.tool-result-error {
    border-left-color: var(--error);
    color: var(--error);
}

.tool-icon {
    color: var(--accent);
    font-weight: bold;
}

.tool-name {
    color: var(--text-primary);
    font-weight: bold;
}

.tool-args {
    color: var(--text-secondary);
    font-family: monospace;
}

.tool-content {
    color: var(--text-secondary);
    font-family: monospace;
    white-space: pre-wrap;
}

/* ====== 输入区 ====== */
.input-area {
    display: flex;
    gap: 8px;
    padding: 12px 16px;
    background: var(--bg-secondary);
    border-top: 1px solid var(--border);
    flex-shrink: 0;
}

.message-input {
    flex: 1;
    background: var(--bg-primary);
    color: var(--text-primary);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 14px;
    font-family: inherit;
    resize: none;
    min-height: 40px;
    max-height: 200px;
    line-height: 1.4;
}

.message-input:focus {
    outline: none;
    border-color: var(--accent);
}

.send-btn, .abort-btn {
    background: var(--accent);
    color: var(--bg-primary);
    border: none;
    width: 40px;
    height: 40px;
    border-radius: 8px;
    cursor: pointer;
    font-size: 18px;
    flex-shrink: 0;
}

.send-btn:hover, .abort-btn:hover {
    opacity: 0.85;
}

.abort-btn {
    background: var(--error);
    color: white;
}

.hidden {
    display: none !important;
}

/* ====== 回合总结条 ====== */
.round-summary {
    padding: 8px 16px;
    background: var(--bg-tertiary);
    border-top: 1px solid var(--border);
    text-align: center;
    color: var(--text-secondary);
    font-size: 12px;
    font-family: monospace;
    flex-shrink: 0;
}

/* ====== 任务面板 ====== */
.task-panel {
    background: var(--bg-secondary);
    border-top: 1px solid var(--border);
    max-height: 200px;
    overflow-y: auto;
    transition: max-height 0.2s ease;
    flex-shrink: 0;
}

.task-panel.collapsed {
    max-height: 0;
    border-top: none;
}

.task-panel-header {
    display: flex;
    justify-content: space-between;
    padding: 8px 16px;
    cursor: pointer;
    font-weight: bold;
    color: var(--accent);
}

.task-list {
    padding: 4px 16px 12px;
}

.task-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0;
    color: var(--text-secondary);
    font-size: 13px;
}

.task-item.task-done {
    color: var(--success);
    text-decoration: line-through;
}

.task-item.task-doing {
    color: var(--accent);
}

.task-icon {
    font-size: 14px;
    width: 16px;
    flex-shrink: 0;
}

/* ====== 移动端响应式 ====== */
@media (max-width: 768px) {
    .sidebar {
        display: none;
    }

    .message {
        max-width: 100%;
    }

    .header-left .logo-sub {
        display: none;
    }
}
"""#
}
