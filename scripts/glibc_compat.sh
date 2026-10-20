#!/usr/bin/env bash
# Linux 产物 glibc 兼容构建（注入自实现 fmod/fmodf，抹掉 GLIBC_2.38 依赖）
#
# 问题：在 glibc ≥2.38 的机器上构建时，仓颉标准库 math 的两个符号 fmod / fmodf
# 会被打上 GLIBC_2.38 版本标记；产物拿到 Ubuntu 22.04（glibc 2.35）/ Debian 12（2.36）
# 上，动态加载器直接报 "version `GLIBC_2.38' not found"，进程进不了 main。
#
# 做法：把 native/fmod_compat.c 编译成 .o 注入链接行（可执行文件自带定义，不再从
# libm 导入这两个符号），最低 glibc 需求回落到 GLIBC_2.34。
# 与 scripts/winbuild.sh 同一套手法：临时改 cjpm.toml 的 link-option，退出时无条件还原。
#
# 用法：
#   source /opt/cangjie/cangjie-1.0.5/envsetup.sh
#   ./scripts/glibc_compat.sh            # 构建（产物在 target/release/bin/cjh）
#   ./scripts/glibc_compat.sh --check    # 只检查现有产物的 glibc 需求

set -euo pipefail
cd "$(dirname "$0")/.."

BIN="target/release/bin/cjh"
SHIM_SRC="native/fmod_compat.c"
OBJ_DIR="target/glibc_compat"

# 打印产物要求的最高 glibc 版本；带 --check 时匹配到 2.38 及以上返回 1
max_glibc() {
    objdump -T "$1" 2>/dev/null \
        | grep -o 'GLIBC_[0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?' \
        | sed 's/GLIBC_//' | sort -uV | tail -1
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f "$BIN" ]; then
        echo "✗ 产物不存在：$BIN（先跑一次构建）"
        exit 1
    fi
    need="$(max_glibc "$BIN")"
    echo "产物最高 glibc 需求：GLIBC_${need}"
    case "$need" in
        2.38|2.39|2.40|2.41|2.42|2.5*) echo "✗ 仍高于 GLIBC_2.34（Ubuntu 22.04 无法运行）"; exit 1 ;;
        *) echo "✓ 兼容 glibc ≤2.35（Ubuntu 22.04 / Debian 12 可运行）"; exit 0 ;;
    esac
fi

if ! command -v gcc > /dev/null 2>&1; then
    echo "✗ 找不到 gcc（编译 native/fmod_compat.c 需要）"
    exit 1
fi
if ! command -v cjpm > /dev/null 2>&1; then
    echo "✗ 找不到 cjpm，先 source 仓颉环境：source /opt/cangjie/cangjie-1.0.5/envsetup.sh"
    exit 1
fi

mkdir -p "$OBJ_DIR"
echo "→ 编译 glibc 兼容 shim：$SHIM_SRC"
gcc -O2 -fno-builtin -fPIC -c "$SHIM_SRC" -o "$OBJ_DIR/fmod_compat.o"

# 备份并临时注入：link-option 里加一条 .o 绝对路径
BACKUP="$(mktemp /tmp/cjh_cjpm_toml.XXXXXX)"
cp cjpm.toml "$BACKUP"
restore() {
    cp "$BACKUP" cjpm.toml
    rm -f "$BACKUP"
}
trap restore EXIT INT TERM

OBJ_ABS="$(cd "$OBJ_DIR" && pwd)/fmod_compat.o"
sed -i "s|link-option = \"|link-option = \"${OBJ_ABS} |" cjpm.toml

echo "→ 构建（已注入 $OBJ_ABS）"
rm -f "$BIN"
cjpm build

# 还原 cjpm.toml（trap 也会兜底，这里显式做一次让 --check 前的状态干净）
restore
trap - EXIT INT TERM

if [ ! -f "$BIN" ]; then
    echo "✗ 构建产物缺失：$BIN"
    exit 1
fi
need="$(max_glibc "$BIN")"
echo "→ 产物最高 glibc 需求：GLIBC_${need}"
if objdump -T "$BIN" | grep -q 'GLIBC_2\.3[89]\|GLIBC_2\.4'; then
    echo "✗ 仍残留高版本符号："
    objdump -T "$BIN" | grep 'GLIBC_2\.3[89]\|GLIBC_2\.4' | head
    exit 1
fi
echo "✓ 已消除 GLIBC_2.38 依赖，产物兼容 glibc ≤2.35（Ubuntu 22.04 / Debian 12）"
