#!/bin/bash
# signed-demo 插件工具
# 参数通过环境变量 CJH_TOOL_ARGS 传递（JSON 字符串）
# 依赖 jq 解析 JSON

if [ -z "$CJH_TOOL_ARGS" ]; then
  echo "error: missing CJH_TOOL_ARGS environment variable" >&2
  exit 1
fi

NAME=$(echo "$CJH_TOOL_ARGS" | jq -r '.name // empty')

if [ -z "$NAME" ]; then
  echo "error: missing 'name' parameter" >&2
  exit 1
fi

echo "[signed-demo] Hello, ${NAME}! This plugin is SM2-signed."
