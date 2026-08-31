import os, sys, time, tempfile, json, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import tui_pty_test as T
from tui_pty_test import PtuSession

class RealSession(PtuSession):
    def __init__(self, config_dir, timeout=30.0):
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
        import struct, fcntl, termios
        winsize = struct.pack("HHHH", 24, 80, 0, 0)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)

def cfg(port, idle=180):
    d = tempfile.mkdtemp(prefix="cjh_real_")
    with open(os.path.join(d, "settings.json"), "w") as f:
        json.dump({"model": "stall-model", "base_url": f"http://127.0.0.1:{port}/v1/chat/completions"}, f)
    with open(os.path.join(d, "auth.json"), "w") as f:
        json.dump({"api_key": "k"}, f)
    if idle != 180:
        os.environ["CJH_IDLE_TIMEOUT_SECS"] = str(idle)
    else:
        os.environ.pop("CJH_IDLE_TIMEOUT_SECS", None)
    return d

port = 18121

print("=== 场景 B：坏代理停滞中 Ctrl+C ×2 强退（不 segfault）===")
p = subprocess.Popen(["python3", "bad_proxy.py", str(port)])
time.sleep(0.5)
d = cfg(port)
s = RealSession(d)
try:
    s.expect("cjh")
    time.sleep(1.0)
    s.send("强退测试\n")
    s.expect("第二段内容")
    time.sleep(1.0)
    s.send_key(3)   # 第一次：请求中断
    time.sleep(0.8)
    s.send_key(3)   # 第二次：强制退出（_exit）
    code = s.wait_exit(timeout=15)
    print(f"  强退 exit code={code}", "PASS(不 segfault)" if code in (0, 1) else f"FAIL(-{code} segfault)")
finally:
    s.close(); p.kill(); p.wait()

print("=== 场景 C：停滞自动恢复（parser 空闲预算，非无限卡）===")
p = subprocess.Popen(["python3", "bad_proxy.py", str(port)])
time.sleep(0.5)
d = cfg(port, idle=15)
s = RealSession(d)
try:
    s.expect("cjh")
    time.sleep(1.0)
    s.send("测试停滞\n")
    s.expect("第二段内容")
    t0 = time.time()
    s.expect("round", timeout=45)   # 停滞 15s 后回合自动结束（总结条）
    dt = time.time() - t0
    print(f"  停滞→回合自动结束: {dt:.1f}s", "PASS" if dt < 40 else "FAIL")
    time.sleep(0.5)
    s.send_key(3)   # 空闲：一次退出
    s.wait_exit(timeout=15)
finally:
    s.close(); p.kill(); p.wait()
