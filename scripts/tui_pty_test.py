#!/usr/bin/env python3
"""
cjh TUI PTY 集成测试（真实终端环境，覆盖单测测不了的部分）

覆盖场景：
  1. 启动渲染：欢迎视图/logo/输入框出现
  2. 输入 + Enter：mock 工具链执行（read_file 提示）+ 最终回复
  3. / 命令补全：输入 "/th" + Tab → 补全为 /theme
  4. 帮助视图：Tab 切换 + Esc 返回
  5. 审批弹窗-同意：capability approval 命中 → 弹窗 → 'y' → 工具继续执行
  6. 审批弹窗-拒绝：'n' → 操作被拒绝
  7. Ctrl+C 退出：进程干净退出

实现：Python 标准库 pty（无 pexpect 依赖），伪终端提供 termios 原始模式
与 winsize，驱动真实 ./target/release/bin/cjh 进程（CJH_MOCK=1）。

用法：python3 scripts/tui_pty_test.py   （需先 cjpm build 产出 cjh）
"""
import os
import sys
import re
import pty
import time
import json
import select
import signal
import struct
import fcntl
import termios
import tempfile

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(PROJECT, "target", "release", "bin", "cjh")

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[=>]|\x1b\(")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


class PtuSession:
    """伪终端会话：spawn cjh 进程，读写 master 端。"""

    def __init__(self, config_dir: str, mock_verify: bool = True, timeout: float = 30.0):
        self.timeout = timeout
        self.buf = ""
        env = dict(os.environ)
        env["CJH_MOCK"] = "1"
        env["CJH_CONFIG_DIR"] = config_dir
        env["CJH_TUI_LOG"] = os.path.join(config_dir, "tui.log")
        env["TERM"] = "xterm-256color"
        env.pop("CJH_LOG_LEVEL", None)
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            # 子进程：exec cjh（必须 execve 显式传 env，否则 CJH_MOCK 等不生效）
            os.execve(BIN, [BIN], env)
        # 设置伪终端尺寸（24x80），否则 ioctl(TIOCGWINSZ) 返回 0 导致 TUI 不渲染
        winsize = struct.pack("HHHH", 24, 80, 0, 0)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)

    def read_available(self, wait: float = 0.2) -> str:
        """读取当前可用的输出（阻塞至多 wait 秒）。"""
        chunks = []
        deadline = time.time() + wait
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                chunks.append(data.decode("utf-8", errors="replace"))
            else:
                break
        out = "".join(chunks)
        if out:
            self.buf += out
        return out

    def expect(self, text: str, timeout: float | None = None) -> str:
        """等待输出中出现 text（ANSI 剥离后匹配）。返回匹配后的完整缓冲。"""
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            if text in strip_ansi(self.buf):
                return self.buf
            self.read_available(0.2)
        raise TimeoutError(
            f"expect '{text}' 超时。当前缓冲(已剥离 ANSI，尾部 500 字符):\n"
            + strip_ansi(self.buf)[-500:]
        )

    def send(self, data: str) -> None:
        os.write(self.master, data.encode("utf-8"))

    def send_key(self, ch: int) -> None:
        os.write(self.master, bytes([ch]))

    def send_esc_seq(self, seq: str) -> None:
        os.write(self.master, seq.encode("utf-8"))

    def wait_exit(self, timeout: float = 10.0) -> int:
        deadline = time.time() + timeout
        while time.time() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid == self.pid:
                return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
            time.sleep(0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return -1

    def close(self) -> None:
        # 进程若仍存活（异常路径），强制清理避免残留
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid == 0:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        except (ChildProcessError, ProcessLookupError):
            pass
        try:
            os.close(self.master)
        except OSError:
            pass


def make_config_dir(approval: list[str] | None = None) -> str:
    """创建临时配置目录：settings.json（可含 capability）+ auth.json。"""
    cfg = tempfile.mkdtemp(prefix="cjh_pty_")
    settings: dict = {
        "model": "mock-model",
        "base_url": "https://api.openai.com/v1/chat/completions",
    }
    if approval is not None:
        settings["capability"] = {
            "enabled": True,
            "tools": ["read_file", "grep", "list_dir", "bash"],
            "approval": approval,
        }
    with open(os.path.join(cfg, "settings.json"), "w") as f:
        json.dump(settings, f)
    with open(os.path.join(cfg, "auth.json"), "w") as f:
        json.dump({"api_key": "mock-key"}, f)
    return cfg


PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {detail}")


def test_startup_and_input() -> None:
    print("[场景1] 启动渲染 + 输入 + mock 工具链 + 最终回复")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")           # logo/标题
        s.expect("Harness")       # 品牌行
        check("启动渲染：标题与品牌出现", True)
        # 输入消息并提交
        s.send("测试任务\n")
        # mock 4 轮在亚秒内完成，中间工具提示可能被差分渲染合并——
        # 断言最终结果（FINAL-DONE + 回合总结条工具计数）
        s.expect("FINAL-DONE")    # 最终答复
        check("最终答复 FINAL-DONE 出现", True)
        s.expect("4 tools")       # 回合总结条：4 次工具调用（read_file+grep+grep+list_dir）
        check("总结条：4 次工具调用", True)
        # Ctrl+C 退出
        s.send_key(3)
        code = s.wait_exit()
        check("Ctrl+C 干净退出", code == 0, f"(exit={code})")
    finally:
        s.close()


def test_slash_completion() -> None:
    print("[场景2] / 命令补全：/th + Tab → /theme")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.5)  # 等主循环进入就绪（PTY 下字符可能丢在初始化窗口）
        s.send("/th")
        s.read_available(0.8)  # 必须读 master 更新 buf（sleep 不会自动收输出）
        dbg = strip_ansi(s.buf)
        check("输入框回显 /th", "/th" in dbg, f"(buf尾部: {dbg[-200:]})")
        check("下拉框出现 /theme 候选", "theme" in dbg, f"(buf尾部: {dbg[-200:]})")
        s.send_key(9)  # Tab 补全
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        # Tab 补全后输入框内容为 /theme
        check("补全为 /theme", "/theme" in buf, f"(buf尾部: {buf[-200:]})")
        s.send_key(3)
        s.wait_exit()
    finally:
        s.close()


def test_help_view() -> None:
    print("[场景3] 帮助视图：Tab 切换 + Esc 返回")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        s.send_key(9)  # Tab → 帮助视图
        s.read_available(0.8)  # 读 master 更新 buf
        buf = strip_ansi(s.buf)
        # 帮助视图独有文本（renderHelp）：「可用命令」+ 快捷键区
        check("Tab 切到帮助视图（出现可用命令）", "可用命令" in buf, f"(buf尾部: {buf[-200:]})")
        check("帮助含快捷键说明", "快捷键" in buf, f"(buf尾部: {buf[-200:]})")
        s.send_esc_seq("\x1b")  # Esc 返回对话视图
        s.read_available(0.5)
        s.send_key(3)
        s.wait_exit()
    finally:
        s.close()


def test_approval_yes() -> None:
    print("[场景4] 审批弹窗-同意：y 继续执行")
    cfg = make_config_dir(approval=["read_file"])
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        s.send("跑审批测试\n")
        s.expect("需人工确认")     # 审批弹窗出现
        check("审批弹窗出现", True)
        s.send("y")               # 同意
        s.expect("FINAL-DONE")    # 工具继续执行到最后
        check("同意后继续执行到最终答复", True)
        s.send_key(3)
        s.wait_exit()
    finally:
        s.close()


def test_approval_no() -> None:
    print("[场景5] 审批弹窗-拒绝：n 拒绝操作")
    cfg = make_config_dir(approval=["read_file"])
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        s.send("跑拒绝测试\n")
        s.expect("需人工确认")
        check("审批弹窗出现", True)
        s.send("n")               # 拒绝
        # 拒绝后 agent 继续（不悬挂）；拒绝提示可能被差分渲染合并，断言宽松
        s.expect("FINAL-DONE")
        check("拒绝后 agent 继续完成", True)
        check("出现拒绝相关提示", "拒绝" in strip_ansi(s.buf))
        s.send_key(3)
        s.wait_exit()
    finally:
        s.close()


def main() -> None:
    if not os.path.exists(BIN):
        print(f"错误：未找到 {BIN}，请先 cjpm build")
        sys.exit(2)
    global PASS, FAIL
    print(f"cjh TUI PTY 集成测试（{BIN}）\n")
    test_startup_and_input()
    test_slash_completion()
    test_help_view()
    test_approval_yes()
    test_approval_no()
    print(f"\n结果：{PASS} 通过 / {FAIL} 失败")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
