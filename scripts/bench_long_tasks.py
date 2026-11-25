#!/usr/bin/env python3
"""
长任务回归基准：耗时可复现，不依赖 `--mock` 的固定脚本。

覆盖三类真实摩擦：
  1. wait   —— 30 秒后台任务。要求 bash_start + bash_poll(wait_ms)，验证
               不再每 2-5 秒轮询一次。
  2. sqlite —— 一个失败用例的 SQLite 小项目。要求读代码、跑测试、只改实现、
               重跑测试，验证工具链与"测试是契约"的约束。
  3. tui    —— 真实 PTY 场景（scripts/tui_pty_test.py），验证 TUI 启动、输入、
               补全、审批、排队等不因改动回归。

默认使用真实模型（需要 ~/.cjh 里的凭据）。`--check` 只生成/校验夹具并
打印计划，不调用模型、不跑 PTY（适合 CI 或改脚本后自检）。

用法：
  ./scripts/bench_long_tasks.py --check
  ./scripts/bench_long_tasks.py --scenario wait --scenario sqlite
  ./scripts/bench_long_tasks.py --cjh target/release/bin/cjh --out /tmp/cjh_bench
  CJH_CONFIG_DIR=/tmp/cjh_bench_cfg ./scripts/bench_long_tasks.py

说明：
  - cjh 必须以 `--mode json` 运行；输出里的 usage/tool_calls 是本脚本的指标源。
  - 每个场景在独立目录中运行，结束后保留现场（fixture、cjh stdout/stderr）。
  - `--check` 会验证 SQLite 夹具初始确实是红的（bug 存在），避免"假基准"。
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
DEFAULT_CJH = PROJECT / "target" / "release" / "bin" / "cjh"
TUI_TEST = PROJECT / "scripts" / "tui_pty_test.py"


# ─── 夹具 ─────────────────────────────────────────────────────────────

WAIT_JOB = """import pathlib
import time

for i in range(1, 7):
    print(f"progress {i}/6", flush=True)
    time.sleep(5)
pathlib.Path("done.txt").write_text("done\\n", encoding="utf-8")
print("ALL-DONE", flush=True)
"""

SQLITE_STORE = """import sqlite3


class Store:
    def __init__(self, path):
        self.conn = sqlite3.connect(path)
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS items ("
            "id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)"
        )
        self.conn.commit()

    def add(self, title):
        cur = self.conn.execute("INSERT INTO items (title) VALUES (?)", (title,))
        self.conn.commit()
        return cur.lastrowid

    def mark_done(self, item_id):
        self.conn.execute("UPDATE items SET done = 1 WHERE id = ?", (item_id,))
        self.conn.commit()

    def open_items(self):
        # BUG: 查询的是已完成项；测试期望未完成项。
        rows = self.conn.execute(
            "SELECT title FROM items WHERE done = 1 ORDER BY id"
        ).fetchall()
        return [row[0] for row in rows]

    def close(self):
        self.conn.close()
"""

SQLITE_TEST = """import os
import tempfile
import unittest

from store import Store


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(os.path.join(self.tmp.name, "items.db"))

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_open_items_excludes_done(self):
        first = self.store.add("write report")
        self.store.add("review patch")
        self.store.mark_done(first)
        self.assertEqual(self.store.open_items(), ["review patch"])

    def test_empty_store(self):
        self.assertEqual(self.store.open_items(), [])


if __name__ == "__main__":
    unittest.main()
"""

WAIT_PROMPT = """当前目录里的 slow_job.py 会输出 6 条进度，约 30 秒后写入 done.txt。
请用 bash_start 在后台启动 `python3 slow_job.py`，然后用 bash_poll 并传 wait_ms=60000 等它结束。
不要用同步 bash 阻塞等待，也不要每 2-5 秒轮询一次。
结束后读取 done.txt，并用一行回答：进度输出的最后标记是什么，done.txt 的内容是什么。"""

SQLITE_PROMPT = """当前目录是一个小型 Python SQLite 项目。
请先运行 `python3 -m unittest -v` 找出失败用例，再只修改 store.py 的实现让测试通过；
不要修改 test_store.py 的断言。修好后重新运行测试，并在最后一行回答实际测试结果（通过/失败数量）。"""


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def write_fixtures(root: Path) -> dict:
    wait_dir = root / "wait"
    sqlite_dir = root / "sqlite"
    # 显式 --out 重跑同一目录时，先清掉上一轮产物（尤其 done.txt/store.py），
    # 否则上一轮的绿会伪装成本轮成功。
    shutil.rmtree(wait_dir, ignore_errors=True)
    shutil.rmtree(sqlite_dir, ignore_errors=True)
    wait_dir.mkdir(parents=True)
    sqlite_dir.mkdir(parents=True)
    (wait_dir / "slow_job.py").write_text(WAIT_JOB, encoding="utf-8")
    (sqlite_dir / "store.py").write_text(SQLITE_STORE, encoding="utf-8")
    (sqlite_dir / "test_store.py").write_text(SQLITE_TEST, encoding="utf-8")
    return {
        "wait_dir": wait_dir,
        "sqlite_dir": sqlite_dir,
        "sqlite_test_sha256": sha256(sqlite_dir / "test_store.py"),
        "sqlite_store_sha256": sha256(sqlite_dir / "store.py"),
    }


# ─── 执行与解析 ───────────────────────────────────────────────────────

def run_cmd(cmd, cwd, timeout, env=None):
    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr, time.monotonic() - start
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        err = exc.stderr or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        return 124, out, err, time.monotonic() - start


def parse_cjh_json(stdout: str):
    """--mode json 的 stdout 应当是单个 JSON 文档；容忍前后有日志行。"""
    text = stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end <= start:
            return None
        try:
            return json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None


def parse_poll_args(raw: str) -> dict:
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def empty_result(name: str) -> dict:
    return {
        "scenario": name,
        "status": "FAIL",
        "wall_s": 0.0,
        "rounds": 0,
        "tools": 0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cached_tokens": 0,
        "cache_pct": 0.0,
        "tool_counts": {},
        "detail": "",
    }


def result_metrics(result: dict, payload: dict, wall_s: float) -> None:
    usage = payload.get("usage") or {}
    result["rounds"] = int(usage.get("rounds") or 0)
    result["tools"] = int(usage.get("tools") or 0)
    result["prompt_tokens"] = int(usage.get("prompt_tokens") or 0)
    result["completion_tokens"] = int(usage.get("completion_tokens") or 0)
    result["cached_tokens"] = int(usage.get("cached_tokens") or 0)
    if result["prompt_tokens"] > 0:
        result["cache_pct"] = round(
            result["cached_tokens"] * 100.0 / result["prompt_tokens"], 1
        )
    counts = {}
    for call in payload.get("tool_calls") or []:
        name = call.get("name") or "?"
        counts[name] = counts.get(name, 0) + 1
    result["tool_counts"] = counts
    result["wall_s"] = round(wall_s, 1)


def cjh_env(config_dir: str, mock: bool = False):
    env = os.environ.copy()
    if config_dir:
        env["CJH_CONFIG_DIR"] = config_dir
    if mock:
        env["CJH_MOCK"] = "1"
    return env


def run_model_scenario(cjh: Path, name: str, prompt: str, workdir: Path,
                       config_dir: str, timeout: float) -> dict:
    result = empty_result(name)
    if not cjh.exists():
        result["detail"] = f"cjh 不存在: {cjh}（先 cjpm build 或传 --cjh）"
        return result
    cmd = [str(cjh), "--mode", "json", prompt]
    rc, out, err, wall = run_cmd(cmd, workdir, timeout, cjh_env(config_dir))
    (workdir / "cjh.stdout.json").write_text(out, encoding="utf-8")
    (workdir / "cjh.stderr.log").write_text(err, encoding="utf-8")
    payload = parse_cjh_json(out)
    if payload is None:
        result["wall_s"] = round(wall, 1)
        result["detail"] = f"cjh 未输出可解析 JSON（exit={rc}，{wall:.1f}s；见 cjh.stderr.log）"
        return result
    result_metrics(result, payload, wall)
    if rc != 0 or payload.get("error_code"):
        result["detail"] = f"cjh 失败: {payload.get('error_code')} {payload.get('error')}"
        return result
    result["status"] = "PASS"
    result["payload"] = payload
    return result


def validate_wait(result: dict, workdir: Path) -> None:
    payload = result.pop("payload", {})
    counts = result["tool_counts"]
    done = workdir / "done.txt"
    problems = []
    if not done.exists() or "done" not in done.read_text(encoding="utf-8", errors="replace"):
        problems.append("done.txt 缺失或内容不对")
    polls = [c for c in payload.get("tool_calls") or [] if c.get("name") == "bash_poll"]
    wait_used = any(
        int(parse_poll_args(c.get("args", "")).get("wait_ms") or 0) > 0
        for c in polls
    )
    if counts.get("bash_start", 0) < 1:
        problems.append("没有用 bash_start")
    if len(polls) < 1:
        problems.append("没有用 bash_poll")
    if not wait_used:
        problems.append("bash_poll 未传 wait_ms")
    reply = str(payload.get("reply") or "")
    if "done" not in reply.lower():
        problems.append("最终回复未提到 done.txt 内容")
    if problems:
        result["status"] = "FAIL"
        result["detail"] = "；".join(problems)
    else:
        result["detail"] = f"polls={len(polls)} wait_ms=yes"


def validate_sqlite(result: dict, workdir: Path, test_sha: str, store_sha: str) -> None:
    result.pop("payload", None)
    problems = []
    if sha256(workdir / "test_store.py") != test_sha:
        problems.append("test_store.py 被修改（测试是契约）")
    if sha256(workdir / "store.py") == store_sha:
        problems.append("store.py 未修改")
    rc, out, err, _ = run_cmd(
        [sys.executable, "-m", "unittest", "-v"], workdir, timeout=120
    )
    (workdir / "unittest.stdout.log").write_text(out, encoding="utf-8")
    (workdir / "unittest.stderr.log").write_text(err, encoding="utf-8")
    if rc != 0:
        problems.append(f"修复后 unittest 仍失败（exit={rc}，见 unittest.stderr.log）")
    if problems:
        result["status"] = "FAIL"
        result["detail"] = "；".join(problems)
    else:
        result["detail"] = "unittest 通过，测试文件未改"


def run_tui(result: dict, out_dir: Path, timeout: float) -> None:
    if not TUI_TEST.exists():
        result["detail"] = f"缺少 {TUI_TEST}"
        return
    rc, out, err, wall = run_cmd(
        [sys.executable, str(TUI_TEST)], PROJECT, timeout, cjh_env("")
    )
    # 日志必须落到基准现场目录，不能写回仓库根（否则每跑一次就多两个未跟踪文件）
    (out_dir / "tui_pty.stdout.log").write_text(out, encoding="utf-8")
    (out_dir / "tui_pty.stderr.log").write_text(err, encoding="utf-8")
    result["wall_s"] = round(wall, 1)
    passed = failed = 0
    found_summary = False
    for line in out.splitlines():
        if "结果：" in line and "通过" in line:
            found_summary = True
            try:
                nums = "".join(ch if ch.isdigit() else " " for ch in line).split()
                passed, failed = int(nums[0]), int(nums[1])
            except (ValueError, IndexError):
                found_summary = False
    if not found_summary or passed <= 0:
        result["status"] = "FAIL"
        result["detail"] = f"未解析到 PTY 结果行（exit={rc}，见 tui_pty.stdout.log）"
    elif rc != 0 or failed:
        result["status"] = "FAIL"
        result["detail"] = f"PTY {passed} 通过 / {failed} 失败（exit={rc}）"
    else:
        result["status"] = "PASS"
        result["detail"] = f"PTY {passed} 通过 / 0 失败"


# ─── 输出 ─────────────────────────────────────────────────────────────

def print_table(results: list) -> None:
    headers = ["scenario", "status", "wall_s", "rounds", "tools",
               "prompt", "completion", "cache%", "detail"]
    rows = []
    for r in results:
        rows.append([
            r["scenario"],
            r["status"],
            f'{r["wall_s"]:.1f}',
            str(r["rounds"]) if r["rounds"] else "-",
            str(r["tools"]) if r["tools"] else "-",
            str(r["prompt_tokens"]) if r["prompt_tokens"] else "-",
            str(r["completion_tokens"]) if r["completion_tokens"] else "-",
            f'{r["cache_pct"]:.1f}' if r["prompt_tokens"] else "-",
            r["detail"],
        ])
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    print("  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))


def check_mode(fixtures: dict, cjh: Path) -> int:
    print("[check] 夹具已生成")
    wait_py = fixtures["wait_dir"] / "slow_job.py"
    sqlite_dir = fixtures["sqlite_dir"]
    rc, out, err, _ = run_cmd([sys.executable, "-m", "py_compile", str(wait_py)],
                              fixtures["wait_dir"], 30)
    if rc != 0:
        print(f"[check] FAIL slow_job.py 语法: {err.strip()}")
        return 1
    rc, out, err, _ = run_cmd([sys.executable, "-m", "unittest", "-v"],
                              sqlite_dir, 60)
    if rc == 0:
        print("[check] FAIL SQLite 夹具初始测试竟然全绿，基准失去意义")
        return 1
    print("[check] SQLite 夹具初始为红（bug 存在）——符合预期")
    if cjh.exists():
        rc, out, err, _ = run_cmd([str(cjh), "--version"], PROJECT, 30)
        print(f"[check] cjh: {(out or err).strip() or '无输出'}"
              f"（exit={rc}）")
    else:
        print(f"[check] 未找到 cjh: {cjh}（真跑前先 cjpm build）")
    print("[check] 计划：")
    print("  wait   : bash_start + bash_poll(wait_ms=60000) 约 30s")
    print("  sqlite : unittest 红转绿，测试文件哈希不变")
    print("  tui    : scripts/tui_pty_test.py 全绿")
    print("[check] OK（未调用模型，未跑 PTY）")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="cjh 长任务回归基准")
    parser.add_argument("--check", action="store_true",
                        help="只生成并校验夹具，不调用模型、不跑 PTY")
    parser.add_argument("--scenario", action="append",
                        choices=["wait", "sqlite", "tui"],
                        help="可重复；默认全部")
    parser.add_argument("--cjh", type=Path,
                        default=Path(os.environ.get("CJH_BIN", DEFAULT_CJH)),
                        help="cjh 可执行文件（默认 target/release/bin/cjh）")
    parser.add_argument("--out", type=Path,
                        default=Path(tempfile.gettempdir()) /
                        f"cjh_bench_{time.strftime('%Y%m%d_%H%M%S')}",
                        help="输出目录（默认 /tmp/cjh_bench_<时间>）")
    parser.add_argument("--config-dir", default=os.environ.get("CJH_CONFIG_DIR", ""),
                        help="传给 cjh 的 CJH_CONFIG_DIR（默认为空 = ~/.cjh）")
    parser.add_argument("--timeout", type=float, default=900,
                        help="单个模型场景超时秒数（默认 900）")
    parser.add_argument("--json", action="store_true", help="结果以 JSON 输出")
    args = parser.parse_args()
    args.cjh = args.cjh.expanduser().resolve()
    if not args.cjh.exists():
        print(f"[bench] 警告: cjh 不存在: {args.cjh}")

    args.out.mkdir(parents=True, exist_ok=True)
    fixtures = write_fixtures(args.out)
    manifest = {
        "cjh": str(args.cjh),
        "config_dir": args.config_dir,
        "sqlite_test_sha256": fixtures["sqlite_test_sha256"],
        "sqlite_store_sha256": fixtures["sqlite_store_sha256"],
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    (args.out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[bench] 现场目录: {args.out}")

    if args.check:
        return check_mode(fixtures, args.cjh)

    scenarios = args.scenario or ["wait", "sqlite", "tui"]
    results = []
    for name in scenarios:
        print(f"[bench] 运行 {name} ...", flush=True)
        if name == "tui":
            result = empty_result(name)
            run_tui(result, args.out, args.timeout)
        elif name == "wait":
            result = run_model_scenario(
                args.cjh, name, WAIT_PROMPT, fixtures["wait_dir"],
                args.config_dir, args.timeout,
            )
            if result["status"] == "PASS":
                validate_wait(result, fixtures["wait_dir"])
        else:
            result = run_model_scenario(
                args.cjh, name, SQLITE_PROMPT, fixtures["sqlite_dir"],
                args.config_dir, args.timeout,
            )
            if result["status"] == "PASS":
                validate_sqlite(
                    result, fixtures["sqlite_dir"],
                    fixtures["sqlite_test_sha256"],
                    fixtures["sqlite_store_sha256"],
                )
        result.pop("payload", None)
        print(f"[bench] {name}: {result['status']} ({result['detail']})", flush=True)
        results.append(result)

    (args.out / "results.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        print_table(results)
        print(f"[bench] 结果已写入 {args.out / 'results.json'}")
    return 0 if all(r["status"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
