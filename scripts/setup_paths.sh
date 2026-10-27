#!/usr/bin/env bash
# 自动探测本机 Cangjie SDK 与 stdx 路径，改写仓库内全部 cjpm.toml + cj-env.sh。
#
# 背景：cjpm.toml 不支持环境变量展开，stdx（bin-dependencies path-option）与
# SDK rpath 只能写绝对路径——换机器/换版本必失效。本脚本一次探测、逐文件
# 改写；已提交的路径是"上一台构建机"的值，新机器 clone 后先跑本脚本。
#
# 用法：
#   ./scripts/setup_paths.sh           # 探测 + 改写
#   ./scripts/setup_paths.sh --check   # 只检查是否匹配，不写（CI 用，不匹配 exit 1）
#
# 探测顺序：
#   SDK  ：$CANGJIE_HOME → which cjc 上两级 → /opt/cangjie/cangjie*
#   stdx ：$CJH_STDX_DIR → ~/.cangjie/stdx/cangjie-stdx-linux-x64-<cjc主版本>*
#          （选与 `cjc -v` 版本前缀一致的最新目录）
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# ---- 探测 SDK ----
detect_sdk() {
    if [ -n "${CANGJIE_HOME:-}" ] && [ -x "$CANGJIE_HOME/bin/cjc" ]; then
        echo "$CANGJIE_HOME"; return
    fi
    local cjc_path
    cjc_path=$(command -v cjc 2>/dev/null || true)
    if [ -n "$cjc_path" ]; then
        echo "$(cd "$(dirname "$cjc_path")/.." && pwd)"; return
    fi
    for d in /opt/cangjie/cangjie /opt/cangjie/cangjie-*; do
        [ -x "$d/bin/cjc" ] && { echo "$d"; return; }
    done
    echo ""
}

# ---- 探测 stdx（匹配 SDK 的 cjc 主版本，如 1.2.0 → cangjie-stdx-linux-x64-1.2.0*）----
detect_stdx() {
    if [ -n "${CJH_STDX_DIR:-}" ] && [ -d "$CJH_STDX_DIR" ]; then
        echo "$CJH_STDX_DIR"; return
    fi
    local ver stem best=""
    # 版本从已探测 SDK 的 cjc 取（脚本自身不依赖 PATH/envsetup）
    ver=$("$SDK/bin/cjc" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) \
        || ver=""
    if [ -n "$ver" ]; then
        stem="cangjie-stdx-linux-x64-${ver%.*}"
        for d in "$HOME/.cangjie/stdx/${stem}"*; do
            [ -d "$d" ] && best="$d"   # glob 展开取最后一个（版本后缀最大的）
        done
    fi
    # 兜底：版本匹配不到时取字典序最大的 stdx 目录（多半是最新装的）
    if [ -z "$best" ]; then
        for d in "$HOME/.cangjie/stdx/cangjie-stdx-linux-x64-"*; do
            [ -d "$d" ] && best="$d"
        done
    fi
    echo "$best"
}

SDK=$(detect_sdk)
STDX=$(detect_stdx)

if [ -z "$SDK" ] || [ -z "$STDX" ]; then
    echo "[setup_paths] 探测失败：SDK='${SDK}' stdx='${STDX}'"
    [ -z "$SDK" ]  && echo "  未找到 Cangjie SDK：设 CANGJIE_HOME 或先 source envsetup.sh"
    [ -z "$STDX" ] && echo "  未找到 stdx：设 CJH_STDX_DIR（须含 stdx/ 子目录），或检查 ~/.cangjie/stdx/"
    exit 1
fi
echo "[setup_paths] SDK  = $SDK"
echo "[setup_paths] stdx = $STDX"

# ---- 目标文件与改写 ----
# 兼容两个 stdx 布局代：1.0.5.x（顶层 static|dynamic/stdx）与 1.2.0（static 挪到
# linux_x86_64_cjnative/static/stdx）——统一按"stdx 根目录"替换，尾段保持原样
FILES=(cjpm.toml cj-env.sh libs/*/cjpm.toml libs/*/examples/*/cjpm.toml example/plugins/signed-demo/cjpm.toml)

MISMATCH=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    # 旧值：任意 cangjie-stdx-linux-x64-*/ 与任意 /opt/cangjie/cangjie-*/
    if grep -qE 'cangjie-stdx-linux-x64-[^"/]+|/opt/cangjie/cangjie(-[0-9.]+)?/' "$f" \
       && ! grep -q "$STDX" "$f"; then
        MISMATCH=1
    fi
    if [ "$CHECK" = 1 ]; then continue; fi
    sed -i "s|cangjie-stdx-linux-x64-[0-9.]*|$(basename "$STDX")|g; s|/opt/cangjie/cangjie-[0-9.]*/|$SDK/|g; s|/opt/cangjie/cangjie/|$SDK/|g" "$f"
done

if [ "$CHECK" = 1 ]; then
    if [ "$MISMATCH" = 1 ]; then
        echo "[setup_paths] --check：存在与本机不匹配的路径，先跑 ./scripts/setup_paths.sh"
        exit 1
    fi
    echo "[setup_paths] --check：全部匹配 ✓"
    exit 0
fi
echo "[setup_paths] 已改写 ${#FILES[@]} 个配置文件（cj-env.sh 同步）。重新 cjpm build 前无需 cjpm clean（源码未变）。"
