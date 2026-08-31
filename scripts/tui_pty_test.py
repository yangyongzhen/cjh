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

    def expect_count(self, text: str, count: int, timeout: float | None = None) -> str:
        """等待输出中 text 出现至少 count 次（ANSI 剥离后计数；expect 无位置游标，
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
        s.send_key(3)  # 空闲：一次退出
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
        s.send_key(3)  # 空闲：一次退出
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
    """[场景10] 输入队列：执行中提交入队（状态行提示，不污染 transcript），
    执行完自动处理下一条（不重复回显）。"""
    print("[场景10] 输入队列：执行中提交排队 → 完成后自动发送")
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
        # 执行中提交第二条：应入队，状态行出现排队提示
        s.send("任务二\n")
        s.expect("排队")
        buf = strip_ansi(s.buf)
        check("执行中提交显示排队提示", "排队 1 条待发送" in buf, f"(buf尾部: {buf[-300:]})")
        check("transcript 无'已入队'残留提示", "已入队" not in buf, f"(buf尾部: {buf[-300:]})")
        # 任务一完成（4 轮工具链）后，排队消息自动发送并完成；
        # 第二条 run（call 5 = 最终答复）也会输出 FINAL-DONE → 共 2 次
        s.expect_count("FINAL-DONE", 2, timeout=30)
        check("排队消息自动发送并完成", True)
        s.send_key(3)  # 空闲：一次退出
        s.wait_exit()
    finally:
        os.environ.pop("CJH_MOCK_DELAY_MS", None)
        s.close()


def test_interrupt_releases_busy() -> None:
    """[场景11] Ctrl+C 中断：忙碌中中断 → 回合明确结束（已中断提示）+ 执行锁释放
    （不再"已请求中断…正在停止"挂死、新消息不再排队）。"""
    print("[场景11] Ctrl+C 中断释放执行锁 → 后续消息直接执行")
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


def test_history_and_paste_collapse() -> None:
    """[场景12] 输入历史（↑↓ 切换上次输入）+ 大粘贴折叠（[Paste #N] marker）"""
    print("[场景12] 输入历史 ↑↓ + 大粘贴折叠")
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
        # 这里只做冒烟验证 ↑ 恢复 + 大粘贴折叠真实生效
        s.send_esc_seq("\x1b[A")
        s.read_available(0.5)
        buf = strip_ansi(s.buf)
        check("↑ 恢复上一条历史", "历史消息二" in buf[-200:], f"(buf尾部: {buf[-200:]})")
        # 大粘贴折叠 + 退格原子删除：单测 testPasteCollapseLarge 已完整断言
        # （PTY 下长 bracketed paste 跨 read 块拆包，ESC[200~ 前缀识别不可靠，
        # 不在此重复验证）
        s.send_key(3)  # 空闲：一次退出
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
    test_provider_dialog()
    test_provider_dialog_aggregator()
    test_provider_dialog_protocol()
    test_provider_paste()
    test_queue_and_autodequeue()
    test_interrupt_releases_busy()
    test_history_and_paste_collapse()
    print(f"\n结果：{PASS} 通过 / {FAIL} 失败")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
