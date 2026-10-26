#!/usr/bin/env bash
# 校验 dist/ 下的发布产物与当前版本一致。
#
# 为什么需要：裸二进制和归档包是各自刷新的，曾出现「版本号相同的 zip 里装着
# 上一个版本的可执行文件」。这种不一致看版本号发现不了——两边都写着 v1.5.3，
# 只有解压出一个文件、和裸二进制逐字节比对才会露馅。所以本脚本不比版本串，
# 而是比 sha256：归档包里的可执行文件必须与 dist/ 下的裸二进制完全相同。
#
# 用法：./scripts/verify_dist.sh
# 退出码：0 全部一致；1 存在不一致
set -uo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 -E '^[[:space:]]*version[[:space:]]*=' cjpm.toml \
    | sed -E 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"(.*)"/\1/')
TMP=$(mktemp -d /tmp/cjh_verify_dist.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=1; }
# 只取前 12 位做展示，够区分且不刷屏；比对本身用 cmp，不看这个值
sum() { sha256sum "$1" | cut -d' ' -f1 | cut -c1-12; }

echo "版本: $VERSION"
echo

# 1) Linux 裸二进制：唯一能真正执行的一种，直接取版本输出
LINUX_BIN=dist/cjh-linux-x64
if [ -x "$LINUX_BIN" ]; then
    got=$("$LINUX_BIN" --version 2>/dev/null | head -1)
    if [ "$got" = "cjh v$VERSION" ]; then
        pass "dist/cjh-linux-x64 --version → $got"
    else
        fail "dist/cjh-linux-x64 --version → ${got:-（无法执行）}，期望 cjh v$VERSION"
    fi
else
    fail "dist/cjh-linux-x64 不存在或不可执行"
fi

# 2) Linux 归档包：解出的二进制必须与裸二进制逐字节相同
LINUX_TGZ="dist/cjh-v$VERSION-linux-x64.tar.gz"
if [ -f "$LINUX_TGZ" ]; then
    mkdir -p "$TMP/tgz" && tar -xzf "$LINUX_TGZ" -C "$TMP/tgz"
    inner=$(find "$TMP/tgz" -type f -name 'cjh*' | head -1)
    if [ -z "$inner" ]; then
        fail "$LINUX_TGZ 内未找到可执行文件"
    elif cmp -s "$inner" "$LINUX_BIN"; then
        pass "$LINUX_TGZ 内二进制与裸二进制一致（$(sum "$inner")）"
    else
        fail "$LINUX_TGZ 内二进制 != dist/cjh-linux-x64（包内 $(sum "$inner") vs 裸 $(sum "$LINUX_BIN")）"
    fi
else
    fail "缺少 $LINUX_TGZ"
fi

# 3) Windows 两个包：Windows 产物在 Linux 上跑不了，只能比字节
WIN_EXE=dist/cjh-windows-x64.exe
if [ -f "$WIN_EXE" ]; then
    for kind in "" "-selfcontained"; do
        z="dist/cjh-v$VERSION-windows-x64$kind.zip"
        if [ ! -f "$z" ]; then
            fail "缺少 $z"
            continue
        fi
        d="$TMP/zip${kind:-plain}"
        mkdir -p "$d" && unzip -o -q "$z" -d "$d"
        inner=$(find "$d" -type f -name '*.exe' | head -1)
        if [ -z "$inner" ]; then
            fail "$z 内未找到 exe"
        elif cmp -s "$inner" "$WIN_EXE"; then
            pass "$z 内 exe 与裸 exe 一致（$(sum "$inner")）"
        else
            fail "$z 内 exe != dist/cjh-windows-x64.exe（包内 $(sum "$inner") vs 裸 $(sum "$WIN_EXE")）"
        fi
    done
else
    fail "dist/cjh-windows-x64.exe 不存在"
fi

# 4) SHA256SUMS：逐条校验，条目缺文件或内容变了都会失败
if [ -f dist/SHA256SUMS ]; then
    if ( cd dist && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
        pass "dist/SHA256SUMS 全部校验通过"
    else
        fail "dist/SHA256SUMS 校验失败（条目对应文件缺失或内容已变），重打产物后需重新生成"
    fi
else
    fail "缺少 dist/SHA256SUMS"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "结论：产物一致"
else
    echo "结论：存在不一致（见上）—— 重打对应产物后重跑本脚本"
fi
exit "$FAIL"
