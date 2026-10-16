#!/usr/bin/env python3
"""cjh Web 端到端冒烟：HTTP 静态资源 + WS 控制帧回执（自起自停 mock 服务）。

为什么单列一个脚本（而不是并入 cjpm test）：
    这里的断言要求**真的起一个 HTTP/WS 服务**——`cjpm test` 跑的是内嵌资产与
    网关逻辑，覆盖不到"浏览器实际拿到的东西"与"帧发出去到底回没回"。
    两者互补：单测管逻辑，本脚本管契约。

用法：
    source /opt/cangjie/cangjie/envsetup.sh && cjpm build
    python3 scripts/web_smoke_test.py
退出码：0 = 全部通过；1 = 有断言失败（明细打在最前）。
WS 断言依赖 websocket-client（未安装时打印 SKIP 并只跑 HTTP 部分）。
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "target/release/bin/cjh"

FAILURES = []


def check(name, ok, detail=""):
    line = ("  [OK]   " if ok else "  [FAIL] ") + name
    if detail and not ok:
        line += "  <- " + detail
    print(line, flush=True)
    if not ok:
        FAILURES.append(name + ((": " + detail) if detail else ""))


def skip(name, why):
    print("  [SKIP] " + name + "  <- " + why, flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def http_get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def wait_ready(base, proc, timeout=20.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            out = proc.stdout.read() if proc.stdout else ""
            return False, "服务进程提前退出 rc=%s\n%s" % (proc.returncode, out[-800:])
        try:
            urllib.request.urlopen(base + "/api/health", timeout=1)
            return True, ""
        except Exception:
            time.sleep(0.3)
    return False, "%.0fs 内未就绪" % timeout


def main():
    if not BIN.exists():
        print("找不到二进制：%s\n请先 source /opt/cangjie/cangjie/envsetup.sh && cjpm build" % BIN)
        return 1

    try:
        import websocket  # noqa: F401
        has_ws = True
    except Exception:
        has_ws = False

    port = free_port()
    base = "http://127.0.0.1:%d" % port
    env = dict(os.environ)
    env["CJH_MOCK"] = "1"
    proc = subprocess.Popen(
        [str(BIN), "web", "--port", str(port), "--bind", "127.0.0.1"],
        cwd=str(ROOT), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        print("== cjh web 冒烟（port=%d, CJH_MOCK=1）==" % port, flush=True)
        ok, why = wait_ready(base, proc)
        check("服务就绪 /api/health", ok, why)
        if not ok:
            return 1

        health = json.loads(http_get(base + "/api/health"))
        check("/api/health status=ok", health.get("status") == "ok", str(health))

        caps = json.loads(http_get(base + "/api/capabilities"))
        check("/api/capabilities protocol=4", caps.get("protocol") == 4, str(caps)[:200])
        check("能力自述含出站 approval_request",
              "approval_request" in (caps.get("ws_out") or []))
        check("能力自述含入站 approval_response",
              "approval_response" in (caps.get("ws_in") or []))
        check("features.approval_over_ws=true",
              (caps.get("features") or {}).get("approval_over_ws") is True,
              str(caps.get("features"))[:200])
        check("features.diff_in_tool_result=true",
              (caps.get("features") or {}).get("diff_in_tool_result") is True,
              str(caps.get("features"))[:200])

        html = http_get(base + "/")
        check("页面含轻提示条 #notice-bar", 'id="notice-bar"' in html)
        check("页面含模型下拉 #model-selector", 'id="model-selector"' in html)
        check("页面含审批弹窗 #approval-modal", 'id="approval-modal"' in html)
        check("页面含审批同意按钮 #approval-allow-btn", 'id="approval-allow-btn"' in html)
        check("页面含审批倒计时 #approval-countdown", 'id="approval-countdown"' in html)

        js = http_get(base + "/assets/app.js")
        for token in ("switch_model", "handleAck", "handleCancelled", "notice-bar",
                      "type: 'cancel'", "handleApprovalRequest", "sendApprovalResponse",
                      "approval_response", "buildDiffBlock", "provider_auth_error",
                      "provider_unreachable", "summary.truncated"):
            check("app.js 含 %s" % token, token in js)
        css = http_get(base + "/assets/styles.css")
        check("styles.css 含 .notice-bar", ".notice-bar" in css)
        check("styles.css 含 .approval-dialog", ".approval-dialog" in css)
        check("styles.css 含 .diff-block", ".diff-block" in css)

        if not has_ws:
            skip("WS 控制帧回执", "未安装 websocket-client（pip install websocket-client）")
        else:
            import websocket
            ws = websocket.create_connection("ws://127.0.0.1:%d/ws" % port, timeout=15)

            def recv_any(types, limit=12):
                for _ in range(limit):
                    m = json.loads(ws.recv())
                    if m.get("type") in types:
                        return m
                return None

            # 1) compact：控制帧不许静默 —— 必回 ack
            ws.send(json.dumps({"type": "compact"}))
            ack = recv_any({"ack", "error"})
            check("compact → ack", bool(ack) and ack.get("type") == "ack" and ack.get("action") == "compact",
                  json.dumps(ack, ensure_ascii=False) if ack else "无回执（静默！）")
            check("ack.compacted 字段存在", bool(ack) and "compacted" in ack,
                  json.dumps(ack, ensure_ascii=False) if ack else "无回执")

            # 2) switch_model：取配置里的当前模型，必回 ack（含端点回显）或 error
            models = json.loads(http_get(base + "/api/models"))
            model = models.get("current") or ""
            ws.send(json.dumps({"type": "switch_model", "model": model}))
            res = recv_any({"ack", "error"})
            check("switch_model → ack/error（不静默）", bool(res), "无回执（静默！）")
            if res and res.get("type") == "ack":
                check("switch_model ack.model 回显", res.get("model") == model,
                      json.dumps(res, ensure_ascii=False))

            # 3) cancel：无回合在跑 → cancelled(was_running=false)
            ws.send(json.dumps({"type": "cancel"}))
            cancel = recv_any({"cancelled"})
            check("cancel → cancelled", bool(cancel), "无回执（静默！）")
            check("cancel 无回合时 was_running=false",
                  bool(cancel) and cancel.get("was_running") is False,
                  json.dumps(cancel, ensure_ascii=False) if cancel else "无回执")

            # 4) abort 别名（旧客户端）同样必回 cancelled
            ws.send(json.dumps({"type": "abort"}))
            check("abort → cancelled", bool(recv_any({"cancelled"})), "无回执（静默！）")

            # 4b) approval_response：未知 request_id 必须回结构化错误（不静默）
            ws.send(json.dumps({"type": "approval_response",
                                "request_id": "no-such-request", "approved": True}))
            appr = recv_any({"error"})
            check("approval_response 未知 id → error(approval_unknown)",
                  bool(appr) and appr.get("code") == "approval_unknown",
                  json.dumps(appr, ensure_ascii=False) if appr else "无回执（静默！）")

            # 5) 回合进行中 cancel：帧不许被吞（was_running 取值不作断言，如实打印）
            ws.send(json.dumps({"type": "chat", "message": "冒烟：请回一句 ok"}))
            ws.send(json.dumps({"type": "cancel"}))
            live = recv_any({"cancelled"}, limit=40)
            check("回合中 cancel → cancelled", bool(live), "无回执（静默！）")
            if live:
                print("         （本次 was_running=%s）" % live.get("was_running"), flush=True)

            ws.close()
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except Exception:
                proc.kill()
                proc.wait(timeout=10)

    print("== 结果：%d 项失败 ==" % len(FAILURES), flush=True)
    for f in FAILURES:
        print("  FAILED: " + f, flush=True)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
