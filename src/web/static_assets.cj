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
    <!-- highlight.js 必须用 cdn-release 的 UMD bundle（build/highlight.min.js），
         /lib/common.js 是 CommonJS 模块（含 require），浏览器无法加载 -->
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css">
    <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
</head>
<body data-theme="light">
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
                    <option value="light" selected>浅色白</option>
                    <option value="starfrost">星霜青</option>
                    <option value="classic">经典亮青</option>
                    <option value="catppuccin">Catppuccin</option>
                    <option value="rose-pine">Rose Pine</option>
                    <option value="solarized">Solarized</option>
                    <option value="monokai">Monokai</option>
                </select>
                <button id="config-btn" class="btn-icon" title="配置">⚙</button>
            </div>
        </header>

        <!-- 主体区 -->
        <main class="app-main">
            <!-- 会话侧边栏 -->
            <aside class="sidebar">
                <!-- 分区切换 tab -->
                <div class="sidebar-tabs">
                    <button class="sidebar-tab active" data-tab="sessions">会话</button>
                    <button class="sidebar-tab" data-tab="skills">技能</button>
                    <button class="sidebar-tab" data-tab="mcp">MCP</button>
                    <button class="sidebar-tab" data-tab="workspaces">工作区</button>
                </div>

                <!-- 会话分区 -->
                <div id="tab-sessions" class="sidebar-panel active">
                    <div class="sidebar-header">
                        <span>历史会话</span>
                        <button id="new-session-btn" class="btn-icon" title="新建会话">+</button>
                    </div>
                    <div id="session-list" class="session-list">
                        <div class="loading">加载中...</div>
                    </div>
                </div>

                <!-- 技能分区 -->
                <div id="tab-skills" class="sidebar-panel">
                    <div class="sidebar-header">
                        <span>已加载技能</span>
                    </div>
                    <div id="skill-list" class="skill-list">
                        <div class="loading">加载中...</div>
                    </div>
                </div>

                <!-- MCP 分区 -->
                <div id="tab-mcp" class="sidebar-panel">
                    <div class="sidebar-header">
                        <span>MCP 服务器</span>
                    </div>
                    <div id="mcp-list" class="mcp-list">
                        <div class="loading">加载中...</div>
                    </div>
                </div>

                <!-- 工作区分区 -->
                <div id="tab-workspaces" class="sidebar-panel">
                    <div class="sidebar-header">
                        <span>工作区</span>
                        <button id="add-workspace-btn" class="btn-icon" title="添加工作区">+</button>
                    </div>
                    <div id="workspace-list" class="workspace-list">
                        <div class="loading">加载中...</div>
                    </div>
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

    <!-- 配置模态对话框 -->
    <div id="config-modal" class="modal-overlay hidden">
        <div class="modal-dialog config-dialog">
            <div class="modal-header">
                <span>配置</span>
                <button class="modal-close" onclick="closeConfigModal()">×</button>
            </div>
            <div class="modal-body">
                <div id="config-form" class="config-form">
                    <div class="loading">加载中...</div>
                </div>
            </div>
        </div>
    </div>

    <!-- 工作区添加模态对话框 -->
    <div id="workspace-modal" class="modal-overlay hidden">
        <div class="modal-dialog">
            <div class="modal-header">
                <span>添加工作区</span>
                <button class="modal-close" onclick="closeWorkspaceModal()">×</button>
            </div>
            <div class="modal-body">
                <div class="config-row">
                    <label>路径（绝对路径）</label>
                    <div style="display:flex;gap:6px">
                        <input type="text" id="workspace-path-input" placeholder="/home/user/project" style="flex:1">
                        <button class="btn-icon" onclick="openDirBrowser()" title="浏览目录">📁</button>
                    </div>
                </div>
                <!-- 目录浏览选择器 -->
                <div id="dir-browser" class="dir-browser hidden">
                    <div id="dir-browser-path" class="dir-browser-path"></div>
                    <div id="dir-browser-list" class="dir-browser-list"></div>
                    <div class="dir-browser-actions">
                        <button class="config-save-btn" onclick="useCurrentDir()">选择当前目录</button>
                        <button onclick="dirUp()">⬆ 上一级</button>
                    </div>
                </div>
                <div class="config-row">
                    <label>名称（可选）</label>
                    <input type="text" id="workspace-name-input" placeholder="my-project">
                </div>
                <button class="config-save-btn" onclick="addWorkspace()">添加</button>
            </div>
        </div>
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
        loadSessions();
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
    // 首次发送：移除欢迎页
    let welcome = document.querySelector('.welcome');
    if (welcome) { welcome.remove(); }
    // 先在页面上渲染用户消息
    appendUserMessage(text);
    const msg = { type: 'chat', message: text };
    ws.send(JSON.stringify(msg));
    setExecuting(true);
}

/**
 * 渲染用户消息气泡（右对齐）
 */
function appendUserMessage(text) {
    let messages = document.getElementById('messages');
    let msgDiv = document.createElement('div');
    msgDiv.className = 'message message-user';
    msgDiv.innerHTML = '<div class="message-content">' + escapeHtml(text) + '</div>';
    messages.appendChild(msgDiv);
    scrollToBottom();
}

function sendAbort() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: 'abort' }));
}

// ====== 会话管理 ======

/**
 * 从 /api/sessions 加载会话列表，渲染到侧边栏
 */
function loadSessions() {
    fetch('/api/sessions')
        .then(r => r.json())
        .then(data => {
            let list = document.getElementById('session-list');
            if (!data.sessions || data.sessions.length === 0) {
                list.innerHTML = '<div class="empty">暂无历史会话</div>';
                return;
            }
            list.innerHTML = '';
            data.sessions.forEach(function(s) {
                let item = document.createElement('div');
                item.className = 'session-item';
                item.dataset.sessionId = s.id;
                let time = formatTime(s.created_at);
                item.innerHTML = '<div class="session-title">' + escapeHtml(s.title || '新会话') + '</div>' +
                                 '<div class="session-time">' + time + '</div>';
                item.addEventListener('click', function() {
                    switchSession(s.id);
                });
                if (s.id === currentSessionId) {
                    item.classList.add('active');
                }
                list.appendChild(item);
            });
        })
        .catch(function(e) {
            console.error('[Sessions] 加载失败:', e);
        });
}

/**
 * 从 /api/skills 加载技能列表，渲染到侧边栏技能分区
 */
function loadSkills() {
    fetch('/api/skills')
        .then(r => r.json())
        .then(data => {
            let list = document.getElementById('skill-list');
            if (!data.skills || data.skills.length === 0) {
                list.innerHTML = '<div class="empty">暂无技能<br>创建 ~/.cjh/skills/&lt;name&gt;.md</div>';
                return;
            }
            list.innerHTML = '';
            data.skills.forEach(function(s) {
                let item = document.createElement('div');
                item.className = 'skill-item' + (s.enabled ? ' skill-enabled' : ' skill-disabled');
                let badge = s.enabled ? '●' : '○';
                let toolsLabel = s.tools > 0 ? (' · ' + s.tools + ' 工具') : '';
                item.innerHTML = '<div class="skill-name">' + badge + ' ' + escapeHtml(s.name) + '</div>' +
                                 '<div class="skill-desc">' + escapeHtml(s.description || '') + '</div>' +
                                 '<div class="skill-meta">' + (s.enabled ? '启用' : '禁用') + toolsLabel + '</div>';
                list.appendChild(item);
            });
        })
        .catch(function(e) {
            console.error('[Skills] 加载失败:', e);
            document.getElementById('skill-list').innerHTML = '<div class="empty">加载失败</div>';
        });
}

/**
 * 从 /api/mcp 加载 MCP 服务器列表，渲染到侧边栏 MCP 分区
 */
function loadMcp() {
    fetch('/api/mcp')
        .then(r => r.json())
        .then(data => {
            let list = document.getElementById('mcp-list');
            if (!data.servers || data.servers.length === 0) {
                list.innerHTML = '<div class="empty">暂无 MCP 服务器<br>在 settings.json 配置 mcp_servers</div>';
                return;
            }
            list.innerHTML = '';
            data.servers.forEach(function(s) {
                let item = document.createElement('div');
                item.className = 'mcp-item';
                let connIcon = s.connected ? '🟢' : '⚪';
                let transport = s.transport === 'sse' ? 'SSE: ' + escapeHtml(s.url || '') : 'stdio: ' + escapeHtml(s.command || '');
                item.innerHTML = '<div class="mcp-name">' + connIcon + ' ' + escapeHtml(s.name) + '</div>' +
                                 '<div class="mcp-transport">' + transport + '</div>';
                list.appendChild(item);
            });
        })
        .catch(function(e) {
            console.error('[MCP] 加载失败:', e);
            document.getElementById('mcp-list').innerHTML = '<div class="empty">加载失败</div>';
        });
}

/**
 * 从 /api/workspaces 加载工作区列表，渲染到侧边栏工作区分区
 */
function loadWorkspaces() {
    fetch('/api/workspaces')
        .then(r => r.json())
        .then(data => {
            let list = document.getElementById('workspace-list');
            if (!data.workspaces || data.workspaces.length === 0) {
                list.innerHTML = '<div class="empty">暂无工作区<br>点 + 添加</div>';
                return;
            }
            list.innerHTML = '';
            data.workspaces.forEach(function(w) {
                let item = document.createElement('div');
                item.className = 'workspace-item';
                item.dataset.path = w.path;
                item.innerHTML = '<div class="workspace-name">' + escapeHtml(w.name) + '</div>' +
                                 '<div class="workspace-path">' + escapeHtml(w.path) + '</div>' +
                                 '<button class="workspace-del" title="删除">×</button>';
                // 切换工作区
                item.addEventListener('click', function(e) {
                    if (e.target.classList.contains('workspace-del')) { return; }
                    switchWorkspace(w.path, w.name);
                });
                // 删除工作区
                item.querySelector('.workspace-del').addEventListener('click', function(e) {
                    e.stopPropagation();
                    removeWorkspace(w.path);
                });
                list.appendChild(item);
            });
            // 高亮当前工作区（对比 cwd）
            fetch('/api/fs/list').then(r => r.json()).then(function(fs) {
                if (!fs.error) {
                    document.querySelectorAll('.workspace-item').forEach(function(el) {
                        el.classList.toggle('active', el.dataset.path === fs.path);
                    });
                }
            }).catch(function() {});
        })
        .catch(function(e) {
            console.error('[Workspaces] 加载失败:', e);
            document.getElementById('workspace-list').innerHTML = '<div class="empty">加载失败</div>';
        });
}

/**
 * 切换工作区：POST /api/workspaces/switch —— 后端 chdir 真正切换 cwd，
 * 后续相对路径工具（bash/read_file 等）立即在新工作区工作。
 */
function switchWorkspace(path, name) {
    fetch('/api/workspaces/switch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: path })
    }).then(r => r.json()).then(function(data) {
        let list = document.getElementById('workspace-list');
        let tip = document.createElement('div');
        tip.className = 'workspace-tip';
        if (data.ok) {
            // 高亮当前工作区
            document.querySelectorAll('.workspace-item').forEach(function(el) {
                el.classList.toggle('active', el.dataset.path === path);
            });
            tip.textContent = '✓ 已切换至「' + name + '」';
        } else {
            tip.style.color = 'var(--error)';
            tip.textContent = '切换失败: ' + (data.error || '未知错误');
        }
        list.insertBefore(tip, list.firstChild);
        loadWorkspaces();  // 刷新排序
    }).catch(function(e) {
        let list = document.getElementById('workspace-list');
        let tip = document.createElement('div');
        tip.className = 'workspace-tip';
        tip.style.color = 'var(--error)';
        tip.textContent = '切换失败: ' + e;
        list.insertBefore(tip, list.firstChild);
    });
}

/* ====== 目录浏览选择器 ====== */
var browsePath = '';

/**
 * 打开目录浏览：从路径输入框当前值（或根目录）开始列目录
 */
function openDirBrowser() {
    let input = document.getElementById('workspace-path-input').value;
    browsePath = input && input.trim().length > 0 ? input.trim() : '/';
    loadDirList();
    document.getElementById('dir-browser').classList.remove('hidden');
}

/**
 * 加载当前 browsePath 的目录列表（/api/fs/list）
 */
function loadDirList() {
    document.getElementById('dir-browser-path').textContent = '当前: ' + browsePath;
    fetch('/api/fs/list?path=' + encodeURIComponent(browsePath))
        .then(r => r.json())
        .then(function(data) {
            let list = document.getElementById('dir-browser-list');
            if (data.error) {
                list.innerHTML = '<div class="empty">' + escapeHtml(data.error) + '</div>';
                return;
            }
            list.innerHTML = '';
            if (!data.dirs || data.dirs.length === 0) {
                list.innerHTML = '<div class="empty">无子目录</div>';
                return;
            }
            data.dirs.forEach(function(d) {
                let item = document.createElement('div');
                item.className = 'dir-item';
                item.textContent = '📁 ' + d.name;
                item.title = d.path;
                item.onclick = function() { browsePath = d.path; loadDirList(); };
                list.appendChild(item);
            });
        })
        .catch(function(e) {
            document.getElementById('dir-browser-list').innerHTML = '<div class="empty">加载失败: ' + e + '</div>';
        });
}

/**
 * 上一级目录
 */
function dirUp() {
    if (browsePath === '/' || browsePath.length === 0) { return; }
    let idx = browsePath.lastIndexOf('/');
    browsePath = idx > 0 ? browsePath.slice(0, idx) : '/';
    loadDirList();
}

/**
 * 选择当前浏览目录：填入路径输入框，关闭浏览器
 */
function useCurrentDir() {
    document.getElementById('workspace-path-input').value = browsePath;
    document.getElementById('dir-browser').classList.add('hidden');
}

/**
 * 删除工作区：DELETE /api/workspaces
 */
function removeWorkspace(path) {
    fetch('/api/workspaces', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: path })
    }).then(function() {
        loadWorkspaces();
    });
}

/**
 * 打开工作区添加模态框
 */
function openWorkspaceModal() {
    document.getElementById('workspace-path-input').value = '';
    document.getElementById('workspace-name-input').value = '';
    document.getElementById('workspace-modal').classList.remove('hidden');
}

/**
 * 关闭工作区添加模态框
 */
function closeWorkspaceModal() {
    document.getElementById('workspace-modal').classList.add('hidden');
}

/**
 * 添加工作区：POST /api/workspaces
 */
function addWorkspace() {
    let path = document.getElementById('workspace-path-input').value.trim();
    let name = document.getElementById('workspace-name-input').value.trim();
    if (!path) { return; }
    fetch('/api/workspaces', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: path, name: name })
    }).then(function(r) { return r.json(); }).then(function(data) {
        if (data.ok) {
            closeWorkspaceModal();
            // 刷新工作区列表
            loadWorkspaces();
            document.getElementById('workspace-list').dataset.loaded = '1';
        } else {
            alert('添加失败: ' + (data.error || '未知错误'));
        }
    });
}

/**
 * 打开配置模态框：拉取配置数据 + 显示
 */
function openConfigModal() {
    loadConfig();
    document.getElementById('config-modal').classList.remove('hidden');
}

/**
 * 关闭配置模态框
 */
function closeConfigModal() {
    document.getElementById('config-modal').classList.add('hidden');
}

/**
 * 从 /api/settings 加载配置，渲染到配置模态框表单。
 * 模型字段渲染为下拉框，选项来自 /api/models。
 */
function loadConfig() {
    // 并行拉取 settings 和 models
    Promise.all([
        fetch('/api/settings').then(r => r.json()),
        fetch('/api/models').then(r => r.json()).catch(() => ({ models: [], current: '' }))
    ]).then(function(results) {
        let data = results[0];
        let modelsData = results[1];
        let form = document.getElementById('config-form');
        form.innerHTML = '';
        // 分组渲染
        let groups = [
            { title: 'Provider', fields: [
                { key: 'baseUrl', label: 'API 端点', type: 'text' },
                { key: 'model', label: '模型', type: 'select' },
                { key: 'apiKey', label: 'API Key', type: 'password' }
            ]},
            { title: '行为参数', fields: [
                { key: 'maxIterations', label: '最大迭代', type: 'number' },
                { key: 'temperature', label: '温度', type: 'number' },
                { key: 'maxTokens', label: '最大 token', type: 'number' },
                { key: 'compactThreshold', label: '压缩阈值', type: 'number' },
                { key: 'compactKeep', label: '压缩保留', type: 'number' },
                { key: 'toolResultMaxChars', label: '工具结果上限', type: 'number' }
            ]},
            { title: 'Web 配置', fields: [
                { key: 'webPort', label: '端口', type: 'number' },
                { key: 'webBindAddr', label: '绑定地址', type: 'text' },
                { key: 'webAuthToken', label: '鉴权 token', type: 'text' }
            ]}
        ];
        // 构建模型选项数组
        let modelOptions = [];
        if (modelsData.models && modelsData.models.length > 0) {
            modelsData.models.forEach(function(m) {
                modelOptions.push({ value: m.id, label: m.name || m.id });
            });
        }
        // 确保当前模型在选项里
        let currentModel = data.model || modelsData.current || '';
        if (currentModel && !modelOptions.some(function(o) { return o.value === currentModel; })) {
            modelOptions.unshift({ value: currentModel, label: currentModel + '（当前）' });
        }
        groups.forEach(function(g) {
            let groupDiv = document.createElement('div');
            groupDiv.className = 'config-group';
            groupDiv.innerHTML = '<div class="config-group-title">' + escapeHtml(g.title) + '</div>';
            g.fields.forEach(function(f) {
                let row = document.createElement('div');
                row.className = 'config-row';
                let val = data[f.key] !== undefined ? data[f.key] : '';
                if (f.type === 'select') {
                    // 下拉框渲染
                    let optsHtml = '';
                    modelOptions.forEach(function(o) {
                        let selected = (o.value === val) ? ' selected' : '';
                        optsHtml += '<option value="' + escapeHtml(o.value) + '"' + selected + '>' +
                                    escapeHtml(o.label) + '</option>';
                    });
                    // 空模型列表 → 降级为 text 输入
                    if (modelOptions.length === 0) {
                        row.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' +
                                       '<input type="text" data-key="' + f.key + '" value="' + escapeHtml(String(val)) + '">';
                    } else {
                        // 允许输入自定义模型：在 select 旁加一个 text 输入（onchange 回填）
                        row.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' +
                                       '<select data-key="' + f.key + '">' + optsHtml + '</select>' +
                                       '<input type="text" class="config-custom-input" placeholder="或输入自定义模型" value="">';
                    }
                } else {
                    row.innerHTML = '<label>' + escapeHtml(f.label) + '</label>' +
                                   '<input type="' + f.type + '" data-key="' + f.key + '" value="' + escapeHtml(String(val)) + '">';
                }
                groupDiv.appendChild(row);
            });
            form.appendChild(groupDiv);
        });
        // 自定义模型输入联动：select 改变时清空 custom；custom 输入时覆盖 select
        let modelSelect = form.querySelector('select[data-key="model"]');
        let modelCustom = form.querySelector('.config-custom-input');
        if (modelSelect && modelCustom) {
            modelSelect.addEventListener('change', function() {
                modelCustom.value = '';
            });
            modelCustom.addEventListener('input', function() {
                // 把自定义值写回 select 的 dataset，saveConfig 时优先取 custom
            });
        }
        // 保存按钮
        let saveBtn = document.createElement('button');
        saveBtn.className = 'config-save-btn';
        saveBtn.textContent = '保存配置';
        saveBtn.addEventListener('click', saveConfig);
        form.appendChild(saveBtn);
    }).catch(function(e) {
        console.error('[Config] 加载失败:', e);
        document.getElementById('config-form').innerHTML = '<div class="empty">加载失败</div>';
    });
}

/**
 * POST /api/settings 保存配置
 */
function saveConfig() {
    let payload = {};
    // 读取所有带 data-key 的 input 和 select
    let dataEls = document.querySelectorAll('#config-form [data-key]');
    dataEls.forEach(function(el) {
        let key = el.dataset.key;
        // select[data-key="model"] 和 custom text 输入同名，custom 非空时优先
        if (key === 'model') {
            let custom = document.querySelector('#config-form .config-custom-input');
            if (custom && custom.value.trim().length > 0) {
                payload[key] = custom.value.trim();
            } else {
                payload[key] = el.value;
            }
            return;
        }
        let val = el.value;
        if (key === 'maxIterations' || key === 'maxTokens' || key === 'compactThreshold' ||
            key === 'compactKeep' || key === 'toolResultMaxChars' || key === 'webPort') {
            payload[key] = parseInt(val) || 0;
        } else if (key === 'temperature') {
            payload[key] = parseFloat(val) || 0.7;
        } else {
            payload[key] = val;
        }
    });
    fetch('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
    .then(r => r.json())
    .then(data => {
        let btn = document.querySelector('.config-save-btn');
        if (data.ok) {
            btn.textContent = '✓ 已保存';
            btn.classList.add('saved');
            setTimeout(function() {
                btn.textContent = '保存配置';
                btn.classList.remove('saved');
            }, 1500);
        } else {
            btn.textContent = '❌ 保存失败';
            console.error('[Config] 保存失败:', data.error);
        }
    })
    .catch(function(e) {
        console.error('[Config] 保存请求失败:', e);
    });
}

/**
 * 侧边栏 tab 切换
 */
function switchSidebarTab(tabName) {
    // 更新 tab 按钮高亮
    document.querySelectorAll('.sidebar-tab').forEach(function(btn) {
        if (btn.dataset.tab === tabName) {
            btn.classList.add('active');
        } else {
            btn.classList.remove('active');
        }
    });
    // 显示对应面板
    document.querySelectorAll('.sidebar-panel').forEach(function(panel) {
        if (panel.id === 'tab-' + tabName) {
            panel.classList.add('active');
        } else {
            panel.classList.remove('active');
        }
    });
    // 懒加载：首次切到技能/MCP/工作区时拉取数据
    if (tabName === 'skills' && !document.getElementById('skill-list').dataset.loaded) {
        loadSkills();
        document.getElementById('skill-list').dataset.loaded = '1';
    } else if (tabName === 'mcp' && !document.getElementById('mcp-list').dataset.loaded) {
        loadMcp();
        document.getElementById('mcp-list').dataset.loaded = '1';
    } else if (tabName === 'workspaces' && !document.getElementById('workspace-list').dataset.loaded) {
        loadWorkspaces();
        document.getElementById('workspace-list').dataset.loaded = '1';
    }
}

/**
 * 切换到指定会话：发 resume_session WebSocket 消息 + 清空消息区
 */
function switchSession(sessionId) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (sessionId === currentSessionId) return;

    // 清空消息区
    let messages = document.getElementById('messages');
    messages.innerHTML = '<div class="loading">加载历史消息...</div>';

    // 发送 resume_session 请求
    ws.send(JSON.stringify({ type: 'resume_session', session_id: sessionId }));

    currentSessionId = sessionId;

    // 更新侧边栏高亮
    document.querySelectorAll('.session-item').forEach(function(item) {
        if (item.dataset.sessionId === sessionId) {
            item.classList.add('active');
        } else {
            item.classList.remove('active');
        }
    });
}

/**
 * 格式化时间戳为相对时间
 */
function formatTime(ts) {
    if (!ts) return '';
    let now = Math.floor(Date.now() / 1000);
    let diff = now - ts;
    if (diff < 60) return '刚刚';
    if (diff < 3600) return Math.floor(diff / 60) + ' 分钟前';
    if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
    if (diff < 604800) return Math.floor(diff / 86400) + ' 天前';
    let d = new Date(ts * 1000);
    return (d.getMonth() + 1) + '/' + d.getDate();
}

// ====== 服务器消息处理 ======
function handleServerMessage(msg) {
    switch (msg.type) {
        case 'delta':
            appendDelta(msg.text);
            break;
        case 'tool_start':
            // assistant 消息定型，再渲染 tool
            finalizeAssistantMessage();
            appendToolStart(msg.name, msg.args);
            break;
        case 'tool_result':
            appendToolResult(msg.name, msg.content, msg.is_error);
            break;
        case 'done':
            finalizeAssistantMessage();
            handleDone(msg.summary);
            break;
        case 'error':
            finalizeAssistantMessage();
            showError(msg.message);
            setExecuting(false);
            break;
        case 'tasks':
            renderTaskList(msg.tasks);
            break;
        case 'history_messages':
            renderHistoryMessages(msg.messages, msg.session_id);
            break;
        default:
            console.warn('[WS] 未知消息类型:', msg.type);
    }
}

/**
 * 渲染历史消息列表（切换会话时调用）
 * messages: [{role, content, tool_call_id?, name?}, ...]
 */
function renderHistoryMessages(messages, sessionId) {
    currentSessionId = sessionId;
    finalizeAssistantMessage();

    let messagesEl = document.getElementById('messages');
    messagesEl.innerHTML = '';

    if (!messages || messages.length === 0) {
        messagesEl.innerHTML = '<div class="welcome"><h2>👋</h2><p>空会话</p></div>';
        return;
    }

    for (let i = 0; i < messages.length; i++) {
        let m = messages[i];
        if (m.role === 'user') {
            appendUserMessage(m.content);
        } else if (m.role === 'assistant') {
            currentAssistantDiv = document.createElement('div');
            currentAssistantDiv.className = 'message message-assistant';
            currentAssistantDiv.innerHTML = '<div class="message-content">' + renderMarkdownInline(m.content) + '</div>';
            messagesEl.appendChild(currentAssistantDiv);
            enhanceCodeBlocks(currentAssistantDiv);
            currentAssistantDiv = null;
        } else if (m.role === 'tool') {
            appendToolResult(m.name || 'tool', m.content, false);
        }
    }

    // 更新侧边栏高亮
    document.querySelectorAll('.session-item').forEach(function(item) {
        if (item.dataset.sessionId === sessionId) {
            item.classList.add('active');
        } else {
            item.classList.remove('active');
        }
    });

    scrollToBottom();
}

// ====== 对话渲染 ======

// 流式渲染状态
var currentAssistantDiv = null;   // 当前 assistant 消息 div
var deltaBuffer = '';             // 累积的 delta 文本
var rafScheduled = false;         // requestAnimationFrame 节流标志

function appendDelta(text) {
    let messages = document.getElementById('messages');

    // 如果最后一条消息不是 assistant 类型，创建新的
    if (!currentAssistantDiv || !currentAssistantDiv.parentElement) {
        currentAssistantDiv = document.createElement('div');
        currentAssistantDiv.className = 'message message-assistant';
        currentAssistantDiv.innerHTML = '<div class="message-content"></div>';
        messages.appendChild(currentAssistantDiv);
        deltaBuffer = '';
    }

    // 累积 delta
    deltaBuffer += text;

    // 用 requestAnimationFrame 节流，每帧最多渲染一次
    if (!rafScheduled) {
        rafScheduled = true;
        requestAnimationFrame(flushDelta);
    }
}

/**
 * 渲染累积的 delta buffer
 * requestAnimationFrame 节流，避免每条 delta 都触发 marked.parse
 */
function flushDelta() {
    rafScheduled = false;
    if (!currentAssistantDiv) { return; }
    let content = currentAssistantDiv.querySelector('.message-content');
    if (!content) { return; }

    // 重新渲染整个 buffer 的 Markdown
    content.innerHTML = renderMarkdownInline(deltaBuffer);

    // 代码块增强（复制按钮等）
    enhanceCodeBlocks(currentAssistantDiv);
    scrollToBottom();
}

/**
 * 完成 assistant 消息：最终渲染 + 高亮代码块
 */
function finalizeAssistantMessage() {
    if (currentAssistantDiv && deltaBuffer.length > 0) {
        let content = currentAssistantDiv.querySelector('.message-content');
        if (content) {
            content.innerHTML = renderMarkdownInline(deltaBuffer);
        }
        enhanceCodeBlocks(currentAssistantDiv);
    }
    currentAssistantDiv = null;
    deltaBuffer = '';
    rafScheduled = false;
}

/**
 * Markdown 渲染（流式 + 最终）
 * 优先 marked.js + DOMPurify，离线降级为纯文本
 */
function renderMarkdownInline(text) {
    if (typeof marked !== 'undefined' && typeof DOMPurify !== 'undefined') {
        try {
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
            return DOMPurify.sanitize(raw);
        } catch (e) {
            return escapeHtml(text);
        }
    }
    // 离线降级：纯文本 + 转义
    return escapeHtml(text);
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

    // 侧边栏 tab 切换
    document.querySelectorAll('.sidebar-tab').forEach(function(btn) {
        btn.addEventListener('click', function() {
            switchSidebarTab(this.dataset.tab);
        });
    });

    // 配置按钮：打开配置模态框
    document.getElementById('config-btn').addEventListener('click', openConfigModal);

    // 添加工作区按钮
    document.getElementById('add-workspace-btn').addEventListener('click', openWorkspaceModal);

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
:root, [data-theme="light"] {
    --bg-primary: #ffffff;
    --bg-secondary: #f7f7f8;
    --bg-tertiary: #ececf1;
    --text-primary: #1a1a1a;
    --text-secondary: #6b6b6b;
    --accent: #2563eb;
    --accent-dim: #93c5fd;
    --border: #e5e5e5;
    --success: #16a34a;
    --error: #dc2626;
    --warning: #d97706;
}

[data-theme="starfrost"] {
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
    width: 280px;
    background: var(--bg-secondary);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
}

/* 分区切换 tab */
.sidebar-tabs {
    display: flex;
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
}
.sidebar-tab {
    flex: 1;
    padding: 8px 4px;
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 12px;
    cursor: pointer;
    border-bottom: 2px solid transparent;
    transition: color 0.15s, border-color 0.15s;
}
.sidebar-tab:hover { color: var(--text-primary); }
.sidebar-tab.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
}

/* 分区面板 */
.sidebar-panel {
    display: none;
    flex: 1;
    flex-direction: column;
    overflow: hidden;
}
.sidebar-panel.active { display: flex; }

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
    font-size: 13px;
}

.session-item {
    padding: 10px 14px;
    cursor: pointer;
    border-left: 3px solid transparent;
    transition: background 0.15s, border-color 0.15s;
}

.session-item:hover {
    background: var(--bg-tertiary);
}

.session-item.active {
    background: var(--bg-tertiary);
    border-left-color: var(--accent);
}

.session-title {
    font-size: 13px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    margin-bottom: 2px;
}

.session-time {
    font-size: 11px;
    color: var(--text-secondary);
}

/* ====== 技能列表 ====== */
.skill-list, .mcp-list {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0;
}
.skill-list .empty, .mcp-list .empty {
    padding: 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 12px;
    line-height: 1.6;
}
.skill-item {
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
}
.skill-item.skill-enabled .skill-name { color: var(--success); }
.skill-item.skill-disabled .skill-name { color: var(--text-secondary); }
.skill-name { font-size: 13px; font-weight: 500; margin-bottom: 4px; }
.skill-desc {
    font-size: 11px;
    color: var(--text-secondary);
    line-height: 1.4;
    margin-bottom: 4px;
}
.skill-meta { font-size: 10px; color: var(--text-secondary); }

/* ====== MCP 列表 ====== */
.mcp-item {
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
}
.mcp-name { font-size: 13px; font-weight: 500; margin-bottom: 4px; }
.mcp-transport {
    font-size: 11px;
    color: var(--text-secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* ====== 工作区列表 ====== */
.workspace-list {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0;
}
.workspace-list .empty {
    padding: 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 12px;
    line-height: 1.6;
}
.workspace-item {
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
    cursor: pointer;
    position: relative;
    transition: background 0.15s;
}
.workspace-item:hover { background: var(--bg-tertiary); }
.workspace-name { font-size: 13px; font-weight: 500; margin-bottom: 4px; }
.workspace-path {
    font-size: 11px;
    color: var(--text-secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-family: monospace;
}
.workspace-del {
    position: absolute;
    top: 8px;
    right: 8px;
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 16px;
    cursor: pointer;
    padding: 0 4px;
    line-height: 1;
}
.workspace-del:hover { color: var(--error); }
.workspace-tip {
    padding: 12px 14px;
    background: var(--bg-tertiary);
    color: var(--accent);
    font-size: 12px;
    white-space: pre-line;
    line-height: 1.5;
    border-bottom: 1px solid var(--border);
}
.workspace-item.active {
    background: var(--bg-tertiary);
    border-left: 3px solid var(--accent);
}
.workspace-item.active .workspace-name { color: var(--accent); }

/* ====== 目录浏览选择器 ====== */
.dir-browser {
    border: 1px solid var(--border);
    border-radius: 6px;
    margin: 8px 0;
    background: var(--bg-secondary);
}
.dir-browser-path {
    padding: 8px 10px;
    font-family: monospace;
    font-size: 11px;
    color: var(--accent);
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
.dir-browser-list {
    max-height: 180px;
    overflow-y: auto;
    padding: 4px 0;
}
.dir-item {
    padding: 6px 12px;
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
.dir-item:hover { background: var(--bg-tertiary); color: var(--accent); }
.dir-browser-actions {
    display: flex;
    gap: 8px;
    padding: 8px 10px;
    border-top: 1px solid var(--border);
}

/* ====== 配置表单 ====== */
.config-form {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0;
}
.config-form .empty {
    padding: 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 12px;
}
.config-group {
    padding: 8px 14px;
    border-bottom: 1px solid var(--border);
}
.config-group-title {
    font-size: 11px;
    font-weight: bold;
    color: var(--text-secondary);
    text-transform: uppercase;
    margin-bottom: 8px;
    letter-spacing: 0.5px;
}
.config-row {
    display: flex;
    flex-direction: column;
    margin-bottom: 10px;
}
.config-row label {
    font-size: 11px;
    color: var(--text-secondary);
    margin-bottom: 4px;
}
.config-row input {
    padding: 6px 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: 4px;
    color: var(--text-primary);
    font-size: 12px;
    font-family: monospace;
}
.config-row input:focus {
    outline: none;
    border-color: var(--accent);
}
.config-save-btn {
    display: block;
    width: calc(100% - 28px);
    margin: 12px 14px;
    padding: 8px;
    background: var(--accent);
    color: var(--bg-primary);
    border: none;
    border-radius: 4px;
    font-size: 13px;
    font-weight: bold;
    cursor: pointer;
    transition: opacity 0.15s;
}
.config-save-btn:hover { opacity: 0.9; }
.config-save-btn.saved { background: var(--success); }

/* ====== 模态对话框 ====== */
.modal-overlay {
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
}
.modal-overlay.hidden { display: none; }
.modal-dialog {
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: 8px;
    width: 480px;
    max-width: 90vw;
    max-height: 80vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 8px 32px rgba(0,0,0,0.3);
}
.config-dialog { width: 560px; }
.modal-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 18px;
    border-bottom: 1px solid var(--border);
    font-weight: bold;
    font-size: 15px;
}
.modal-close {
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 20px;
    cursor: pointer;
    padding: 0 4px;
    line-height: 1;
}
.modal-close:hover { color: var(--error); }
.modal-body {
    padding: 16px 18px;
    overflow-y: auto;
    flex: 1;
}
/* 模态框内的配置表单复用 .config-group/.config-row 样式 */
.modal-body .config-form { padding: 0; }

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
