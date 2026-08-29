#!/usr/bin/env bash
# Windows 交叉构建（自动临时改 link-option）
#
# cjpm.toml 的 root link-option 是 Linux 专属（-rpath，lld/mingw 不认）；
# Windows 构建需临时替换为 stdx 静态链接所需的系统库，结束自动恢复。
#
# 用法：./scripts/winbuild.sh [--target-dir ...]
set -e
cd "$(dirname "$0")/.."

cp cjpm.toml /tmp/cjpm.winbuild.toml
# link-option 换 Windows 系统库（crypt32: x509 证书；ws2_32: 网络）
sed -i 's|^  link-option = .*|  link-option = "-lcrypt32 -lws2_32"|' cjpm.toml
restore() { cp /tmp/cjpm.winbuild.toml cjpm.toml; }
trap restore EXIT

echo "[winbuild.sh] 交叉构建 Windows（stdx 静态链接）..."
cjpm build --target x86_64-pc-windows-gnu "$@"
echo "[winbuild.sh] 产物: target/x86_64-pc-windows-gnu/release/bin/main.exe"
