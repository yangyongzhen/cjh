import os, sys, time, tempfile, json, subprocess, struct, fcntl, termios
sys.path.insert(0, "/root/test/cj/cjh/scripts")
import tui_pty_test as T

class RealSession(T.PtuSession):
    def __init__(self, config_dir, timeout=90.0):
        self.timeout = timeout
        self.buf = ""
        env = dict(os.environ)
        env["CJH_CONFIG_DIR"] = config_dir
        env["CJH_TUI_LOG"] = os.path.join(config_dir, "tui.log")
        env["TERM"] = "xterm-256color"
        env.pop("CJH_MOCK", None)
        self.pid, self.master = __import__("pty").fork()
        if self.pid == 0:
            os.execve(T.BIN, [T.BIN], env)
        winsize = struct.pack("HHHH", 24, 80, 0, 0)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)

port = 18122
os.environ["CJH_IDLE_TIMEOUT_SECS"] = "10"
p = subprocess.Popen(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bad_proxy_keepalive.py"), str(port)])
time.sleep(0.8)
d = tempfile.mkdtemp(prefix="cjh_ka_")
with open(os.path.join(d, "settings.json"), "w") as f:
    json.dump({"model": "stall", "base_url": f"http://127.0.0.1:{port}/v1/chat/completions"}, f)
with open(os.path.join(d, "auth.json"), "w") as f:
    json.dump({"api_key": "k"}, f)
s = RealSession(d)
try:
    s.expect("cjh")
    time.sleep(1.0)
    s.send("测试\n")
    s.expect("第二段内容", timeout=15)
    print("内容输出 ✓")
    t0 = time.time()
    # 代理持续空帧 → parser 预算绕过 → 看门狗 10s 兜底
    s.expect("无响应", timeout=30)
    print(f"看门狗触发: {time.time()-t0:.1f}s ✓")
    # 回合结束（总结条）
    s.expect("round", timeout=20)
    print(f"回合结束: {time.time()-t0:.1f}s ✓")
    # 检查日志诊断
    tl = open(os.path.join(d, "tui.log")).read()
    print("tui.log 看门狗记录:", [l.split('"')[-1] for l in tl.splitlines() if "看门狗" in l][:2])
finally:
    os.environ.pop("CJH_IDLE_TIMEOUT_SECS", None)
    s.close(); p.kill(); p.wait()
