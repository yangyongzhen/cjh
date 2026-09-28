#!/usr/bin/env python3
"""端到端复现台：真实 TUI + 真实 HTTP，验证 stdx 打到 fd 1 的噪声不会污染输入栏。

链路（除 LLM 用仓内 MockProvider 外，全部真实）：
    PTY 启动 target/release/bin/cjh（CJH_MOCK=1）
      → MockProvider 第 2 轮发 web_fetch（URL 由 CJH_MOCK_WEB_URL 给出）
      → WebFetchTool 真实发起 HTTP 到本脚本的"停滞服务端"（accept 后永不回数据）
      → settings.json 的 web_fetch.timeout_seconds 取配方前提缺口的最恶劣值（默认 0）
      → 断言整段 PTY 输出里绝不出现 stdx 的 readTimer WARN

为什么必须能跑 --expect-warn（阳性对照）：只断言"没出现 WARN"分不清"已修好"与"链路压根没跑"，
所以本台子额外输出"停滞服务端 accept 次数"作为链路确实跑通的证据，并支持对旧构建做阳性对照：

    git worktree add /tmp/cjh_prefix HEAD~2      # 配方前提缺口修复之前的提交
    ( cd /tmp/cjh_prefix && source /opt/cangjie/cangjie/envsetup.sh && cjpm build )
    python3 scripts/e2e_warn_harness.py --binary /tmp/cjh_prefix/target/release/bin/cjh --expect-warn

用法：
    python3 scripts/e2e_warn_harness.py                    # 期望无 WARN
    python3 scripts/e2e_warn_harness.py --expect-warn       # 阳性对照：期望出现 WARN
    python3 scripts/e2e_warn_harness.py --binary /path/cjh  # 指定被测二进制
退出码：0 = 符合期望；1 = 不符合期望。
"""

import argparse
import json
import os
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tui_pty_test as T  # noqa: E402  复用伪终端会话与配置模板（自身有 __main__ 守卫）

WARN_MARK = "sendRequestTimeout readTimer"
WARN_FULL = "[ConnNode#sendRequestTimeout readTimer] Client1.1 read response timeout"


class StallServer(threading.Thread):
    """accept 后读请求、永不回响应：制造"网络卡死"，逼出客户端 readTimer 路径。"""

    def __init__(self, mode: str = "silent"):
        super().__init__(daemon=True)
        self.mode = mode
        self.accepted = 0
        self._conns = []
        self._stop = threading.Event()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(16)
        self._sock.settimeout(0.5)
        self.port = self._sock.getsockname()[1]

    def run(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.accepted += 1
            self._conns.append(conn)
            if self.mode == "headers":
                # 只给响应头、体永不发：卡在"读响应体"而不是"等响应头"
                try:
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n")
                except OSError:
                    pass

    def close(self) -> None:
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass
        for c in self._conns:
            try:
                c.close()
            except OSError:
                pass


def make_web_config(timeout_seconds: int) -> str:
    """临时配置目录：开 web_fetch + 放行 localhost（停滞服务端在 127.0.0.1）。"""
    cfg = T.make_config_dir()
    path = os.path.join(cfg, "settings.json")
    with open(path) as f:
        settings = json.load(f)
    settings["web_fetch"] = {
        "enabled": True,
        "allow_internal_hosts": True,
        "timeout_seconds": timeout_seconds,
    }
    with open(path, "w") as f:
        json.dump(settings, f)
    return cfg


def readlink_fd1(pid: int) -> str:
    """TUI 存活期间子进程 fd 1 的真实指向 —— 结构性隔离的直接证据。

    隔离生效 = fd 1 被指向 /dev/null（库噪声进不了终端）；
    未隔离 = fd 1 还是那个 pty 从设备（/dev/pts/N）。
    """
    try:
        return os.readlink(f"/proc/{pid}/fd/1")
    except OSError as e:
        return f"<读取失败: {e}>"


def run_once(binary: str, timeout_seconds: int, mode: str, wait_final: float) -> tuple:
    srv = StallServer(mode)
    srv.start()
    os.environ["CJH_MOCK_WEB_URL"] = f"http://127.0.0.1:{srv.port}/stall"
    T.BIN = binary
    cfg = make_web_config(timeout_seconds)
    s = T.PtuSession(cfg, mock_verify=True, timeout=60.0)
    got_final = False
    fd1_target = ""
    try:
        s.read_available(1.0)
        fd1_target = readlink_fd1(s.pid)
        s.send("抓一下这个页面\r")
        deadline = time.time() + wait_final
        while time.time() < deadline:
            s.read_available(0.3)
            if "FINAL-DONE" in T.strip_ansi(s.buf):
                got_final = True
                break
        # 收尾再排空几秒：迟到的 WARN 也进缓冲（旧构建的 readTimer 在 10s 后才响）
        end = time.time() + 3.0
        while time.time() < end:
            s.read_available(0.3)
    finally:
        text = T.strip_ansi(s.buf)
        s.close()
        srv.close()
    return text, got_final, srv.accepted, fd1_target


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=T.BIN, help="被测 cjh 二进制")
    ap.add_argument("--timeout", type=int, default=0,
                    help="settings.json 的 web_fetch.timeout_seconds（默认 0=缺口最恶劣值）")
    ap.add_argument("--mode", default="silent", choices=["silent", "headers"],
                    help="silent=等响应头就卡死；headers=给了头再卡住读体")
    ap.add_argument("--expect-warn", action="store_true", help="阳性对照：期望出现 WARN")
    ap.add_argument("--wait-final", type=float, default=45.0)
    args = ap.parse_args()

    print(f"[台子] 二进制={args.binary}")
    print(f"[台子] web_fetch.timeout_seconds={args.timeout} 停滞模式={args.mode} "
          f"期望={'出现 WARN' if args.expect_warn else '无 WARN'}")

    text, got_final, accepted, fd1_target = run_once(
        args.binary, args.timeout, args.mode, args.wait_final)
    has_warn = WARN_MARK in text

    print(f"[证据] 停滞服务端 accept={accepted} 次（>0 = 真实 HTTP 链路确实跑通）")
    print(f"[证据] 会话出现最终答复 FINAL-DONE={got_final}")
    print(f"[证据] TUI 存活期间子进程 fd 1 → {fd1_target}"
          f"（/dev/null = 已与终端解耦）")
    if has_warn:
        i = text.index(WARN_MARK)
        print(f"[证据] 命中 WARN 原文: {text[max(0, i - 40):i + len(WARN_FULL) + 20]!r}")
    else:
        print("[证据] 整段 PTY 输出中未出现 readTimer WARN")

    if accepted == 0:
        print("[FAIL] 停滞服务端零连接：web_fetch 没被真正调用（链路未跑通，断言无意义）")
        return 1
    if has_warn != args.expect_warn:
        print(f"[FAIL] 期望 expect-warn={args.expect_warn}，实际 has_warn={has_warn}")
        return 1
    # 结构断言：现行构建必须已把 fd 1 让给 /dev/null；阳性对照（改动前的构建）必须还没让
    isolated = fd1_target == "/dev/null"
    if args.expect_warn:
        if isolated:
            print("[FAIL] 阳性对照不该已经解耦 fd 1（该断言前提不成立）")
            return 1
    else:
        if not isolated:
            print(f"[FAIL] 期望 fd 1 已解耦到 /dev/null，实际 {fd1_target}")
            return 1
    print(f"[PASS] 符合期望（has_warn={has_warn}，fd1={fd1_target}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
