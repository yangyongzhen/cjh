#!/usr/bin/env python3
"""把 `cjh --cli`（Mock 模式）的真实会话录制并渲染成 README 用短 GIF。

设计取舍：
  - 不依赖 pyte / asciinema / 终端模拟器：CLI 模式本身就是纯文本流，逐行揭示即可。
  - 画面内容全部来自真实进程输出（含 mock 的工具调用轨迹），只在渲染层做「打字 + 逐行揭示」节奏。
  - 过滤两类无害噪声行（首次运行生成的配置文件提示、session saved 行），其余原样保留。
  - 字体按「ASCII 用等宽、CJK 用中文字体」逐字符绘制，保证中英混排对齐。

用法:
  python3 scripts/gif_record.py                      # 输出 docs/imgs/cjh-demo.gif
  python3 scripts/gif_record.py --out /tmp/x.gif --cols 96 --rows 26 --step 2

依赖: Pillow（PIL）+ 系统字体（DejaVu Sans Mono / 文泉驿微米黑，自动探测）。
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(PROJECT, "target", "release", "bin", "cjh")

DEFAULT_PROMPT = "先读一下 README 开头，再帮我看看项目结构"

# 配色（与官网站点同一套）
BG = (11, 18, 32)
CHROME = (19, 28, 46)
TEXT = (214, 230, 227)
DIM = (100, 116, 139)
TEAL = (15, 191, 174)
AMBER = (247, 185, 85)

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[=>()]")
NOISE_PREFIX = ("[cjh] 已生成配置文件", "❯ [session saved")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def first_existing(paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return None


def find_fonts():
    mono = first_existing([
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    ])
    cjk = first_existing([
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/arphic/uming.ttc",
    ])
    if cjk is None:
        try:
            cjk = subprocess.run(
                ["fc-match", "-f", "%{file}", ":lang=zh"],
                capture_output=True, text=True, timeout=10,
            ).stdout.strip() or None
        except Exception:
            cjk = None
    return mono, cjk


def capture(prompt, timeout):
    """跑一次真实 CLI 会话，返回清理后的文本行。"""
    cfg = tempfile.mkdtemp(prefix="cjh_gif_")
    out = os.path.join(cfg, "session.txt")
    inp = os.path.join(cfg, "input.txt")
    with open(inp, "w", encoding="utf-8") as f:
        f.write(prompt + "\n")
    env = dict(os.environ)
    env.update({
        "CJH_MOCK": "1",
        "CJH_CONFIG_DIR": cfg,
        "CJH_MOCK_REASONING_CHARS": "0",   # 关掉长思考垫片
        "CJH_MOCK_DELAY_MS": "18",         # 让流式输出有节奏
        "TERM": "dumb",
        "NO_COLOR": "1",
    })
    # 注意：必须走 shell 管道。直接用 subprocess 的 stdin 管道时，cjh 读不到输入（已实测）。
    cmd = "cat %s | %s --cli > %s 2>&1" % (shlex.quote(inp), shlex.quote(BIN), shlex.quote(out))
    try:
        subprocess.run(cmd, shell=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    with open(out, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    lines = []
    for line in strip_ansi(raw).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.startswith(NOISE_PREFIX):
            continue
        lines.append(line.rstrip())
    # 折叠工具结果块：每个 "↳" 结果最多保留 3 行，其余压成 "…"（否则会把 /tmp 的目录列表整屏搬进 GIF）
    collapsed, in_result, kept = [], False, 0
    for line in lines:
        s = line.strip()
        if s.startswith("▶") or s.startswith("──"):
            in_result, kept = False, 0
            collapsed.append(line)
            continue
        if s.startswith("↳"):
            in_result, kept = True, 0
            collapsed.append(line)
            continue
        if in_result:
            if kept < 3:
                collapsed.append(line)
                kept += 1
            elif kept == 3:
                collapsed.append("  …")
                kept += 1
            continue
        collapsed.append(line)
    lines = collapsed
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def cell_width(ch):
    """CJK / 全角算 2 格。"""
    return 1 if ord(ch) < 0x2E80 else 2


def wrap(lines, cols):
    out = []
    for line in lines:
        if not line:
            out.append("")
            continue
        cur, w = "", 0
        for ch in line:
            cw = cell_width(ch)
            if w + cw > cols:
                out.append(cur)
                cur, w = "", 0
            cur += ch
            w += cw
        out.append(cur)
    return out


def color_of(line):
    s = line.strip()
    if s.startswith("▶"):
        return AMBER
    if s.startswith("──"):
        return TEAL
    if s.startswith("↳"):
        return DIM
    if s.startswith("[cjh]"):
        return DIM
    return TEXT


class Renderer:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.cw, self.ch = 9, 20
        self.pad = 16
        self.chrome = 34
        self.w = cols * self.cw + self.pad * 2
        self.h = rows * self.ch + self.pad * 2 + self.chrome
        mono_path, cjk_path = find_fonts()
        if mono_path is None:
            raise SystemExit("找不到等宽字体（DejaVu Sans Mono）")
        self.f_mono = ImageFont.truetype(mono_path, 15)
        self.f_cjk = ImageFont.truetype(cjk_path, 14) if cjk_path else self.f_mono
        self.f_title = ImageFont.truetype(mono_path, 12)

    def draw(self, lines, cursor):
        img = Image.new("RGB", (self.w, self.h), BG)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, self.w, self.chrome], fill=CHROME)
        for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = 18 + i * 18
            d.ellipse([cx - 5, self.chrome // 2 - 5, cx + 5, self.chrome // 2 + 5], fill=c)
        d.text((80, self.chrome // 2 - 8), "cjh --cli  (mock)", font=self.f_title, fill=DIM)
        y0 = self.chrome + self.pad
        visible = lines[-self.rows:]
        for row, line in enumerate(visible):
            color = color_of(line)
            x = self.pad
            y = y0 + row * self.ch
            for ch in line:
                cw = cell_width(ch)
                font = self.f_mono if cw == 1 else self.f_cjk
                d.text((x, y), ch, font=font, fill=color)
                x += cw * self.cw
            if cursor and row == len(visible) - 1:
                d.rectangle([x + 1, y + 3, x + self.cw, y + self.ch - 5], fill=TEAL)
        return img


def build_frames(transcript, prompt, cols, step):
    """打字动画 + 逐行揭示，返回 [(行列表, 光标, 停留毫秒)]。"""
    frames = []
    for i in range(0, len(prompt) + 1, 2):
        lines = ["> " + prompt[:i]]
        frames.append((lines, True, 40))
    base = ["> " + prompt, ""] + transcript
    for i in range(0, len(base) + 1, step):
        frames.append((base[:i], False, 95))
    tail = frames[-1][0]
    frames.append((tail, True, 800))
    frames.append((tail, True, 1600))
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(PROJECT, "docs", "imgs", "cjh-demo.gif"))
    ap.add_argument("--cols", type=int, default=96)
    ap.add_argument("--rows", type=int, default=26)
    ap.add_argument("--step", type=int, default=2, help="每帧揭示多少行（越小越细腻、体积越大）")
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--dump", action="store_true", help="只打印捕获到的转录，不出图")
    args = ap.parse_args()

    if not os.path.exists(BIN):
        raise SystemExit("找不到 %s，先跑 cjpm build" % BIN)

    print("[1/3] 录制 CLI 会话（mock）…")
    transcript = capture(args.prompt, args.timeout)
    print("      转录 %d 行" % len(transcript))
    if args.dump:
        for i, line in enumerate(transcript[:60]):
            print("%3d| %s" % (i + 1, line[:150]))
        return 0
    if len(transcript) < 15:
        raise SystemExit("转录过短（%d 行），检查 mock 是否生效" % len(transcript))

    print("[2/3] 渲染帧（%dx%d 格，每条 %d 行一帧）…" % (args.cols, args.rows, args.step))
    renderer = Renderer(args.cols, args.rows)
    frames = build_frames(wrap(transcript, args.cols), args.prompt, args.cols, args.step)
    print("      帧数 %d" % len(frames))
    images = [renderer.draw(lines, cursor) for lines, cursor, _ in frames]
    durations = [ms for _, _, ms in frames]

    print("[3/3] 合成 GIF → %s" % args.out)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    pal = [im.convert("P", palette=Image.ADAPTIVE, colors=96) for im in images]
    pal[0].save(args.out, save_all=True, append_images=pal[1:], duration=durations,
                loop=0, optimize=True, disposal=1)
    size = os.path.getsize(args.out)
    print("完成：%s（%.2f MB，%d 帧）" % (args.out, size / 1048576.0, len(pal)))
    if size > 2.6 * 1048576:
        print("提示：体积偏大，可减小 --cols/--rows 或增大 --step")


if __name__ == "__main__":
    sys.exit(main())
