<div align="center">

# cjh · Cangjie Coding Agent Harness

**An interactive coding agent harness built from scratch in Huawei's Cangjie language.**

Describe tasks in natural language → the Agent understands intent, plans autonomously, calls tools, observes results, and iterates until done. The entire workflow is rendered live in a TUI, and can also be driven remotely via Web.

**cjh is a coding agent harness natively implemented in Cangjie**: single-binary zero-dependency distribution (one file = one agent), a plugin trust chain backed by language-level memory safety, and systematic engineering optimization around two hard metrics: **token efficiency** + **execution speed**. Driven both from the TUI and remotely via Web, cjh is evolving toward **parallel multi-agent orchestration** (drawing on mature patterns like swarm, with a parallel-subagent orientation).

[Project Intent](#-project-intent-not-just-another-agent) · [Features](#-features) · [Two Hard Metrics](#-two-hard-metrics) · [Quick Start](#-quick-start) · [Architecture](#-architecture) · [Plugin Ecosystem](#-plugin-ecosystem--trust-chain) · [Docs](#-docs) · [Roadmap](#-roadmap)

</div>

---

## 🎯 Project Intent: Not Just Another Agent

> The coding-agent space already has mature solutions — codex, claude code, deepseek's dsh, pi, omp, and more — with features proven viable.
> **Building yet another "same agent in Cangjie" has no value.** cjh's foundation is the differentiation only Cangjie can provide:
> single-binary distribution, a strong safety DNA, multi-backend compilation, M:N native concurrency, and the **parallel multi-agent orchestration** these enable.

The core thesis: **mainstream agents have already proven features viable; piling on features is meaningless. Cangjie's unique advantages are the foundation.** Three hard constraints permeate all design:

1. **Don't reinvent the wheel**: features that mainstream agents have already proven viable — piling on features is meaningless;
2. **Cangjie's unique advantages are a prerequisite**: what other languages can easily do does not constitute competitiveness; learn from others' strengths, but the differentiation brought by Cangjie's language characteristics is more worth doing;
3. **Ecosystem contribution is the goal**: like dsh's plugin ecosystem, make the community willing to contribute to cjh — this requires plugin barriers to be low enough, distribution smooth enough, and trust mechanisms complete enough.

### How Cangjie Language Characteristics Hit Pain Points

Cangjie's characteristics happen to hit 4 of the above pain points. This is "why Cangjie" not "happened to use Cangjie":

| Cangjie Characteristic | Pain Point Solved | Differentiated Advantage |
|---|---|---|
| **Static compilation single binary** (cjnative) | Runtime baggage, distribution cost | No Node/Bun/npm dependency tree, `one file = one agent`, <10MB |
| **Strong safety language design** (safety DNA) | Security model | Plugin/skill compile-time type checking, memory safety, structurally reduced malicious code risk |
| **Multi-backend compilation + terminal-layer platform abstraction** (cjnative/cjvm + HarmonyOS slot) | Platform coverage | Native on Linux / macOS / Windows, HarmonyOS reserved; unified VT output with conditional-compiled platform backends — one source tree, multi-platform binaries ([design](docs/跨平台终端层设计方案.md)) |
| **M:N lightweight threads + high performance** | Context management, concurrency | Native concurrent processing of streaming/multi-agent, low overhead |
| **Domestic root technology** | Xinchu/self-controllable | Government, finance and other sensitive scenarios with no foreign runtime dependencies |

### cjh's Differentiation

Facing mature mainstream agents, cjh's differentiation is:

**1. Cangjie single binary → plugins with zero dependency, distribute and use**

dsh's plugin ecosystem is powerful, but the Node/npm dependency tree is an invisible barrier. cjh uses Cangjie's single binary: plugin = a shell script or a Cangjie package, no runtime environment configuration, `git clone` and use. Barriers are lowered to the minimum, community contribution willingness is highest.

**2. Cangjie strong safety DNA → structural improvement in plugin security**

Mainstream agents rely on sandbox + approval (runtime interception) for plugin security. cjh leverages Cangjie's compile-time type checking + memory safety to reduce malicious code risk at the language level. Combined with SHA256 checksum + SM2 national cryptography signature verification (Cangjie native `stdx.crypto`), forming a "language-level security + trust chain security" double insurance.

**3. Token efficiency + execution speed → comprehensive optimization of two hard metrics**

This is cjh's core distinguishing it from "feature piling". Drawing on Pi's token-saving engineering and OMP's hashline file rewriting, two hard metrics are systematically optimized. See the [Two Hard Metrics](#-two-hard-metrics) section below.

**4. Long-term goal: parallel multi-agent orchestration**

Multi-agent collaboration is already a mature industry pattern — OpenAI Swarm (handoff), crewAI, AutoGen, LangGraph and others each have implementations. **cjh claims no conceptual novelty here**; it draws on the pattern and picks its own implementation orientation:

| Pattern | Representative | Collaboration model |
|---|---|---|
| Handoff | OpenAI Swarm | **Serial**: one agent hands the conversation to another |
| Parallel sub-agents | cjh planning (V4) | **Parallel**: orchestrator forks sub-agents with isolated contexts working in parallel |

cjh's orientation is **parallel sub-agents + context isolation** (Linux-fork-like): sub-agents keep only task-local memory, saving tokens by isolating context per task; testing/coding/review can proceed in parallel. This orientation is naturally supported by Cangjie's characteristics — **M:N lightweight threads** make sub-agents in-process threads with zero scheduling overhead; **static single binary** keeps the whole multi-agent system in one file. The real combined advantage is the landing of "parallel + context isolation + in-process zero overhead + single-file distribution" together, not the concept itself. (V4 planned; the `task` tool already provides explore/worker foundations.)

**Saving tokens is the core goal of division-of-labor parallelism, not a byproduct.** Handing a whole task to a single agent means one entity is omniscient from start to finish — every step carries the global context, and tokens keep growing with task size. The common sense of team collaboration is that each person only needs to know the part relevant to their role — information distributed on demand should cost *less* overall. cjh's parallel sub-agents isolate context per task: each carries only task-local memory, aiming for **the same task with fewer tokens**. This is the essential difference from swarm-style handoff (the whole conversation is passed along, history keeps accumulating): the latter improves throughput, the former also optimizes cost.

## 🌟 Why cjh

| | |
|---|---|
| **Cangjie-native Coding Agent Harness** | From Agent core, tool system, TUI rendering to Web Server — all implemented in Cangjie, a flagship AI coding practice in the Cangjie ecosystem. |
| **Single Binary · Zero Runtime Deps** | Cangjie `cjnative` static compilation. One binary, no Python/Node environment needed. |
| **Token Efficiency + Execution Speed** | Drawing on Pi's token-saving engineering (tool result truncation & backtrack, auto compaction, prompt cache utilization), and OMP's hashline file rewriting (precise line-level editing, avoiding full file rewrites), comprehensive optimization of two hard metrics. |
| **Multi-Provider Out of the Box** | OpenAI / DeepSeek / GLM / Anthropic / Ollama all compatible, `/provider` hot-swap. |
| **Plugin Trust Chain** | SHA256 checksum + SM2 national cryptography signature verification (Cangjie native `stdx.crypto`), preventing supply chain poisoning. |
| **Web Native Support** | Built-in HTTP Server + WebSocket streaming conversation + REST API + frontend SPA, remotely driving the Agent. |
| **Cross-Platform Native** | Cangjie multi-backend compilation + terminal-layer platform abstraction (POSIX/Win32 backends via conditional compilation, unified VT output) — one source tree, multi-platform binaries: Linux static single file + Windows cross-compiled exe verified, macOS passthrough ([design](docs/跨平台终端层设计方案.md)). |

## 🎯 Two Hard Metrics

cjh's core design goal is two hard metrics: **token efficiency** + **execution speed**. These directly determine a coding agent's practical value and cost.

### Metric 1: Token Efficiency

LLM APIs charge per token, and coding agents' multi-turn tool calls accumulate staggering token costs. cjh draws on Pi agent's token-saving engineering, systematically optimizing from four dimensions:

| Optimization | Implementation | Effect |
|---|---|---|
| **Tool result truncation & backtrack** | Results exceeding threshold keep head+tail + **full spill** to `~/.cjh/spill/<sessionId>/<toolCallId>.txt` + ellipsis marker contains spill path, model can use `read_file` to read back on demand | Avoids losing middle information like some agents (e.g., d'sh) that only keep head and tail; spill-backtrack saves tokens without losing info |
| **Auto Compaction** | Message count OR estimated prompt tokens (real `usage.promptTokens`) exceeding threshold triggers LLM summary compression, `compactThreshold` / `compact_token_threshold` / `compactKeep` configurable | Long sessions don't blow context window, saves tokens and prevents overflow |
| **Prompt cache utilization** | DeepSeek `prompt_cache_hit_tokens` + Anthropic `cache_read_input_tokens` stats and display | Leverages Provider's prompt cache, repeated prefixes not repeatedly billed |
| **Round summary bar** | End of each round shows `✓ 2 rounds · 3 tools · 42.6s · 1.53K tokens · 99% cached` | Token consumption visible in real time, enabling manual intervention |

**The exquisite design of tool result truncation & backtrack**: Unlike simple truncation (only keeping first N lines), cjh adopts a **head+tail retention + middle spill** strategy. The model sees the beginning and end of the result (preserving context coherence), while the complete middle content spills to `~/.cjh/spill/`, with the ellipsis marker containing the spill path. When the model needs middle info, it can use `read_file` to read it back on demand. This both drastically saves tokens and loses no information — **this is cjh's core design distinguishing it from simple truncation agents**.

Tool-specific thresholds (avoiding one-size-fits-all):
- `bash`: 2000 chars (aggressive truncation — bash output often dominates prompt size; the full result is spilled to disk and can be read back)
- `list_dir`: 4000 chars
- default: 6000 chars

### Metric 2: Execution Speed

A coding agent's execution speed directly determines user wait time. cjh optimizes from three dimensions:

| Optimization | Implementation | Effect |
|---|---|---|
| **V2d concurrent execution engine** | DAG dependency analysis (extracting resource access `(path, isWrite)` from `ToolCall`) + topological group scheduling (same group spawns concurrently, groups execute serially) | LLM parallel tool calls automatically execute concurrently, `parallelSavedMs` stats time saved in real time |
| **hashline file rewriting** (drawing on OMP) | Line number anchor `@@N` + content verification editing, avoiding the overhead of reading + writing entire files | Precise line-level editing of large files, saves tokens and is fast |
| **Provider connection warmup** | Background connection establishment at construction time, first `chatStream` doesn't pay TLS cold start overhead | Faster first response |

**V2d concurrent engine's DAG dependency analysis**: Each tool call extracts resource access `(path, isWrite)`, automatically building a dependency graph. Rules:
- Same path and at least one isWrite → serial dependency edge
- Different paths → can be concurrent (even if all writes)
- `bash`'s command treated as path (different bash commands can be concurrent)

Topological group scheduling: Groups by dependency relationships; tools in the same group can execute concurrently; the next group must wait for the current group to complete. Order within a group maintains LLM's original order (result feedback order). Single-element groups execute serially directly (avoiding spawn overhead); multi-element groups spawn concurrently.

Performance baseline measurement 3D stats:
- `parallelBatches`: number of concurrently executed batches
- `parallelSavedMs`: milliseconds saved by concurrency vs serial
- `maxParallelism`: maximum concurrency (most tools in a single group)

### 📊 Measured Benchmarks (2026-08-29, real LLM task)

> Task: optimize a shooter HTML game (deepseek-v4-flash). Same task, before vs after optimization, 240-300s window.

| Metric | Before | After | Note |
|---|---|---|---|
| Prompt peak | 42.9K tokens (unbounded growth) | **9.4K** (reset to 5-7K after compaction) | History compaction fixed (below) |
| Rounds in window | 48 / 300s | 15 / 240s | Per-round latency 2-5s (was 5-22s) |
| Compaction trigger | never | every ~5 rounds | Dual threshold: message count OR real prompt tokens |
| Tool execution | <100ms | <100ms | The framework is not the bottleneck (measured) |
| Parallel tool batch | occasional | measured 3-way parallel read_file | V2d DAG engine |

**Three iterations of history-compaction fixes** (`docs/疑难问题-LLM工具调用效率低.md`):
1. Compaction check moved from `run()` start into **every loop round** — previously never re-checked during a multi-round task
2. Trigger signal uses the provider's real `usage.promptTokens` — char estimation measured 7x undercount
3. `compactKeep` 12→6 — otherwise compaction couldn't remove enough messages to reset prompt

## 📸 Interface Preview

### TUI Terminal Interface

![cjh TUI](docs/imgs/cjh.png)

Full-screen TUI: colorful logo + title bar + conversation/help view tabs + scrollable output area (Markdown rendering, streaming deltas, tool call hints, round summary bar) + status bar + input box (`/` command dropdown completion, Ctrl+E multi-line editing).

### Web Remote Interface

![cjh Web](docs/imgs/web.png)

Built-in HTTP Server + WebSocket streaming conversation + REST API + frontend SPA. Drive the Agent remotely from a browser, sharing the same tool/plugin/MCP system as the TUI.

---

## 🚀 Features

### Agent Core

- **Multi-turn tool call loop**: message history → LLM → tool call → result feedback → re-call, supporting complex task orchestration
- **Three-domain Capability security model**: commands / tools / resources whitelist + dangerous operation approval chain
- **Auto Compaction**: LLM summary compression of early history when message count or real prompt tokens (`usage.promptTokens`) exceed thresholds (`compactThreshold` / `compact_token_threshold` / `compactKeep`)
- **Project instructions**: auto-loads `AGENTS.md` / `.atomcode.md` project instructions injected into system prompt

### Tool System (14 built-in + extensible)

| Tool | Description |
|---|---|
| `bash` | Execute shell commands, capture stdout/stderr |
| `read_file` | Read file, large files return symbol skeleton, offset/limit expand on demand |
| `write_file` | Write file (create/overwrite, complete content in one call) |
| `append_file` | Append to existing file (continue after write_file truncation) |
| `edit` | str_replace exact replacement, unique-match safety check, replace_all |
| `hashline_edit` | Line number anchor `@@N` + content verification editing |
| `grep` | Recursive directory tree search, gitignore-aware |
| `glob` | Filename glob matching (`**` / `*` / `?`), gitignore-aware |
| `list_dir` | List directory tree |
| `ast_grep` | AST structural search (ast-grep CLI, falls back to grep) |
| `todo_write` | LLM manages task list via tool calls |
| `task` | Delegate to subagent (explore read-only / worker writable) |
| `web_search` | Web search, multi-backend routing (Tavily/Exa/SearXNG/DDG) + per-engine key rotation |
| `web_fetch` | Fetch web page, 3-tier degradation chain (Cangjie HTTP → curl → Firecrawl) + SSRF guard |

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
- stdx extension standard library (Linux version for development; platform-specific versions for cross-packaging, see below)
- Linux (development environment; Windows cross-packaging supported, see below)

### Build

```bash
# Activate Cangjie environment (sets PATH; build is static-linked single file, no runtime libs needed)
source cj-env.sh

# Build (produces cjh, static single file, zero deps)
cjpm build

# Unit tests (auto-switches to dynamic config: test framework double-free crashes under static linking)
./scripts/test.sh          # all
./scripts/test.sh --filter "*Workspace*"   # single case
```

### Packaging per platform

| Platform | Command | Artifact | Notes |
|---|---|---|---|
| Linux (static single file, default) | `cjpm build` (cjpm.toml defaults to `--static`) | `dist/linux/cjh-<ver>-linux-x64` | Single file, zero deps (Cangjie runtime + stdx included; only system libc), run directly, no env vars needed |
| Windows | `./scripts/winbuild.sh` | `dist/windows/cjh-<ver>-windows-x64.exe` | Cross-compiled PE on Linux (stdx **statically linked**: artifact depends only on system libs + 2 runtime DLLs). **Prerequisite**: `cangjie-stdx-windows-x64-<ver>` installed under `~/.cangjie/stdx/` (download from gitcode.com/Cangjie/cangjie_stdx/releases). **Deploy**: unpack `dist/cjh-<ver>-windows-x64.zip` (7.2MB, includes exe + runtime DLLs + **openssl DLL**) — openssl (libcrypto-3-x64.dll/libssl-3-x64.dll) is required for WebSocket handshake and HTTPS, loaded on demand by dynamicLoader, must sit next to the exe. **Single-file exe not yet possible**: the Cangjie SDK ships no Windows static runtime (`libcangjie-runtime.a` exists for Linux only), and `--static` affects Linux targets only — waiting for official support (see dev docs §3.10) |
| macOS | POSIX backend passthrough, same source tree | — | Build on macOS (termios-compatible, `@When` auto-selects POSIX backend) |

> Cross-platform principle: terminal-layer `TerminalBackend` abstraction (`@When[os == ...]` conditional compilation selects the backend; Windows uses Win32 Console API + VT output, Linux/macOS use termios) — one source tree, multi-platform binaries. See [design](docs/跨平台终端层设计方案.md).

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
./target/release/bin/cjh

# CLI mode (plain text interaction)
./target/release/bin/cjh --cli

# JSON headless mode (script integration)
./target/release/bin/cjh --mode json "Search for TODO with grep"

# Restore historical session
./target/release/bin/cjh --resume <session-id>

# Mock mode (demo without API Key)
CJH_MOCK=1 ./target/release/bin/cjh

# Web mode (remote Agent driving)
./target/release/bin/cjh web --port 8765 --token my-secret
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
│          cjh main entry (entries.cj + main.cj)           │
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

## 🧪 Testing & Quality Assurance

**216 unit tests, all green** (4 packages, 25 test classes, one-shot `cjpm test`) + **14 PTY integration tests** (`python3 scripts/tui_pty_test.py`, real TUI driven via pseudo-terminal), covering all 14 built-in tools + Agent core + TUI rendering/events + infrastructure:

| Test domain | Coverage |
|---|---|
| Tool main paths | bash / write / append / edit / grep / glob / list_dir / hashline / todo / registry — CRUD + error paths |
| Tool edge cases | read large-file streaming/offset-out-of-range/binary tolerance, grep dir recursion + .git skip, glob deep nesting/ignored dirs, edit Chinese/emoji/multiline, hashline CRLF/single-line/hash collision/multi-anchor offset |
| Agent end-to-end | DAG parallel batch (measured 3-way concurrency), write-then-read same-path serial, tool result truncation + full spill |
| Infrastructure | session save/restore/fork, skill frontmatter parsing, UTF-8 tolerant decode/byte-safe truncation, WebBudget, BM25 retrieval, web_search degradation chain, KeyRotator |
| Pure functions | ToolResultTruncator thresholds/head-tail/spill, parseSgJsonLine, escapeRegex, formatToolArgs |
| **TUI rendering & events** | Markdown bold/inline-code/code-block/cross-frame streaming/finish reset, Screen diff rendering (changed lines/Chinese/clone), Ansi sequences, **TuiApp key protocol** (Ctrl+C quit/typing/submit/completion/view switch/multiline/backspace crash-guard) |
| **PTY integration (real terminal)** | `scripts/tui_pty_test.py`: startup rendering, mock toolchain e2e, `/` completion, help view, **approval dialog yes/no** (blocking approval path unit tests can't cover) |

**CI gate (mandatory, see `AGENTS.md`)**: `cjpm test` all-green is the sole delivery credential; new features/fixes must ship with tests; bug fixes require a reproducing test written first.

**The value of tests — 10+ latent bugs caught (see `docs/开发文档与踩坑记录.md` §3.9)**:

| Bug | Impact |
|---|---|
| `edit` replacement corrupts files | byte-wise append output decimal integers — **the edit tool had never actually worked** |
| `hashline` always threw | FNV-1a UInt32 multiply overflow — **hashline had never been usable** |
| grep/glob dir search not recursive | misused `Directory.walk` (non-recursive + false stops walk) — only top level searched |
| append_file silently created files | auto-created missing files, contradicting its spec |
| capability resource-check gap | 4 write tools skipped fs whitelist (security-model hole) |
| session ID millisecond collision | save/saveFork same-ms IDs overwrote each other |
| tool messages lost `name` | tool names missing after session restore |
| glob/list_dir static-state race | concurrent calls clobbered each other (V2d + shared registry) |

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
| v1.3.1 | **LLM efficiency triple fix** (compaction into loop + real-usage trigger + keep tuning, prompt peak 42.9K→9.4K) + **216 unit tests green** + 13 latent bugs fixed (incl. TUI: markdown code-block, Tab re-open, backspace log crash) + build.cj renames artifact to `cjh` |
| **v1.3.2** | **P0+P1 optimization**: bash timeout + Ctrl+C interrupt + persistent bash session + cross-session project memory + fast-model routing + 429 key fallback + compaction keeps tool results + SQLite read + prompt tuning + **static-linked single-file release** (228 tests + 36 PTY green) |

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
- [ ] **V4 parallel multi-agent orchestration** (drawing on mature patterns like swarm; orientation: parallel sub-agents + context isolation): orchestrator + parallel sub-agents (Linux-fork-style isolated workspaces/contexts) + role model (PM/research/coding/testing/review) + contract interfaces + workflow DSL + per-agent model routing + HarmonyOS native

## 📚 Docs

- [Architecture & Design v2](docs/方案与架构设计-v2.md) — Project design and architecture
- [Implementation & Handover](docs/实现方案与交接.md) — Architecture and code map (onboarding entry)
- [Feature Checklist](docs/cjh功能清单.md) — Complete feature list
- [LLM Tool-Call Efficiency](docs/疑难问题-LLM工具调用效率低.md) — Optimization process and measured data
- [Plugin System Implementation](docs/插件系统实现方案.md) — Plugin system design
- [Plugin Signing & Contribution Guide](docs/插件签名与贡献指南.md) — Trust chain and plugin publishing
- [Web Support Implementation](docs/Web支持实现方案.md) — Web Server design
- [Web Search & Fetch Design](docs/Web搜索与抓取工具设计.md) — Search degradation chain & key rotation
- [Progress Log](docs/进度记录.md) — Development progress and status tracking
- [Dev Docs & Pitfall Records](docs/开发文档与踩坑记录.md) — Cangjie engineering pitfalls

## 🤝 Cangjie Ecosystem Value

cjh is a complete practice of the Cangjie language in the **AI coding agent** domain. Along the way it produced **5 self-contained Cangjie libraries** (zero deps or official-stdx only), ready to be published independently to the Cangjie ecosystem:

| Library | Position | Deps | Ease |
|---|---|---|---|
| [**cjterm**](libs/cjterm/README.md) | Terminal UI component library: ANSI control / diff rendering / input box / editor / form / list select components / **cross-platform terminal layer** (termios + Win32 Console via `@When[os]` conditional compilation) | zero deps | ★ |
| [**cjlog**](libs/cjlog/README.md) | Async logging: level control / dual-file output / exception stack extraction | zero deps | ★ |
| [**cjconfig**](libs/cjconfig/README.md) | Layered config: env var > config file > defaults / declarative fields / auto template / preserves user extensions | stdx.json only | ★ |
| [**cjutil**](libs/cjutil/README.md) | Utilities: UTF-8 safe truncation / SHA-256 / national crypto SM2 / article extraction / BM25 search / HTML→Markdown / JSON repair / SSRF guard / cross-platform FFI | official stdx | ★★ |
| [**cjllm**](libs/cjllm/README.md) | LLM protocol library: OpenAI-compatible / Anthropic Messages / Ollama / Mock, streaming + tool calls + token stats + mojibake fix | cjutil+cjlog+stdx | ★★★ |

> Each library ships with its own README, MIT LICENSE, runnable examples (`examples/`), CI template, and release guide (`docs/发布指南.md`). Publish by pushing an independent repo to atomgit (Cangjie-TPC) → tag → optionally submit to pkg.cangjie-lang.cn → request inclusion from Cangjie-SIG. See [libs/README.md](libs/README.md).

Further contributions from cjh:

| Contribution | Description |
|---|---|
| **MCP Protocol Implementation** | The first MCP client implementation in Cangjie (stdio transport + tool registration), paving the way for the Cangjie ecosystem to access the MCP tool network |
| **Plugin Trust Chain** | A practical example of Cangjie `stdx.crypto` national cryptography SM2 in plugin security (SHA256 checksum + SM2 signature) |
| **Cross-platform terminal layer** | `TerminalBackend` abstraction + conditional compilation (termios / Win32), a standard pattern for cross-platform Cangjie TUIs ([design](docs/跨平台终端层设计方案.md)) |
| **Engineering Pitfall Records** | Complete records of FFI / conditional compilation / static linking / concurrency / TLS pitfalls in Cangjie development ([dev docs](docs/开发文档与踩坑记录.md)), lowering the barrier for newcomers |

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
│   ├── entries.cj          # assembly entry (CLI/TUI/JSON/Web/Mock)
│   ├── main.cj             # program entry (provider factory + dispatch)
│   ├── tests/              # unit tests (tools/session/truncator/router)
│   └── core_funcs_test.cj  # root-package pure-function tests
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
