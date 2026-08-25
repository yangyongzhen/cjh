# cjh 示例插件

本目录包含 cjh 插件系统的示例插件，供参考和快速上手。

## 目录结构

```
example/plugins/
├── echo-test/                    # 工具插件示例
│   ├── plugin.json               # 插件元数据
│   └── tools/
│       └── echo.sh               # 工具实现（shell 脚本）
│
└── log-pruner/                   # 事件钩子插件示例
    ├── plugin.json
    └── hooks/
        └── on_tool_result.sh     # on_tool_result 钩子
```

## 安装示例插件

将 `example/plugins/` 下的插件目录复制到 `~/.cjh/plugins/`：

```bash
cp -r example/plugins/* ~/.cjh/plugins/
chmod +x ~/.cjh/plugins/echo-test/tools/echo.sh
chmod +x ~/.cjh/plugins/log-pruner/hooks/on_tool_result.sh
```

cjh 启动时会自动扫描 `~/.cjh/plugins/` 并加载插件。

## echo-test：工具插件示例

最简单的插件——注册一个 `echo` 工具，回显传入的 `message` 参数。

### plugin.json

```json
{
  "name": "echo-test",
  "version": "1.0.0",
  "description": "测试插件：回显传入的 message 参数",
  "tools": [
    {
      "name": "echo",
      "description": "Echo back the message parameter.",
      "command": "tools/echo.sh",
      "is_read_only": true,
      "parameters": {
        "type": "object",
        "properties": {
          "message": { "type": "string", "description": "Message to echo back" }
        },
        "required": ["message"]
      }
    }
  ]
}
```

### 工具实现协议

插件工具通过**环境变量**接收参数：

| 环境变量 | 内容 |
|----------|------|
| `CJH_TOOL_ARGS` | LLM 传入的参数（JSON 字符串） |

工具脚本通过 stdout 输出结果文本（回填到消息历史），退出码 0=成功、非0=失败。

### echo.sh

```bash
#!/bin/bash
# 参数通过环境变量 CJH_TOOL_ARGS 传递（JSON 字符串）
MESSAGE=$(echo "$CJH_TOOL_ARGS" | jq -r '.message // empty')
echo "[echo plugin] message: ${MESSAGE}"
```

### 验证

```
❯ 用 echo 工具回显消息 "hello from plugin"
▶ echo message: hello from plugin
  ↳ echo: [echo plugin] message: hello from plugin
✓ 2 rounds · 1 tools · 4.062s · 4.855K tokens · 96% cached
```

## log-pruner：事件钩子插件示例

注册一个 `on_tool_result` 事件钩子——工具结果超 1000 字符时截断到头 500 + 尾 500 + 省略标记。

### plugin.json

```json
{
  "name": "log-pruner",
  "version": "1.0.0",
  "description": "工具结果裁剪钩子：超 1000 字符的结果截断到头 500 + 尾 500",
  "hooks": {
    "on_tool_result": "hooks/on_tool_result.sh"
  }
}
```

### 钩子实现协议

钩子脚本通过**环境变量**接收事件数据：

| 环境变量 | 内容 |
|----------|------|
| `CJH_HOOK_DATA` | 事件数据（JSON 字符串） |

`on_tool_result` 事件数据格式：

```json
{
  "tool": "bash",
  "content": "命令输出..."
}
```

钩子脚本通过 stdout 输出**改写后的 content**，退出码 0=正常、非0=失败（用原内容）。

### on_tool_result.sh

```bash
#!/bin/bash
CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')
LEN=${#CONTENT}

if [ "$LEN" -le 1000 ]; then
  echo "$CONTENT"
  exit 0
fi

HEAD=$(echo "$CONTENT" | head -c 500)
TAIL=$(echo "$CONTENT" | tail -c 500)
SKIPPED=$((LEN - 1000))
printf '%s\n\n[log-pruner 截断 %d 字符]\n\n%s' "$HEAD" "$SKIPPED" "$TAIL"
```

## 编写自己的插件

### 1. 创建插件目录

```bash
mkdir -p ~/.cjh/plugins/my-plugin/tools
```

### 2. 编写 plugin.json

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "我的插件",
  "tools": [
    {
      "name": "my_tool",
      "description": "我的工具",
      "command": "tools/my_tool.sh",
      "is_read_only": true,
      "parameters": {
        "type": "object",
        "properties": {
          "input": { "type": "string", "description": "输入参数" }
        },
        "required": ["input"]
      }
    }
  ],
  "hooks": {
    "on_tool_result": "hooks/on_tool_result.sh"
  }
}
```

### 3. 编写工具脚本

```bash
#!/bin/bash
INPUT=$(echo "$CJH_TOOL_ARGS" | jq -r '.input // empty')
echo "处理结果: ${INPUT}"
```

### 4. 编写钩子脚本（可选）

```bash
#!/bin/bash
CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')
# 改写 content...
echo "$CONTENT"
```

### 5. 加执行权限

```bash
chmod +x ~/.cjh/plugins/my-plugin/tools/my_tool.sh
chmod +x ~/.cjh/plugins/my-plugin/hooks/on_tool_result.sh
```

### 6. 启动 cjh 验证

```bash
cjh
❯ 用 my_tool 工具处理输入 "test"
```

## 配置

### 启用插件白名单

在 `~/.cjh/settings.json` 中配置 `enabled_plugins`：

```json
{
  "enabled_plugins": ["echo-test", "log-pruner"]
}
```

未配置或空数组 = 全部启用。

### 事件钩子列表

| 事件 | 触发时机 | 可拦截/改写 |
|------|----------|-------------|
| `on_tool_result` | 工具执行完毕、回填消息历史之前 | ✅ 改写 content |

未来扩展：`on_tool_start`、`on_delta`、`on_compaction`、`on_session_end`。

## 参考文档

- [插件系统实现方案](../docs/插件系统实现方案.md)
- [cjh 方案与架构设计](../docs/方案与架构设计-v2.md)
