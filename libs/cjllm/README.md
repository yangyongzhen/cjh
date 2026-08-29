# cjllm · 仓颉 LLM 协议库

**多 Provider 的 LLM 客户端协议抽象**——OpenAI 兼容 / Anthropic Messages / Ollama / Mock，流式 + 工具调用 + token 统计。

## 特性

| 特性 | 说明 |
|---|---|
| **多协议** | OpenAI 兼容（OpenAI/DeepSeek/通义/GLM）、Anthropic Messages、Ollama（本地，apiKey 可空）、Mock（离线测试） |
| **流式输出** | SSE 解析（`SseParser`）+ `StreamAccumulator` 增量累积，工具调用/文本混合流 |
| **工具调用** | `ToolCall` 协议（tool_calls 数组），多轮工具循环数据模型 |
| **token 统计** | `TokenUsage`（输入/输出/缓存命中：`prompt_cache_hit_tokens`、`cache_read_input_tokens`） |
| **容错** | 429/5xx 重试（备用 key 轮换由宿主实现）、mojibake 修复（`MojibakeFix`，中文乱码整体修复） |
| **协议无关** | `LlmProvider` 接口 + `ToolSpec` 工具描述，宿主业务与协议解耦 |

## 快速开始

```toml
[dependencies]
  cjllm = { path = "../cjllm" }
  cjutil = { path = "../cjutil" }   # cjllm 依赖
  cjlog = { path = "../cjlog" }     # cjllm 依赖
```

```cangjie
import cjllm.*

// OpenAI 兼容（DeepSeek 等）
let provider = OpenAiProvider("https://api.deepseek.com/v1/chat/completions", "sk-xxx", "deepseek-chat")

// 或 Ollama 本地（无 key）
let ollama = OllamaProvider("http://localhost:11434/v1", "", "qwen2.5")

// 或 Mock（离线测试，无网络）
let mock = MockProvider("/tmp/mock_verify.txt")

// 流式对话
var msgs = ArrayList<ChatMessage>()
msgs.add(ChatMessage.user("用仓颉写个冒泡排序"))
let resp = provider.chatStream(msgs, ArrayList<ToolSpec>())
for (chunk in resp) {
    match (chunk) {
        case Some(text) => print(text)   // 流式文本
        case None => ()
    }
}
```

## 模块

| 文件 | 内容 |
|---|---|
| `provider.cj` | `LlmProvider` 接口、`ToolSpec`、`StreamAccumulator` |
| `message.cj` | `ChatMessage` / `ToolCall` / `ModelResponse` / `TokenUsage` |
| `openai.cj` | OpenAI 兼容协议（`OpenAiProvider`） |
| `anthropic.cj` | Anthropic Messages 协议（`AnthropicProvider`，cache_read_input_tokens） |
| `ollama.cj` | 本地模型（`OllamaProvider`） |
| `mock.cj` | 离线验证（`MockProvider`） |
| `sse.cj` | SSE 流解析 |
| `mojibake.cj` | 中文乱码修复 |
| `firecrawl.cj` | Firecrawl 网页抓取客户端 |

## 依赖

- 仓颉 std + **官方 stdx**（net.http/net.tls/crypto.x509/encoding.json）
- cjutil（工具）、cjlog（日志）——均为本系列仓颉库

## 许可

MIT
