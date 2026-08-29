---
name: example
description: 示例技能，演示 frontmatter + 正文指令 + 声明式工具的完整形态
tools:
  [
    {
      "name": "echo_hi",
      "description": "向指定用户打招呼",
      "command": "echo Hi, ${who}!",
      "args": { "who": "要打招呼的用户名" }
    },
    {
      "name": "disk_usage",
      "description": "查看指定目录的磁盘占用",
      "command": "du -sh ${path}",
      "args": { "path": "要查看的目录路径" }
    }
  ]
---

# 示例技能

这是一个用于验证 V2b Skills 系统端到端的示例技能文件。

## 能力说明

- **正文部分**会作为指令注入到 system prompt 中，告诉模型该技能的用途
- **tools 段**声明的声明式工具会被注册到 ToolRegistry，模型可按需调用
- 编辑 `~/.cjh/settings.json` 的 `enabled_skills` 数组可控制开关（空=全部启用）

## 用法

在 TUI 或 CLI 中直接让模型使用，例如：
- "用 echo_hi 向 Alice 打招呼"
- "用 disk_usage 查看 /tmp 的磁盘占用"
