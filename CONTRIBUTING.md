# Contributing to cjh

Thanks for your interest! cjh is a terminal coding agent written in [Cangjie](https://cangjie-lang.cn) — a single static binary with zero runtime dependencies. Contributions of all sizes are welcome: docs fixes, bug reports, new tools, and (especially) integrations that embed cjh in your own apps.

**Language**: issues and PRs in English or 中文 both work — use whichever you're comfortable with.

## Good first issues

Start with issues labeled [`good-first-issue`](https://atomgit.com/qq8864/cjh/issues?q=label) — they're scoped to be self-contained and don't require deep knowledge of the codebase (some don't require any Cangjie at all).

## Development setup (Linux)

```bash
# 1. Cangjie SDK 1.2.0 + stdx 1.2.0.1 — install from https://cangjie-lang.cn/download
#    (SDK goes to e.g. /opt/cangjie/cangjie, stdx to ~/.cangjie/stdx/...)
# 2. Clone + point the build at your local SDK paths (cjpm.toml has absolute paths;
#    this script rewrites them automatically — run it once after cloning):
./scripts/setup_paths.sh          # add --check to just verify

# 3. Activate the toolchain and build
source /opt/cangjie/cangjie/envsetup.sh
cjpm build && ./target/release/bin/cjh --version
```

## Running the test gates

Every change must pass these before a PR is merged — `scripts/test.sh` is the single delivery credential:

```bash
source /opt/cangjie/cangjie/envsetup.sh

./scripts/test.sh                    # root package, ~600 cases
./scripts/test_libs.sh               # the 6 library packages (208 cases)
python3 scripts/tui_pty_test.py      # 77 end-to-end TUI scenarios over a pty
CJH_MOCK=1 ./target/release/bin/cjh --mock   # offline end-to-end tool-chain check
```

If `cjpm` is not found, source the envsetup script first (each shell needs it once).
`scripts/test_libs.sh` may print `找不到 cjpm` for the same reason.

## Code conventions

- **Tests live next to or with what they test**: root-package tests go in `src/*_test.cj` (same package, white-box); everything else goes in `src/tests/` (package `cjh.tests`). Library tests live in the lib's own `src/*_test.cj`. The `_test.cj` suffix keeps them out of release builds.
- **New behavior ships with tests** in the same PR — bug fixes first get a failing test that reproduces the bug.
- **Tools are tested through `execute()`** (assert on `ToolResult`), not private internals.
- **Packages stay decoupled**: shared utilities go into the bottom-level libs (`cjutil`), not business packages; circular deps are resolved with callback injection, never by moving code between packages.
- Zero compile warnings is a hard gate (`--static` driver notices are the only known exception).

## Pull requests

1. Fork / branch from `main` (e.g. `feat/your-topic` or `fix/issue-NN`).
2. Make the change + tests.
3. Run the four gates above.
4. Open the PR against `main` with a short description and test evidence.

CI runs the same gates on every push. For questions, open an issue first — design discussions before code save everyone time.
