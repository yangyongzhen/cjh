<div align="center">

# cjh · Cangjie Coding Agent

**An interactive coding agent built from scratch in Huawei's Cangjie language.**

Describe tasks in natural language → the Agent understands intent, plans autonomously, calls tools, observes results, and iterates until done. The entire workflow is rendered live in a TUI, and can also be driven remotely via Web.

[Features](#-features) · [Quick Start](#-quick-start) · [Architecture](#-architecture) · [Plugin Ecosystem](#-plugin-ecosystem--trust-chain) · [Docs](#-docs) · [Roadmap](#-roadmap)

</div>

---

## 🌟 Why cjh

| | |
|---|---|
| **Cangjie-native Coding Agent** | From Agent core, tool system, TUI rendering to Web Server — all implemented in Cangjie, a flagship AI coding practice in the Cangjie ecosystem. |
| **Single Binary · Zero Runtime Deps** | Cangjie `cjnative` static compilation. One binary, no Python/Node environment needed. |
| **Multi-Provider Out of the Box** | OpenAI / DeepSeek / GLM / Anthropic / Ollama all compatible, `/provider` hot-swap. |
| **Plugin Trust Chain** | SHA256 checksum + SM2 national cryptography signature verification (Cangjie native `stdx.crypto`), preventing supply chain poisoning. |
| **Concurrent Execution Engine** | DAG dependency analysis + topological group scheduling. LLM parallel tool calls are automatically executed concurrently. |
| **Web Native Support** | Built-in HTTP Server + WebSocket streaming conversation + REST API + frontend SPA, remotely driving the Agent. |

## 🚀 Features

### Agent Core

- **Multi-turn tool call loop**: message history → LLM → tool call → result feedback → re-call, supporting complex task orchestration
- **Three-domain Capability security model**: commands / tools / resources whitelist + dangerous operation approval chain
- **Auto Compaction**: automatically triggers LLM summary compression for early history when message count exceeds threshold
- **Project instructions**: auto-loads `AGENTS.md` / `.atomcode.md` project instructions injected into system prompt

### Tool System (7 built-in + extensible)

| Tool | Description |
|---|---|
| `bash` | Execute shell commands, capture stdout/stderr |
| `read_file` | Read file, large files return symbol skeleton, offset/limit expand on demand |
| `write_file` | Write file (create/overwrite) |
| `hashline_edit` | Line number anchor `@@N` + content verification editing |
| `grep` | Recursive directory tree search, gitignore-aware |
| `list_dir` | List directory tree |
| `todo_write` | LLM manages task list via tool calls |

### Concurrent Execution Engine (V2d)

- **DAG dependency analysis**: extracts resource access `(path, isWrite)` from `ToolCall`, automatically builds dependency graph
- **Topological group scheduling**: tools in the same group spawn concurrently, groups execute serially, maintaining LLM's original feedback order
- **Performance baseline measurement**: `parallelBatches` / `parallelSavedMs` / `maxParallelism` three-dimensional stats

### LLM Provider Layer

| Provider | Protocol | Notes |
|---|---|---|
| **OpenAI** | OpenAI API | GPT-4o / GPT-4o-mini |
| **DeepSeek** | OpenAI compatible | deepseek-chat / deepseek-v4-flash, supports prompt_cache_hit_tokens |
| **GLM** | OpenAI compatible | glm-4-flash, Zhipu AI |
| **Ollama** | OpenAI compatible (no TLS) | Local model, apiKey can be empty |
| **Anthropic** | Anthropic API | Claude series, supports cache_read_input_tokens |
| **MCP Server** | MCP protocol (stdio) | Configured via `mcp_servers`, tools auto-registered |

- **SSE streaming parsing**: chunk-by-chunk reading, UTF-8 safe splitting, event frame callback
- **Streaming accumulator**: incremental text rendered live (diff-rendering frame-by-frame)
- **Provider hot-swap**: `/model` `/provider` runtime switching, history preserved

### TUI Terminal Interface

- **Full-screen TUI**: diff rendering + ANSI escape, termios raw mode (pure libc FFI)
- **Markdown rendering**: headings / lists / code blocks / tables / links
- **6 themes**: starfrost / classic / catppuccin / rose-pine / solarized / monokai, `/theme` live switching
- **Multi-line editor**: Ctrl+E to enter, Alt+Enter to submit
- **Slash command completion**: `/` triggers dropdown completion
- **Tasks panel**: Agent's built-in task list displayed in real time
- **Round summary bar**: `✓ 2 rounds · 3 tools · 42.6s · 1.53K tokens · 99% cached`
- **Approval popup**: dangerous operations with embedded y/n approval
- **Welcome view**: two-column layout (logo+model / Tips+sessions)

### Web Support (v1.3.0)

- **HTTP Server**: static assets + REST API + WebSocket
- **WebSocket streaming conversation**: `ChatRequest` → `tool_start` → `tool_result` → streaming `delta` → `done`
- **REST API**: sessions / models / tasks / health
- **Frontend SPA**: vanilla JS + marked.js + DOMPurify + highlight.js, 6 themes
- **auth_token auth middleware** + **startup security audit log**

### Sessions & Memory

- **Tree sessions**: session branching/forking, parent chain tracking, `/tree` tree listing
- **Session restore**: `--resume <id>` restore historical session
- **Session list**: `--list` list all sessions
- **Auto Compaction**: auto LLM summary compression when messages exceed threshold
- **Tool result truncation & backtrack**: results exceeding threshold keep head+tail + full spill to `~/.cjh/spill/` + ellipsis marker contains spill path

### Skill System

- **Skills as Markdown**: `~/.cjh/skills/<name>.md`, frontmatter declares metadata + tools
- **Skill whitelist**: `enabled_skills` config to enable skills
- **Skill-carried tools**: skill frontmatter's `tools` section registers declarative tools

### Headless Mode

- **JSON mode**: `--mode json` headless mode, outputs JSON results (script-parseable)
- **CLI mode**: `--cli` command-line interactive mode
- **Mock mode**: `--mock` verification mode using MockProvider, testable without API Key

## 🔧 Quick Start

### Prerequisites

- Cangjie SDK 1.0.5+ (`cjc` / `cjpm`)
- stdx extension standard library
- Linux (this project is pure terminal, no GUI dependency)

### Build

```bash
# Activate Cangjie environment
source /path/to/cj-env.sh

# Build
cjpm build
```

### Configuration

```bash
# Set API Key (any one)
export OPENAI_API_KEY=sk-xxx        # OpenAI
export DEEPSEEK_API_KEY=sk-xxx      # DeepSeek
export DASHSCOPE_API_KEY=sk-xxx     # Tongyi Qianwen
export CJH_API_KEY=sk-xxx           # Generic

# Optional: specify endpoint and model
export CJH_BASE_URL=https://api.deepseek.com
export CJH_MODEL=deepseek-chat
```

### Run

```bash
# TUI mode (default)
./target/release/bin/main

# CLI mode (plain text interaction)
./target/release/bin/main --cli

# JSON headless mode (script integration)
./target/release/bin/main --mode json "Search for TODO with grep"

# Restore historical session
./target/release/bin/main --resume <session-id>

# Mock mode (demo without API Key)
CJH_MOCK=1 ./target/release/bin/main

# Web mode (remote Agent driving)
./target/release/bin/main web --port 8765 --token my-secret
```

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `CJH_API_KEY` | API Key (any) | — |
| `CJH_BASE_URL` | LLM endpoint | OpenAI |
| `CJH_MODEL` | Model name | gpt-4o-mini |
| `CJH_PROVIDER` | Provider switch (openai/anthropic/ollama) | openai |
| `CJH_MOCK` | `1` enables mock | off |
| `CJH_CONFIG_DIR` | Config directory | `~/.cjh` |

## 📁 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    cjh main entry (main.cj)              │
│              CLI / TUI / JSON / Web / Mock               │
├─────────────────────────────────────────────────────────┤
│  TUI Layer (tui/)       │  Web Layer (web/)             │
│  Diff render + keys     │  HTTP Server + WebSocket       │
├─────────────────────────────────────────────────────────┤
│              Agent Runtime (agent/loop.cj)              │
│       Message state machine + Tool call + DAG sched     │
├──────────────────┬──────────────────────────────────────┤
│  Tools (tools/)  │  LLM Layer (libs/cjllm/)            │
│  bash/read/write │  OpenAI / Anthropic / Ollama / Mock  │
│  grep/list/edit  │  SSE streaming parser + accumulator  │
│  plugin/mcp/todo │                                      │
├──────────────────┴──────────────────────────────────────┤
│  Infrastructure libs (libs/)                            │
│  cjterm (Terminal UI) · cjcfg (Config) · cjutil (SHA256/SM2) │
└─────────────────────────────────────────────────────────┘
```

### Package Layout

| Package | Responsibility |
|---|---|
| `cjh.agent` | Agent main loop orchestration (message state machine + tool call + DAG concurrent scheduling) |
| `cjh.tools` | Tool interface, registry, built-in tools, plugin system, MCP client |
| `cjh.tui` | TUI application layer (conversation interface, Markdown rendering) |
| `cjh.web` | Web Server (HTTP + WebSocket + REST API + frontend SPA) |
| `cjterm` (libs/) | **Independent terminal UI library**: ANSI / diff rendering / termios / 6 themes (pure libc FFI, reusable) |
| `cjllm` (libs/) | **Independent LLM protocol library**: OpenAI / Anthropic / Ollama / SSE / Mock |
| `cjcfg` (libs/) | **Independent config library**: settings.json / auth.json / env vars / session management |
| `cjutil` (libs/) | **Independent utility library**: SHA256 / SM2 signature / UTF-8 / JSON repair / logging |

## 🔌 Plugin Ecosystem & Trust Chain

### Plugin System

cjh supports writing plugin tools with shell scripts. `~/.cjh/plugins/<name>/plugin.json` declares metadata:

```json
{
  "name": "echo-test",
  "version": "1.0.0",
  "tools": [{
    "name": "echo",
    "description": "Echo back the message parameter.",
    "command": "tools/echo.sh",
    "is_read_only": true,
    "parameters": {
      "type": "object",
      "properties": { "message": { "type": "string" } },
      "required": ["message"]
    }
  }]
}
```

Tool scripts receive parameters via the `CJH_TOOL_ARGS` environment variable (JSON) and output results to stdout.

### Trust Chain (V3 Step 1+2)

Plugins can declare four fields: `checksum` / `publisher` / `pubkey` / `signature`. cjh automatically verifies them on load:

1. **SHA256 checksum** (Step 1): `sha256DirExcluding` computes the plugin directory fingerprint, compared against the `checksum` field, detecting file tampering
2. **SM2 signature verification** (Step 2): uses Cangjie native `stdx.crypto.keys.SM2PublicKey.verify` to verify signature, preventing supply chain poisoning

```json
{
  "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "publisher": "github:alice",
  "pubkey": "3059301306072a8648ce3d020106082a811ccf5501822d03420004...",
  "signature": "3045022100fe42fa103dbdeed8bc8c8665017583d8aa574878..."
}
```

**Signatures are optional.** Plugins without signature fields load normally; signatures are just trust chain hardening, not mandatory. Set `"require_signature": true` in `settings.json` to force plugins to carry signatures.

See [Plugin Signing & Contribution Guide](docs/插件签名与贡献指南.md).

### MCP Protocol Support

cjh has a built-in MCP client supporting stdio transport + JSON-RPC 2.0. After configuring `mcp_servers`, MCP server tools are automatically registered to the Agent:

```json
{
  "mcp_servers": {
    "my-mcp": {
      "transport": "stdio",
      "command": "node",
      "args": ["mcp-server.js"]
    }
  }
}
```

## ⌨️ Slash Commands

| Command | Description |
|---|---|
| `/help` | Show help |
| `/new` | Start new session |
| `/resume [id]` | Restore historical session |
| `/model [id]` | List/switch model |
| `/provider [name] [key]` | Switch provider |
| `/theme [name]` | Switch theme |
| `/compact` | Manually compress history |
| `/tree` | Tree-list session branches |
| `/fork` | Fork new session from current |
| `/skills` | List skills and enabled status |
| `/task` | Task management |
| `/settings` | View sampling parameters |
| `/quit` | Exit |

## 📊 Version History

| Version | Main Features |
|---|---|
| v1.0.0 | Initial release: TUI + Agent loop + basic tools |
| v1.1.0 | Memory layering + plugin system + tree sessions + Ollama support |
| v1.2.0 | Concurrent execution engine + tool efficiency + Tasks panel |
| v1.2.1 | Starfrost theme system + /theme switching |
| v1.2.2 | Round summary bar + /compact + /tree + /fork |
| v1.2.3 | SSE idle timeout + tool result truncation & backtrack + MCP protocol support + 6 themes |
| **v1.3.0** | **Web support + plugin trust chain (SHA256 + SM2 signature) + require_signature config** |

## 🗺️ Roadmap

### ✅ Completed

- [x] **V1**: Agent core + tools + dual protocol + TUI + sessions + mock
- [x] **V2a**: Three-domain Capability + approval chain
- [x] **V2b Step 1+2**: plugin.json + shell tool plugins + event hooks
- [x] **V2b MCP extension point**: McpClient stdio + McpTool proxy + McpManager
- [x] **V2c**: Compaction + AGENTS.md project instructions
- [x] **V2d concurrent engine**: DAG dependency analysis + topological group scheduling + performance baseline
- [x] **V3 trust chain Step 1+2**: SHA256 checksum + SM2 signature verification
- [x] **Web support Step 1-5**: HTTP Server + WebSocket + REST API + frontend SPA + auth

### 🔜 In Progress

- [ ] **V3 trust chain Step 3**: Trust management CLI (`/cjh trust` / `untrust` / `trust-list`)
- [ ] **V2e IM gateway**: Channel abstraction + Web channel + remote approval

### 📋 Planned

- [ ] **V2b Step 3**: WASM tool sandbox + central registry + `cjh install`
- [ ] **Web TLS**: `ServerBuilder.tlsConfig` support
- [ ] **V4 multi-agent**: Multi-agent collaboration + HarmonyOS native adaptation

## 📚 Docs

- [Architecture & Design v2](docs/方案与架构设计-v2.md) — Project design and architecture
- [Feature Checklist](docs/cjh功能清单.md) — Complete feature list
- [Plugin System Implementation](docs/插件系统实现方案.md) — Plugin system design
- [Plugin Signing & Contribution Guide](docs/插件签名与贡献指南.md) — Trust chain and plugin publishing
- [Web Support Implementation](docs/Web支持实现方案.md) — Web Server design
- [Progress Log](docs/进度记录.md) — Development progress and status tracking
- [Dev Docs & Pitfall Records](docs/开发文档与踩坑记录.md) — Cangjie engineering pitfalls

## 🤝 Cangjie Ecosystem Value

cjh is a complete practice of the Cangjie language in the **AI coding agent** domain, contributing to the Cangjie ecosystem:

| Contribution | Description |
|---|---|
| **cjterm** | Independent terminal UI library (ANSI / diff rendering / termios / 6 themes), pure libc FFI, reusable by any Cangjie terminal project |
| **cjllm** | Independent LLM protocol library (OpenAI / Anthropic / Ollama / SSE / Mock), reusable by any Cangjie AI project |
| **cjutil** | Independent utility library (SHA256 / SM2 signature / UTF-8 / JSON repair / logging), common infrastructure for the Cangjie ecosystem |
| **MCP Protocol Implementation** | The first MCP client implementation in Cangjie, paving the way for the Cangjie ecosystem to access the MCP tool network |
| **Plugin Trust Chain** | A practical example of Cangjie `stdx.crypto` national cryptography SM2 in plugin security scenarios |
| **Engineering Pitfall Records** | Complete records of FFI / compilation / concurrency / TLS pitfalls in Cangjie development, lowering the barrier for newcomers |

## 🔨 Development

### Develop a Tool

```cangjie
public class GrepTool <: CjhTool {
    public init() {}
    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("Regex to search"))
        props.add("path", JsonSchema.str("Search path"))
        return ToolSpec("grep", "Search text in files",
            JsonSchema.object(props, ArrayList<String>(["pattern", "path"])))
    }
    public func execute(args: JsonObject): ToolResult {
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        // ... implement search
        return ToolResult("result", false)
    }
    public func isReadOnly(): Bool { true }
}

// Register
let registry = ToolRegistry()
registry.register(GrepTool())
```

### Project Structure

```
cjh/
├── src/                    # Main program
│   ├── agent/loop.cj       # Agent main loop + DAG concurrent scheduling
│   ├── tools/              # Tool system (built-in tools + plugins + MCP)
│   ├── tui/                # TUI application layer
│   ├── web/                # Web Server (HTTP + WS + REST + frontend)
│   └── main.cj             # CLI/TUI/JSON/Web/Mock entry
├── libs/                   # Independent reusable libraries
│   ├── cjterm/             # Terminal UI library (ANSI / diff rendering / termios / themes)
│   ├── cjllm/              # LLM protocol library (OpenAI / Anthropic / Ollama / SSE)
│   ├── cjcfg/              # Config library (settings.json / auth.json / sessions)
│   └── cjutil/             # Utility library (SHA256 / SM2 / UTF-8 / JSON repair / logging)
├── example/                # Examples
│   ├── plugins/            # Plugin examples (echo-test / log-pruner / signed-demo)
│   └── mcp/                # MCP server examples
├── docs/                   # Documentation
└── cjpm.toml               # Cangjie package manager config
```

## 📄 License

MIT
