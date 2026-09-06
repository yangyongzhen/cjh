#!/bin/bash
# tool-result-banner 钩子：在工具结果头部追加 [tool: <name>] 横幅
# 事件数据通过环境变量 CJH_HOOK_DATA 传递（JSON 字符串）
# 依赖 jq 解析 JSON

if [ -z "$CJH_HOOK_DATA" ]; then
  exit 0
fi

TOOL=$(echo "$CJH_HOOK_DATA" | jq -r '.tool // "unknown"')
CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')

printf '[tool: %s]\n%s' "$TOOL" "$CONTENT"
