# cjh

> Terminal coding agent harness written in Cangjie — one static binary, zero runtime dependencies.

**cjh** is a coding agent that lives in your terminal. It reads and writes files, runs commands, and drives a full agent loop — implemented from scratch in [Cangjie](https://cangjie-lang.cn/), so it ships as a single native binary instead of a Node / Python / Electron stack.

## Install

```bash
npx cjh          # run once without installing
npm i -g cjh     # or install it globally
```

Prebuilt platforms:

| Platform | Arch | Package |
| --- | --- | --- |
| Linux | x64 | `@cjh/cli-linux-x64` |
| Windows | x64 | `@cjh/cli-win32-x64` |

The launcher resolves the binary for your platform at startup. Platform packages are published separately, so you only download your own (~5 MB compressed, ~17 MB installed) and never the other platform's build.

> **npm is a convenience channel, not a requirement.** cjh itself has **zero runtime dependencies** — no Node, no Python, no Electron. If you would rather not install Node at all, grab the standalone binary from [GitHub Releases](https://github.com/yangyongzhen/cjh/releases).

## What it does

- **Full-screen TUI** — diff-rendered terminal UI with streaming output, multi-line editing (`Ctrl+E`), view switching (`Tab` / `←` `→`), and inline approval prompts (`y` / `n`)
- **14 built-in tools** — bash, read/write/edit, grep, glob, ast_grep, todo_write, task, web_search, web_fetch and friends
- **Safety boundaries** — a three-domain capability gate (commands / tools / resources) plus an approval chain for destructive operations. Permissive by default; strict mode is one config flag, never a hidden default
- **MCP support** — plug Model Context Protocol servers in as extra tool sources
- **Built-in web UI** — `cjh web` serves the same agent and the same tools over HTTP
- **Plugin trust chain** — SHA256 checksums plus SM2 national-standard signatures before a skill or plugin loads
- **Cangjie knowledge layer** — optional offline reference corpus (`cjh ref`) for Cangjie projects

## Usage

```bash
cjh --version                    # print the version, e.g. "cjh v1.5.3"
cjh --help                       # full flag list
cjh                              # start the TUI in the current directory
cjh --cli                        # plain-text CLI instead of the TUI
cjh --mode json "explain src/"   # headless JSON run, script-friendly
cjh --resume <session-id>        # reopen a previous session
cjh --list                       # list saved sessions
cjh web                          # built-in web UI (--port / --bind / --token)
cjh --mock                       # offline end-to-end check, no API key needed
cjh trust-list                   # show trusted plugin publishers
```

Configuration lives in `~/.cjh/config.json` (providers, models, capability rules). Credentials are only ever written to `~/.cjh/auth.json`.

## Links

- Repository: <https://github.com/yangyongzhen/cjh>
- Website: <https://yangyongzhen.github.io/cjh/>
- Issues: <https://github.com/yangyongzhen/cjh/issues>
- License: MIT

<sub>Primary development happens on [AtomGit](https://atomgit.com/qq8864/cjh); GitHub is the mirror used for distribution.</sub>
