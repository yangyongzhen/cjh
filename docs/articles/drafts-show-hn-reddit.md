# Show HN / Reddit 英文帖草稿（待本人发布，供过目修改）

> 发布建议：Show HN 选工作日美东上午（北京时间 21:00–24:00）；Reddit 同周跟进，
> 不要同一天多平台齐发。标题里的数字（13MB / zero deps）是钩子，别改成形容词。

---

## Show HN

**Title:**

    Show HN: A 13MB single-binary coding agent you can embed in any app

**First comment（正文，第一人称）:**

Hi HN! I built cjh — a terminal coding agent that ships as a single static binary (13 MB Linux, 13 MB Windows), with zero runtime dependencies. One file is the whole agent: TUI, built-in web UI, and an HTTP/WebSocket API for embedding.

It's written in Cangjie, Huawei's open-source language (yes, that's the unusual part — the toolchain produces genuinely tiny static binaries, which is what makes the single-file approach possible). But you don't need to know anything about Cangjie to *use* it: the embedding protocol is plain REST + WebSocket over localhost, so the host can be TypeScript, Rust, Python — whatever your app is.

Three things I think are interesting:

1. **Embedding story.** `cjh web` turns the agent into a local service on 127.0.0.1:8765. Your app spawns it as a subprocess, talks REST/WS, and gets crash isolation + independent upgrades for free. I documented three real integrations: an AI chat panel in a desktop app, a note-taking app, and a migration workbench (screenshot in the README) — the host apps are 33KB of glue code.

2. **Works with local models.** Any OpenAI-compatible endpoint works, including Ollama/vLLM/llama.cpp — your code never leaves the machine.

3. **It's honest software**: ~600 unit tests + 208 library tests + 77 pty-driven end-to-end TUI scenarios in CI, MIT licensed.

Try it without an API key: `CJH_MOCK=1 ./cjh` runs the full tool loop against a mock model.

Repo: https://github.com/yangyongzhen/cjh
Install: `curl -fsSL https://yangyongzhen.github.io/cjh/install.sh | bash`

Happy to answer questions about the architecture, the single-binary packaging, or what building on Cangjie is like.

**预备回复（评论区常见问题，提前备好）:**

- Q: Why Cangjie? → A: I wanted a static-single-binary agent without Go/Rust's trade-offs; Cangjie's toolchain does `--static` genuinely well (one file, no libc.so dance). The language is new, the stdlib is complete, and the cross-compile story is solid.
- Q: How is this different from aider/opencode/claude-code? → A: It's the deployable-unit size and the embed-first design. Those are great terminals for humans; cjh is a 13MB binary your *application* can own as a subprocess.
- Q: Does it phone home? → A: Only to whatever LLM endpoint you configure. No telemetry.

---

## Reddit

### r/commandline（或 r/linux）

**Title:**

    cjh: a coding agent that's one 13MB static file — TUI + web UI + embed API

**Body:**

I got tired of agents that need a runtime, a node_modules folder, and a prayer. So I built cjh: one static binary, zero deps. `./cjh` gives you a full TUI coding agent; `cjh web` gives you a browser UI on localhost:8765; the same process speaks REST/WS if you want to embed it in your own tooling.

It works with any OpenAI-compatible endpoint (Ollama, vLLM, llama.cpp — fully offline if you want), and there's a mock mode so you can try the whole thing with no API key: `CJH_MOCK=1 ./cjh --mock`.

MIT, source's readable if you're curious — it's written in Cangjie (Huawei's open language), which is honestly half the story: the toolchain makes single-file static builds trivial.

Install: `curl -fsSL https://yangyongzhen.github.io/cjh/install.sh | bash`
Repo + screenshots: https://github.com/yangyongzhen/cjh

Feedback welcome — especially on the embedding API (docs in the repo).

### r/LocalLLaMA

**Title:**

    cjh: a 13MB terminal coding agent that plugs straight into Ollama/llama.cpp

**Body:**

cjh is an open-source (MIT) coding agent — plan/tool-calls/iterate loop, TUI + web UI — that speaks the OpenAI-compatible protocol, so it works out of the box against Ollama, vLLM, or llama.cpp server. Everything runs locally: the agent is a single 13MB static binary, your code and context never leave the machine.

Two features the local crowd might care about:
- `--mock` mode: full tool-loop demo with zero model — good for seeing what it does before wiring a model in
- Embed mode: `cjh web` exposes REST/WS on 127.0.0.1, so you can wire it into your own app as a local "AI brain" (crash-isolated subprocess)

Repo: https://github.com/yangyongzhen/cjh

（诚实提醒：模型质量决定 agent 上限——小本地模型工具调用会抖，建议 qwen2.5-coder 32B 级别起步。）

---

## dev.to 文章标题备选

    I built a coding agent that fits in one file — here's the packaging story
