#!/bin/bash
# 最小 MCP 服务器示例（stdio 传输，JSON-RPC 2.0）
#
# 实现 initialize + tools/list + tools/call 三个方法
# 提供一个 "echo" 工具：回显传入的 message 参数
#
# 协议参考：https://modelcontextprotocol.io/specification/2025-03-26
# 消息格式：每行一条 JSON-RPC 消息，stdin/stdout 交换

# 强制 stdout 行缓冲（pipe 模式下 bash 默认全缓冲，会导致 cjh 读不到响应）
if command -v stdbuf > /dev/null 2>&1; then
  exec stdbuf -oL -i0 "$0" "$@"
fi

# 读取 stdin 每行一条 JSON-RPC 消息
while IFS= read -r line; do
  # 提取 method 字段
  method=$(echo "$line" | jq -r '.method // empty')
  id=$(echo "$line" | jq -r '.id // empty')

  case "$method" in
    "initialize")
      # 握手响应：声明服务器能力
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"echo-mcp-server","version":"1.0.0"}}}\n' "$id"
      ;;
    "notifications/initialized")
      # 通知无响应
      :
      ;;
    "tools/list")
      # 返回工具列表
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo back the message parameter","inputSchema":{"type":"object","properties":{"message":{"type":"string","description":"Message to echo back"}},"required":["message"]},"annotations":{"readOnlyHint":true}}]}}\n' "$id"
      ;;
    "tools/call")
      # 调用工具
      tool_name=$(echo "$line" | jq -r '.params.name // empty')
      message=$(echo "$line" | jq -r '.params.arguments.message // empty')

      if [ "$tool_name" = "echo" ]; then
        if [ -z "$message" ]; then
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"error: missing message parameter"}],"isError":true}}\n' "$id"
        else
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"[mcp echo] %s"}],"isError":false}}\n' "$id" "$message"
        fi
      else
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown tool: %s"}}\n' "$id" "$tool_name"
      fi
      ;;
    *)
      # 未知方法
      if [ -n "$id" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found: %s"}}\n' "$id" "$method"
      fi
      ;;
  esac
done
