#!/bin/bash
# log-pruner 钩子：工具结果超 1000 字符时截断到头 500 + 尾 500 + 省略标记
# 事件数据通过环境变量 CJH_HOOK_DATA 传递（JSON 字符串）
# 依赖 jq 解析 JSON

if [ -z "$CJH_HOOK_DATA" ]; then
  exit 0
fi

CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')
LEN=${#CONTENT}

if [ "$LEN" -le 1000 ]; then
  # 短结果：原样输出
  echo "$CONTENT"
  exit 0
fi

# 长结果：头 500 + 省略标记 + 尾 500
HEAD=$(echo "$CONTENT" | head -c 500)
TAIL=$(echo "$CONTENT" | tail -c 500)
SKIPPED=$((LEN - 1000))

printf '%s\n\n[log-pruner 截断 %d 字符]\n\n%s' "$HEAD" "$SKIPPED" "$TAIL"
