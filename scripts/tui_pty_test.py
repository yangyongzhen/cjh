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

    def __init__(self, config_dir: str, mock_verify: bool = True, timeout: float = 30.0,
                 extra_env: dict | None = None):
        self.timeout = timeout
        self.buf = ""
        env = dict(os.environ)
        env["CJH_MOCK"] = "1"
        env["CJH_CONFIG_DIR"] = config_dir
        env["CJH_TUI_LOG"] = os.path.join(config_dir, "tui.log")
        env["TERM"] = "xterm-256color"
        env.pop("CJH_LOG_LEVEL", None)
        if extra_env:
            env.update(extra_env)
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

    def expect_count(self, text: str, count: int, timeout: float | None = None) -> str:
        """等待输出中出现 text 至少 count 次（ANSI 剥离后计数；expect 无位置游标，
        重复 expect 同一文本会命中同一处，必须计数等待）。"""
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            if strip_ansi(self.buf).count(text) >= count:
                return self.buf
            self.read_available(0.2)
        raise TimeoutError(
            f"expect '{text}' x{count} 超时。当前缓冲(已剥离 ANSI，尾部 500 字符):\n"
            + strip_ansi(self.buf)[-500:]
        )

    def wait_new_output(self, start: int, timeout: float = 0.8) -> bool:
        """等待 start 之后出现新输出（弹窗文案相同、diff 渲染可能不重发文本，
        所以只要求有新字节；超时返回 False，由调用方按已渲染处理）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.read_available(0.05)
            if len(strip_ansi(self.buf)) > start:
                return True
        return False

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


def make_config_dir(approval: list[str] | None = None,
                    base_url: str = "https://api.openai.com/v1/chat/completions",
                    model: str = "mock-model") -> str:
    """创建临时配置目录：settings.json（可含 capability）+ auth.json。"""
    cfg = tempfile.mkdtemp(prefix="cjh_pty_")
    settings: dict = {
        "model": model,
        "base_url": base_url,
    }
    if approval is not None:
        settings["capability"] = {
            "enabled": True,
            # task：供 CJH_MOCK_TASKS 门控派子代理用（其余场景 mock 不发 task，无影响）
            "tools": ["read_file", "grep", "list_dir", "bash", "task"],
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
        # 工具结果默认折叠：摘要行带 Ctrl+O 提示，明细行不绘制；
        # Ctrl+O 展开后同一份明细必须出现在屏幕上（真实渲染，非单测行缓存）。
        s.read_available(0.5)
        dbg = strip_ansi(s.buf)
        # list_dir 明细 = /tmp 前 50 项（读序不定）：目录项带 "/"，只会出现在明细里
        # （工具调用行只显示路径 /tmp）；折叠态一条都不绘制，展开后视口内至少一条。
        tmpDirs = [n + "/" for n in os.listdir("/tmp")
                   if len(n) > 6 and os.path.isdir(os.path.join("/tmp", n))]
        check("工具明细默认折叠（摘要带 Ctrl+O 切换提示）", "Ctrl+O 切换" in dbg,
              f"(buf尾部: {dbg[-200:]})")
        check("折叠态不绘制明细行", not any(n in dbg for n in tmpDirs),
              f"(buf尾部: {dbg[-200:]})")
        s.send_key(15)  # Ctrl+O 展开全部工具明细
        s.read_available(0.8)
        delta = strip_ansi(s.buf)[len(dbg):]
        check("Ctrl+O 展开明细", any(n in delta for n in tmpDirs),
              f"(delta尾部: {delta[-300:]})")
        # Ctrl+C 退出
        s.send_key(3)  # 空闲：一次退出
        code = s.wait_exit()
        check("Ctrl+C 干净退出", code == 0, f"(exit={code})")
    finally:
        s.close()


def test_status_cache_and_round() -> None:
    """[场景1b] 状态行可观测：usage → 缓存命中率，多轮 → 第 N 轮

    CJH_MOCK_USAGE 给 mock 响应附真实 usage（默认 0，不影响其他场景）。
    这里断言状态行确实把 provider usage 显示出来，而不是只有单测里的纯函数。
    """
    print("[场景1b] 状态行缓存命中率 + 轮次推进")
    cfg = make_config_dir()
    s = PtuSession(cfg, extra_env={"CJH_MOCK_DELAY_MS": "800", "CJH_MOCK_USAGE": "10000:5000"})
    try:
        s.expect("cjh")
        time.sleep(0.5)
        s.send("状态行测试\n")
        s.expect("缓存 50%", timeout=20)
        check("状态行显示缓存命中率", True)
        s.expect("第 2 轮", timeout=20)
        check("多轮任务显示第 N 轮", True)
        s.expect("FINAL-DONE", timeout=30)
        s.send_key(3)
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
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
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_fullwidth_slash_dispatch() -> None:
    """[场景2b] 全角斜杠 / 行首空格：应识别为命令，不得发给模型

    中文输入法下敲 `/` 常得到全角 `／`（U+FF0F），行首也可能带全角空格；
    旧实现只认 ASCII 前缀，这类输入会作为普通消息发给模型（现象：发完跑一轮 mock 任务）。
    """
    print("[场景2b] 全角斜杠 / 行首空格命令分发")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.2)
        s.send("／theme dracula\r")
        s.expect("[主题已切换: dracula]", timeout=15)
        check("全角 ／theme 被识别为命令", True)
        time.sleep(0.6)
        s.read_available(0.3)
        buf = strip_ansi(s.buf)
        check("全角命令未发给 agent（无 FINAL-DONE）", "FINAL-DONE" not in buf,
              f"(buf尾部: {buf[-200:]})")
        with open(os.path.join(cfg, "settings.json"), encoding="utf-8") as f:
            theme = json.load(f).get("theme")
        check("全角命令写入 settings", theme == "dracula", f"(theme={theme})")
        # 行首空格 + /help：候选与分发都必须按归一化文本识别
        s.send(" /help\r")
        s.expect_count("/theme [name]", 1, timeout=15)
        check("行首空格 /help 被识别为命令", True)
        # 仅输入全角斜杠：候选菜单应弹出，Enter 选中 /help 并执行（第二份帮助）
        s.send("／\r")
        s.expect_count("/theme [name]", 2, timeout=15)
        check("仅 ／ 触发候选并执行 /help", True)
        s.read_available(0.3)
        buf = strip_ansi(s.buf)
        check("全程未触发 agent 回合", "FINAL-DONE" not in buf, f"(buf尾部: {buf[-200:]})")
        s.send_key(3)
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
    finally:
        s.close()


def test_busy_slash_command_dispatch() -> None:
    """[场景2c] 模型忙时 /theme：必须排队为命令，不得作为用户消息注入回合

    用户实测：空闲时 `/theme` 正常，模型干活时输入却被当成内容发出去。
    旧实现忙时所有提交都进 steer 队列，工具批次边界直接注入模型。
    """
    print("[场景2c] 忙时 /theme 命令排队（不发给模型）")
    cfg = make_config_dir()
    s = PtuSession(cfg, extra_env={"CJH_MOCK_DELAY_MS": "1000"})
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("慢任务\n")
        time.sleep(1.5)  # 进入执行态（mock 每轮延迟中）
        s.send("/theme dracula\r")
        s.expect("命令已排队", timeout=10)
        check("忙时 /theme 进入命令队列", True)
        # 命令后面紧跟普通消息：命令执行后必须继续出队，否则消息会永久卡住
        s.send("第二个任务\n")
        s.read_available(0.3)
        buf = strip_ansi(s.buf)
        check("命令未在当前回合立即执行", "[主题已切换" not in buf, f"(buf尾部: {buf[-200:]})")
        s.expect("[主题已切换: dracula]", timeout=30)
        check("当前回合结束后命令执行", True)
        with open(os.path.join(cfg, "settings.json"), encoding="utf-8") as f:
            theme = json.load(f).get("theme")
        check("忙时命令写入 settings", theme == "dracula", f"(theme={theme})")
        # 第二个任务应作为新回合执行并落会话（命令排空后不能把后续消息留在队列）
        deadline = time.time() + 25
        ran_second = False
        while time.time() < deadline and not ran_second:
            for root, _, files in os.walk(os.path.join(cfg, "sessions")):
                for fn in files:
                    try:
                        with open(os.path.join(root, fn), encoding="utf-8", errors="ignore") as f:
                            if "第二个任务" in f.read():
                                ran_second = True
                                break
                    except OSError:
                        pass
                if ran_second:
                    break
            if not ran_second:
                time.sleep(0.3)
        check("命令后的排队消息继续执行", ran_second)
        s.send_key(3)
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
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
        # 帮助视图独有文本（renderHelp）：「可用命令」
        check("Tab 切到帮助视图（出现可用命令）", "可用命令" in buf, f"(buf尾部: {buf[-200:]})")
        check("帮助含新增命令（/theme）", "/theme" in buf, f"(buf尾部: {buf[-200:]})")
        # 帮助内容超一屏（24 行终端）：PageDown 滚动到快捷键区
        s.send_esc_seq("\x1b[6~")  # PageDown
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        check("帮助可滚动到快捷键区", "快捷键" in buf, f"(buf尾部: {buf[-250:]})")
        s.send_esc_seq("\x1b")  # Esc 返回对话视图
        s.read_available(0.5)
        s.send_key(3)  # 空闲：一次退出
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
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_approval_queue() -> None:
    print("[场景4b] 审批队列化：两路并发审批 → y 只批队首 → 标题 (2/2)")
    cfg = make_config_dir(approval=["read_file"])
    # CJH_MOCK_TASKS：父 mock 第 2 轮并发派两个 explore 子代理，
    # 各自第 1 轮的 read_file 撞审批 → 两路审批同时进 TUI 队列
    s = PtuSession(cfg, extra_env={"CJH_MOCK_TASKS": "1"})
    try:
        s.expect("cjh")
        s.send("跑审批排队测试\n")
        s.expect("需人工确认")                 # 队首审批弹窗出现
        s.expect("审批 (1/2)", timeout=15)     # 第二路入队后标题刷新为 (1/2)
        check("两路入队：标题刷新为 审批 (1/2)", True)
        s.send("y")                            # 只批队首
        s.expect("审批 (2/2)")                 # 应答后自动弹出下一项
        check("y 只批队首：标题推进 (2/2) 且第二项弹窗可见", True)
        check("第二项带 [task:label] 身份", "[task:并发审批" in strip_ansi(s.buf))
        s.send("y")                            # 批第二路
        s.expect("FINAL-DONE")
        check("两路审批后 agent 完成回合", True)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_approval_danger_denied_switches_safe() -> None:
    print("[场景5b] 危险命令拒绝：rm -rf 被拒后改用安全只读命令")
    cfg = make_config_dir(approval=["bash"])
    # 第 2 轮发 rm -rf（撞审批），第 3 轮发 echo 安全命令（再撞审批）
    s = PtuSession(cfg, extra_env={"CJH_MOCK_DANGER": "1"})
    try:
        s.expect("cjh")
        s.send("跑危险命令拒绝测试\n")
        s.expect("需人工确认")
        s.expect("rm -rf /tmp/cjh_mock_danger_probe")
        check("危险命令进入审批弹窗", True)
        s.send("n")  # 拒绝删除
        # 拒绝后 agent 必须继续，且下一轮改用安全命令（不是重复请求 rm -rf）
        s.expect("cjh-safe-alternative", timeout=20)
        check("拒绝后模型改用安全方案", True)
        # 安全命令同样要过审批。注意 approve 弹窗文案与首张相同，diff 渲染可能
        # 不重发文本，因此不能靠文字第二次出现判断；等一小段新输出（弹窗绘制）
        # 后再按 y，避免按键落在「工具已开始但审批尚未接管输入」的间隙里。
        mark = len(strip_ansi(s.buf))
        s.wait_new_output(mark, timeout=0.8)
        s.send("y")  # 批准安全命令
        s.expect("FINAL-DONE")
        check("安全方案执行后回合完成", True)
        check("出现拒绝相关提示", "拒绝" in strip_ansi(s.buf))
        s.send_key(3)
        s.wait_exit()
    finally:
        s.close()


def test_agents_panel_focus() -> None:
    print("[场景4c] Agents 面板：并发子代理行可见 + Ctrl+G 焦点切换（真断言，非框线假绿）")
    cfg = make_config_dir()  # 无 approval：子代理一路跑完，不弹审批
    # CJH_MOCK_TASKS：父并发派两个 explore；CJH_MOCK_DELAY_MS 拖慢每轮，
    # 给面板行渲染与焦点切换留观察窗口
    s = PtuSession(cfg, extra_env={"CJH_MOCK_TASKS": "1", "CJH_MOCK_DELAY_MS": "300"})
    try:
        s.expect("cjh")
        s.send("跑面板测试\n")
        s.expect("Agents")            # 面板标题（节点登记即渲染）
        check("Agents 面板出现", True)
        s.expect("explore")           # 面板行：子代理类型
        check("子代理面板行可见", True)
        # Ctrl+G：焦点 父 → 子。断言"── 焦点: <kind>·<label> ──"这条即时反馈行——
        # 此前断 expect("│") 是假绿：面板左右边框本身就输出 │，Ctrl+G 完全失效也会命中。
        # 注：两个子代理同批并发派发，注册顺序不确定 → 只断"反馈行出现 N 次"，不断具体是哪个
        s.send_key(7)
        s.expect("── 焦点: ")
        check("Ctrl+G 焦点切到子代理（即时反馈行，不再靠框线假绿）", True)
        s.send_key(7)                 # 子1 → 子2
        s.expect_count("── 焦点: ", 2)
        check("Ctrl+G 焦点循环到另一个子代理", True)
        s.send_key(7)                 # 子2 → 父
        s.expect("焦点回到主对话")
        check("Ctrl+G 循环回父", True)
        s.expect("FINAL-DONE")
        check("回合完成", True)
        s.send_key(3)  # 空闲：一次退出
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
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_provider_dialog() -> None:
    print("[场景6] Provider 配置弹窗：默认值按各家预设自洽 + ←→ 切换联动")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(0.5)
        s.send("/provider\n")      # 无参数 → 弹窗
        s.expect("配置 Provider")
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        # 测试配置 base_url=openai 默认 → 弹窗按推断显示 openai 预设（自洽，不掺真实配置）
        check("弹窗出现", True)
        check("Provider 显示 openai", "openai" in buf)
        check("端点=openai（真实配置预填）", "api.openai.com" in buf, f"(buf尾部: {buf[-200:]})")
        check("模型=真实配置预填", "mock-model" in buf)  # 预填 make_config_dir 的 model
        # API Key 不预填（显示 placeholder sk-xxxx，避免误导其他家有 key）
        check("API Key 显示占位符", "sk-xxxx" in buf, f"(buf尾部: {buf[-200:]})")
        check("API Key 无预填星号", "*" * 8 not in buf)
        # ← 切换到 deepseek：端点/模型联动为 deepseek 预设（expect 等唯一新帧，防历史假阳性）
        s.send_esc_seq("\x1b[D")   # 左键 → deepseek
        s.expect("deepseek-chat")  # 唯一文本：联动后的模型
        check("切换到 deepseek（模型联动）", True)
        # → 逐个切到 qwen：验证新增预设联动（deepseek→openai→glm→qwen），
        # 每次 expect 唯一文本（gpt-4o-mini / bigmodel.cn / dashscope），天然拉开时序
        s.send_esc_seq("\x1b[C")   # → openai
        s.expect("gpt-4o-mini")
        check("切回 openai 模型联动", True)
        s.send_esc_seq("\x1b[C")   # → glm
        s.expect("bigmodel.cn")
        check("切换到 glm 端点", True)
        s.send_esc_seq("\x1b[C")   # → qwen
        s.expect("dashscope.aliyuncs.com")
        s.expect("qwen-plus")
        check("切换到 qwen 端点", True)
        check("切换到 qwen 模型", True)
        # → 切到 kimi：验证新增预设（select 只渲染当前值，直接切换验证）
        s.send_esc_seq("\x1b[C")   # → kimi
        s.expect("moonshot.cn")
        s.expect("moonshot-v1-8k")
        check("切换到 kimi 端点", True)
        check("切换到 kimi 模型", True)
        # Esc 关闭
        s.send_esc_seq("\x1b")
        s.read_available(0.3)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_provider_dialog_aggregator() -> None:
    print("[场景7] Provider 弹窗-聚合端点：真实配置（端点/模型）必须体现")
    # 聚合平台（taotoken.net + deepseek-v4-flash）：base_url 未匹配任何预设
    cfg = make_config_dir(base_url="https://taotoken.net/api", model="deepseek-v4-flash")
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(0.5)
        s.send("/provider\n")
        s.expect("配置 Provider")
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        # 聚合端点未匹配预设 → Provider=custom（自定义），端点/模型体现真实配置，协议 openai
        check("聚合端点体现在弹窗", "taotoken.net" in buf, f"(buf尾部: {buf[-200:]})")
        check("真实模型体现在弹窗", "deepseek-v4-flash" in buf, f"(buf尾部: {buf[-200:]})")
        check("Provider 显示 custom（自定义/聚合）", "custom" in buf)
        check("协议=openai", "openai" in buf)
        s.send_esc_seq("\x1b")
        s.read_available(0.3)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_provider_dialog_protocol() -> None:
    print("[场景8] Provider 弹窗-协议切换：custom 下 openai ↔ anthropic")
    cfg = make_config_dir(base_url="https://taotoken.net/api", model="deepseek-v4-flash")
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(0.5)
        s.send("/provider\n")
        s.expect("配置 Provider")
        s.read_available(0.5)
        # ↓ 到协议字段（焦点 0 Provider → 1 协议），→ 切到 anthropic
        s.send_key(9)            # Tab → 协议字段
        s.read_available(0.3)
        s.send_esc_seq("\x1b[C") # → anthropic
        s.expect("anthropic")
        check("协议切到 anthropic", True)
        # 切回 openai
        s.send_esc_seq("\x1b[D")
        s.expect("openai")
        check("协议切回 openai", True)
        s.send_esc_seq("\x1b")
        s.read_available(0.3)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_provider_paste() -> None:
    print("[场景9] Provider 弹窗-粘贴：内容进弹窗字段，不穿透主输入框/不误提交")
    # 聚合端点（custom）：弹窗含协议字段，Tab 两次到端点字段
    cfg = make_config_dir(base_url="https://taotoken.net/api", model="deepseek-v4-flash")
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(0.5)
        s.send("/provider\n")
        s.expect("配置 Provider")
        s.read_available(0.3)
        # Tab × 2：Provider(0) → 协议(1) → 端点(2)
        s.send_key(9)
        s.read_available(0.2)
        s.send_key(9)
        s.read_available(0.2)
        # bracketed paste：ESC[200~ 内容（含换行！） ESC[201~
        # 换行不得触发 Enter 提交、内容不得穿透到主输入框
        s.send("\x1b[200~https://api.example.com/v1\n\x1b[201~")
        s.expect("api.example.com")
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        check("粘贴内容进入弹窗端点字段", "api.example.com" in buf, f"(buf尾部: {buf[-250:]})")
        check("弹窗未被粘贴换行提交（仍打开）", "配置 Provider" in buf)
        check("粘贴内容未穿透主输入框", "❯ api.example.com" not in buf)
        s.send_esc_seq("\x1b")  # 关闭弹窗（Esc 应仍可用）
        s.read_available(0.3)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_queue_and_autodequeue() -> None:
    """[场景10] 忙时 Enter 只入队（不打断当前回合）；方案 2 边界注入：Agent 在
    工具批次执行完、下一轮请求前取**一条**并入本回合——所以只剩**一个**回合、
    不再出现"回合结束后新回合重跑一遍"的第二条总结条。"""
    print("[场景10] 忙时 Enter 只入队 → 工具批次后并入本回合（不打断、不另起回合）")
    cfg = make_config_dir()
    # 慢 mock（每轮 2.5s 延迟，4 轮 ≈ 10s 忙窗口）保证第二条消息提交时仍在执行；
    # 必须在 PtuSession 构造前设置（构造时快照 os.environ）
    os.environ["CJH_MOCK_DELAY_MS"] = "2500"
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("任务一\n")
        time.sleep(1.2)  # 等进入执行态（Thinking/Streaming）
        # 执行中提交第二条：只入队、不打断当前回合
        s.send("任务二\n")
        s.expect("排队 1 条待发送", timeout=15)
        check("忙时入队显示排队提示（状态行）", True)
        # 第一回合作答完毕（4 轮工具链 + 最终答复）
        s.expect("FINAL-DONE", timeout=45)
        buf = strip_ansi(s.buf)
        check("忙时 Enter 不打断当前回合（无'已中断'）", "已中断" not in buf, f"(buf尾部: {buf[-300:]})")
        # 回合内并入走的是带框架抬头的 System Notice，不是旧 steer 的裸注入
        check("回合内不出现旧 steer 注入标记（无'收到排队输入'）", "收到排队输入" not in buf,
              f"(buf尾部: {buf[-300:]})")
        # 方案 2 关键判据：整轮只应有一次作答——旧语义（回合结束再作新回合）会
        # 打印第二次 FINAL-DONE + 第二条回合总结条。留出充足窗口再数一遍。
        time.sleep(6.0)
        buf2 = strip_ansi(s.buf)
        # 计数以「回合总结条」为准：差分渲染在输出区滚动时会把已有行原样重画，
        # 纯文本流里 FINAL-DONE 因此可能被计成 2 次（基线实测 8 次里 3 次踩到，
        # 而同一次运行里总结条恒为 1——是同一行被重画，不是第二个回合）。
        # 第二个回合必然多写一条 "✓ N rounds · …" 总结条，用它判「是否另起回合」
        # 既准确又不受重绘影响。
        summaries = buf2.count("rounds · ")
        check("排队消息并入本回合、不另起新回合（回合总结条只一条）",
              summaries == 1 and "FINAL-DONE" in buf2,
              f"(FINAL-DONE {buf2.count('FINAL-DONE')} 次 / 总结条 {summaries} 次)")
        check("不产生第二回合总结条（无 '1 round'）", "1 round" not in buf2,
              f"(buf尾部: {buf2[-300:]})")
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_esc_interrupt_sends_queue() -> None:
    """[场景11] Esc 中断并立即发送：忙时入队后按 Esc → 中断当前回合（已中断提示）。
    中断优先于边界注入（SteerPolicy.shouldInject），消息留在队列、在 run 结束后
    作为新 turn 自动发送（第二回合作答完成即 FINAL-DONE）。"""
    print("[场景11] Esc 忙时中断 → 排队消息作为新 turn 立即发送")
    cfg = make_config_dir()
    os.environ["CJH_MOCK_DELAY_MS"] = "2500"
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("任务一\n")
        time.sleep(1.2)  # 进入执行态
        # 忙时 Enter：只入队不打断
        s.send("任务二\n")
        s.expect("排队 1 条待发送", timeout=15)
        # 裸 Esc：中断当前回合（不退出 TUI）
        s.send_esc_seq("\x1b")
        s.expect("已中断", timeout=30)
        check("Esc 中断当前回合（已中断提示）", True)
        # 排队消息在 run 结束后作为新 turn 自动发送（首回合被中断，故
        # FINAL-DONE 只可能来自这个新回合）
        s.expect("FINAL-DONE", timeout=45)
        check("排队消息中断后作为新 turn 发送", True)
        buf = strip_ansi(s.buf)
        check("中断路径同样不在回合内注入", "收到排队输入" not in buf, f"(buf尾部: {buf[-300:]})")
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_alt_enter_immediate_send() -> None:
    """[场景12] 忙时 Alt+Enter：入队到队首并中断当前回合，随后立即作为新 turn 发送。
    验证真实终端的 ESC+CR 序列不会被当成裸 Esc 丢掉输入。"""
    print("[场景11b] Alt+Enter 忙时立即发送 → 队首 + 中断 + 新 turn 发送")
    cfg = make_config_dir()
    os.environ["CJH_MOCK_DELAY_MS"] = "2500"
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("任务一\n")
        time.sleep(1.2)  # 进入执行态
        s.send("立即任务")
        time.sleep(0.2)
        s.send_esc_seq("\x1b\r")  # Alt+Enter
        s.expect("已排到队首", timeout=15)
        check("Alt+Enter 入队到队首并提示立即发送", True)
        s.expect("已中断", timeout=30)
        buf = strip_ansi(s.buf)
        check("Alt+Enter 不把 ESC+CR 当裸 Esc 丢输入", "立即任务" in buf, f"(buf尾部: {buf[-300:]})")
        s.expect("FINAL-DONE", timeout=60)
        check("立即任务在中断后作为新 turn 执行", True)
        s.send_key(3)
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_ctrl_n_new_task_deferral() -> None:
    """[场景11c] Ctrl+N：下一条消息作为新任务排队，不并入当前回合；当前回合结束后
    再作为新 turn 发送（出现第二条回合总结条，且无"已中断"）。"""
    print("[场景11c] Ctrl+N 新任务排队 → 当前回合结束后另起 turn")
    cfg = make_config_dir()
    os.environ["CJH_MOCK_DELAY_MS"] = "2500"
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("任务一\n")
        time.sleep(1.2)  # 进入执行态
        s.send_key(14)    # Ctrl+N
        time.sleep(0.2)
        s.send("新任务\n")
        s.expect("已作为新任务排队", timeout=15)
        check("Ctrl+N 标记后入队提示为「新任务」", True)
        s.expect_count("rounds · ", 2, timeout=90)
        buf = strip_ansi(s.buf)
        check("新任务不并入当前回合（无中断）", "已中断" not in buf, f"(buf尾部: {buf[-300:]})")
        check("新任务另起 turn（两条回合总结条）", True)
        s.send_key(3)
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_interrupt_releases_busy() -> None:
    """[场景12] Ctrl+C 中断：忙碌中中断 → 回合明确结束（已中断提示）+ 执行锁释放
    （不再"已请求中断…正在停止"挂死、新消息不再排队）。"""
    print("[场景12] Ctrl+C 中断释放执行锁 → 后续消息直接执行")
    cfg = make_config_dir()
    os.environ["CJH_MOCK_DELAY_MS"] = "3000"  # 慢 mock：每轮 3s，制造忙碌窗口
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        s.send("慢任务\n")
        time.sleep(1.5)          # 进入执行态（mock 延迟中）
        s.send_key(3)            # Ctrl+C：忙时中断（不退出）
        s.expect("已中断", timeout=15)  # 回合明确结束（loop.cj 流中中断标记）
        check("中断后回合明确结束（已中断提示）", True)
        s.read_available(0.5)
        # 执行锁已释放：新消息直接执行（不入队）
        s.send("快查\n")
        s.expect("FINAL-DONE", timeout=60)
        buf = strip_ansi(s.buf)
        check("中断释放执行锁（新消息未排队）", "排队" not in buf, f"(buf尾部: {buf[-300:]})")
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_history_and_paste_multiline() -> None:
    """[场景13] 输入历史（↑↓ 切换上次输入）+ 粘贴双路径（v1.3.20）

    粘贴行为分两路（阈值对齐 atomcode：≥5 行或 ≥400 码点才折叠）：
    - ≥5 行粘贴 → 折叠为 [Paste #N, +X lines] marker（原子 token，原文不进输入框），
      Enter 展开原文提交
    - <5 行且 <400 码点粘贴（含单行长文本）→ 原文进输入框，按屏宽自动软换行多行显示
      （最多 5 行视口跟随光标），Enter 整体提交
    """
    print("[场景13] 输入历史 ↑↓ + 粘贴折叠/软换行")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)
        # 提交两条消息
        s.send("历史消息一\n")
        s.expect("历史消息一")
        time.sleep(0.3)
        s.send("历史消息二\n")
        s.expect("历史消息二")
        time.sleep(0.5)
        # ↑ 恢复上一条（最新）——PTY 下 ESC 序列偶发拆包，单测已完整覆盖 ↑↑↓↓，
        # 这里只做冒烟验证 ↑ 恢复 + 粘贴双路径真实生效
        s.send_esc_seq("\x1b[A")
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        check("↑ 恢复上一条历史", "历史消息二" in buf[-200:], f"(buf尾部: {buf[-200:]})")
        # 短粘贴（单行 0 换行、350 码点 < 400 → 不折叠）：原文进输入框，软换行多行显示
        big = "长内容" * 88  # 352 码点（704 字节，> 单行屏宽，必触发软换行；< 400 码点不折叠）
        s.send("\x1b[200~" + big + "\x1b[201~")
        s.expect("长内容长内容", timeout=15)  # 等粘贴内容渲染进输入框
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        tail = buf[-400:]
        check("短粘贴不折叠（无 marker）", "[Paste #" not in tail, f"(buf尾部: {tail})")
        # 多行软换行：粘贴区出现多行"长内容"重复（软换行后的后续显示行）
        check("短粘贴软换行多行显示", tail.count("长内容") >= 4, f"(buf尾部: {tail})")
        # 粘贴不自动提交：输入框仍显示粘贴内容（提交后会被清空）
        s.read_available(0.6)
        buf = strip_ansi(s.buf)
        check("粘贴后不自动发送（等 Enter）", "长内容" in buf[-400:], f"(buf尾部: {buf[-400:]})")
        # 提交：Enter 整体提交（回显出现"长内容"）
        s.send("\r")
        s.expect("长内容", timeout=15)
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        check("Enter 整体提交长文本", "长内容" in buf[-600:], f"(buf尾部: {buf[-600:]})")
        # 长粘贴（5 行 ≥5 → 折叠 [Paste #N, +X lines]，原文不进输入框）
        s.send("\x1b[200~段落一\n段落二\n段落三\n段落四\n段落五\n\x1b[201~")
        s.expect("[Paste #", timeout=15)  # 等 marker 渲染进输入框
        s.read_available(0.6)
        buf = strip_ansi(s.buf)
        tail = buf[-300:]
        check("长粘贴折叠为 marker", "[Paste #" in tail and "lines]" in tail, f"(buf尾部: {tail})")
        check("折叠后原文不进输入框", "段落二" not in tail, f"(buf尾部: {tail})")
        # 提交：Enter 展开原文提交（回显出现原文各行）
        s.send("\r")
        s.expect("段落一", timeout=15)
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        check("Enter 展开原文提交", "段落二" in buf[-800:] and "段落五" in buf[-900:], f"(buf尾部: {buf[-600:]})")
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_bracketed_paste_chinese() -> None:
    """[场景14] bracketed paste 中文进输入框（回归：逐字节 Rune 拼接导致
    中文 UTF-8 字节被当 Latin-1 码点，"好"=E5 A5 BD → "å¥½" 乱码）。"""
    print("[场景14] bracketed paste 中文/emoji 进输入框不乱码")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.0)  # 等主循环就绪（PTY 下字符可能丢在初始化窗口）
        payload = "粘贴测试🚀ok"
        s.send("\x1b[200~" + payload + "\x1b[201~")
        s.read_available(1.0)
        buf = strip_ansi(s.buf)
        tail = buf[-300:]
        check("中文粘贴正确进输入框", payload in tail, f"(buf尾部: {tail})")
        check("无 Latin-1 乱码（å 等）", "å" not in tail, f"(buf尾部: {tail})")
        # 粘贴不自动提交：输入框保留内容（提交后会被清空）
        s.read_available(0.6)
        buf = strip_ansi(s.buf)
        check("粘贴后不自动发送（等 Enter）", payload in buf[-300:], f"(buf尾部: {buf[-200:]})")
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        s.close()


def test_thinking_history_expand() -> None:
    print("[场景15] 思考历史：Ctrl+T 展开 + Ctrl+U 回看思考开头（交织锚点）")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        s.send("测试任务\n")
        s.expect("FINAL-DONE")
        # 折叠态：1 行摘要，正文不可见（正文仅在展开/滚动后才绘制）。
        # 注：多轮轮次标题由单测覆盖（thinking_log_test / thinking_history_test /
        # TuiAppReasoningHistoryTest）——mock 的工具轮之间没有 content，多轮推理会
        # 合并成同一轮思考，故此处锁端到端链路而非轮数。
        s.expect("思考过程 · Ctrl+T 查看")
        check("折叠态显示思考摘要", True)
        check("折叠态不显示思考正文", "分析用户任务" not in strip_ansi(s.buf))

        def scroll_up_until(text: str, max_press: int) -> bool:
            """Ctrl+U 上滚直至 text 可见。必须由 expect 驱动读取（sleep 后直读 buf 会漏读）。"""
            for _ in range(max_press):
                try:
                    s.expect(text, timeout=0.5)
                    return True
                except TimeoutError:
                    s.send_key(21)   # Ctrl+U = 上滚 8 行
            return False

        # Ctrl+T 展开：交织布局下思考钉在本轮起点（消息流上方，自己那条回复之前），
        # 视口仍锚在会话底部，故需上滚回看正文——思考不再贴底（本次语义修订）。
        s.send_key(20)   # Ctrl+T
        check("Ctrl+T 展开 + 上滚可见思考正文", scroll_up_until("测试驱动", 12))
        # 继续上滚回看：思考开头（最早增量）可见——旧实现按 8192 截尾只留尾部、
        # 且新一轮清空上一轮，开头无从回看
        check("Ctrl+U 回看思考开头", scroll_up_until("分析用户任务", 12))
        # 折叠回摘要 + Ctrl+C 干净退出
        s.send_key(20)
        s.send_key(3)
        code = s.wait_exit()
        check("思考展开后干净退出", code == 0, f"(exit={code})")
    finally:
        s.close()


def test_ref_panel_gate() -> None:
    print("[场景16] /ref 面板：联网闸门 + 未知子命令用法")
    cfg = make_config_dir()
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        # `/ref update` 不带 --yes：只打印计划，绝不联网。
        # 自动化测试永远不跑 `/ref update --yes` 那条路（那条会真的 git clone）。
        s.send("/ref update\n")
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        check("/ref update 走联网闸门（只打印计划）", "唯一会联网的操作" in buf, f"(buf 尾部: {buf[-160:]})")
        check("计划里给出语料目录", "cangjie-ref" in buf, f"(buf 尾部: {buf[-160:]})")
        check("计划里给出确认方式", "--yes" in buf, f"(buf 尾部: {buf[-160:]})")
        # 未知子命令回到 CLI 用法（纯本地，不碰语料、不联网）
        s.send("/ref zzz\n")
        s.read_available(0.8)
        buf2 = strip_ansi(s.buf)
        check("/ref 未知子命令回退到用法", "未知子命令" in buf2, f"(buf 尾部: {buf2[-160:]})")
        check("用法里列出 search 子命令", "search" in buf2, f"(buf 尾部: {buf2[-160:]})")
        s.send_key(3)
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
    finally:
        s.close()


def test_history_recall_no_slash_menu() -> None:
    """[场景17] 历史回吸不重开 / 命令菜单（回归："按上下键出来个 / 杠内容 + 选择项"）

    真实复现：用户 history 文件里躺着旧版本存下的裸 "/"（本机那份末尾就有两条），
    按 ↑ 只想翻上一条输入，结果输入框变成 "/"、命令候选整屏弹出，随后的 ↑↓ 还被
    抢去做选项导航。修复后：载入即剔除裸 "/"，且回吸只换文本、不触发候选刷新。
    """
    print("[场景17] 历史回吸不重开 / 命令菜单")
    cfg = make_config_dir()
    # 预置历史（旧在前），照抄用户那份文件的真实形态：末尾躺着裸 "/"（旧版本存的）
    with open(os.path.join(cfg, "history"), "w", encoding="utf-8") as f:
        f.write("/theme\n/\n历史输入一\n")
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        time.sleep(1.2)
        s.send_esc_seq("\x1b[A")  # ↑：回吸最新一条
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        tail = buf[-400:]
        check("↑ 回吸到正常输入（裸 / 不插队）", "历史输入一" in tail, f"(buf尾部: {tail})")
        check("不再弹出整屏命令候选", "/model" not in tail and "/provider" not in tail,
              f"(buf尾部: {tail})")
        # 继续 ↑ 翻到更早的真命令：回吸只换文本，不触发候选刷新
        s.send_esc_seq("\x1b[A")
        s.read_available(0.8)
        buf = strip_ansi(s.buf)
        tail = buf[-400:]
        check("继续 ↑ 翻到更早的真命令", "/theme" in tail, f"(buf尾部: {tail})")
        s.send_key(3)  # 空闲：一次退出
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
    finally:
        s.close()


def test_skills_over_budget_visible() -> None:
    print("[场景] /skills 显示索引超预算，而不是只显示“启用”")
    cfg = make_config_dir()
    with open(os.path.join(cfg, "settings.json"), encoding="utf-8") as f:
        settings = json.load(f)
    settings["prompt_skills_max_bytes"] = 60
    with open(os.path.join(cfg, "settings.json"), "w", encoding="utf-8") as f:
        json.dump(settings, f)
    skills_dir = os.path.join(cfg, "skills")
    os.makedirs(skills_dir)
    with open(os.path.join(skills_dir, "big-skill.md"), "w", encoding="utf-8") as f:
        f.write("---\nname: big-skill\ndescription: " + "d" * 200 + "\n---\nBIG-BODY")
    with open(os.path.join(skills_dir, "small-skill.md"), "w", encoding="utf-8") as f:
        f.write("---\nname: small-skill\ndescription: S\n---\nSMALL-BODY")
    s = PtuSession(cfg)
    try:
        s.expect("cjh")
        s.send("/skills\n")
        s.expect("索引超预算（未注入）")
        s.expect("仍可 skill_load")
        s.expect("small-skill")
        check("超预算技能可见且说明可按需加载", True)
        s.send_key(3)
        code = s.wait_exit()
        check("退出码 0", code == 0, f"(实际 {code})")
    finally:
        s.close()


def main() -> None:
    if not os.path.exists(BIN):
        print(f"错误：未找到 {BIN}，请先 cjpm build")
        sys.exit(2)
    global PASS, FAIL
    print(f"cjh TUI PTY 集成测试（{BIN}）\n")
    test_startup_and_input()
    test_status_cache_and_round()
    test_slash_completion()
    test_fullwidth_slash_dispatch()
    test_busy_slash_command_dispatch()
    test_help_view()
    test_approval_yes()
    test_approval_queue()
    test_agents_panel_focus()
    test_approval_no()
    test_approval_danger_denied_switches_safe()
    test_provider_dialog()
    test_provider_dialog_aggregator()
    test_provider_dialog_protocol()
    test_provider_paste()
    test_queue_and_autodequeue()
    test_esc_interrupt_sends_queue()
    test_alt_enter_immediate_send()
    test_ctrl_n_new_task_deferral()
    test_interrupt_releases_busy()
    test_history_and_paste_multiline()
    test_bracketed_paste_chinese()
    test_thinking_history_expand()
    test_ref_panel_gate()
    test_history_recall_no_slash_menu()
    test_skills_over_budget_visible()
    print(f"\n结果：{PASS} 通过 / {FAIL} 失败")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
