#!/usr/bin/env bash
#
# cjh 一键安装脚本（Linux / Windows-GitBash）
#
# 用法：
#   curl -fsSL <release 里的 install.sh 下载地址> | bash
#   或仓库内执行：CJH_PREFIX=~/.local/bin bash scripts/install.sh
#
# 环境变量：
#   CJH_PREFIX  安装目录（默认 ~/.local/bin）
#   CJH_VERSION 指定版本（默认取最新 release）
#
set -euo pipefail

REPO_API="https://api.atomgit.com/api/v5/repos/qq8864/cjh"
PREFIX="${CJH_PREFIX:-$HOME/.local/bin}"

say() { printf '\033[1;36m[cjh]\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m[cjh]\033[0m %s\n' "$1" >&2; exit 1; }

command -v curl > /dev/null || die "curl 未安装，请先安装 curl"
command -v tar > /dev/null || die "tar 未安装"

# ---- 平台检测（目前发布 linux x86_64 / windows x86_64）----
case "$(uname -s)" in
    Linux*)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    Darwin*) die "macOS 构建暂未发布（欢迎提 issue 催更）；可自行源码编译，见 README" ;;
    *) die "不支持的平台：$(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "暂只发布 x86_64 构建（当前 $(uname -m)）" ;;
esac

# ---- 取最新版本号（可 CJH_VERSION 覆盖）----
if [ -z "${CJH_VERSION:-}" ]; then
    say "查询最新版本…"
    CJH_VERSION=$(curl -fsSL "$REPO_API/releases/latest" \
        | grep -oE '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$CJH_VERSION" ] || die "无法获取最新版本号（网络问题？）可手动指定：CJH_VERSION=v1.6.4"
fi
say "安装 $CJH_VERSION → $PREFIX"

BASE="$REPO_API/releases/$CJH_VERSION/attach_files"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- 下载 + 安装 ----
mkdir -p "$PREFIX"
if [ "$OS" = "linux" ]; then
    FILE="cjh-$CJH_VERSION-linux-x64.tar.gz"
    say "下载 $FILE …"
    curl -fsSL "$BASE/$FILE/download" | tar -xz -C "$TMP"
    mv "$TMP/cjh-linux-x64" "$PREFIX/cjh"
    chmod +x "$PREFIX/cjh"
else
    FILE="cjh-$CJH_VERSION-windows-x64-selfcontained.zip"
    say "下载 $FILE …"
    curl -fsSL -o "$TMP/cjh.zip" "$BASE/$FILE/download"
    unzip -o -q "$TMP/cjh.zip" -d "$TMP/unzipped"
    exe="$(ls "$TMP/unzipped/"*.exe 2>/dev/null | head -1)"
    [ -n "$exe" ] || die "安装包内未找到 exe"
    mv "$exe" "$PREFIX/cjh.exe"
    # 自包含版的 4 枚 DLL 一并带入
    cp "$TMP/unzipped/"*.dll "$PREFIX/" 2>/dev/null || true
fi

# ---- 校验 ----
say "校验安装…"
if ! "$PREFIX/cjh" --version; then
    die "安装产物校验失败"
fi

case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) say "注意：$PREFIX 不在 PATH 里——请把它加进 PATH（如写入 ~/.bashrc）" ;;
esac
say "完成！试试：cjh --mock"
