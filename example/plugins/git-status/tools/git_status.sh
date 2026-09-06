#!/bin/bash
# git-status 插件工具：输出指定仓库的状态摘要
# 参数通过环境变量 CJH_TOOL_ARGS 传递（JSON 字符串）
# 依赖：bash + git + jq

if [ -z "$CJH_TOOL_ARGS" ]; then
  CJH_TOOL_ARGS="{}"
fi

PATH_ARG=$(echo "$CJH_TOOL_ARGS" | jq -r '.path // empty')
if [ -n "$PATH_ARG" ]; then
  cd "$PATH_ARG" 2>/dev/null || { echo "error: cannot cd to ${PATH_ARG}" >&2; exit 1; }
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git repository" >&2
  exit 1
fi

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH="(detached)"

CHANGED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
LATEST=$(git log -1 --format='%h %s' 2>/dev/null)

echo "branch:   ${BRANCH}"
echo "changes:  ${CHANGED} file(s) modified/untracked, ${STAGED} staged"
echo "latest:   ${LATEST}"
