#!/usr/bin/env bash
# Windows 交叉构建（自动临时改 link-option + windows stdx path-option）
#
# cjpm.toml 的 root link-option 是 Linux 专属（-rpath，lld/mingw 不认）；
# Windows 构建需临时替换为系统库，并补 windows target 的 stdx 路径，
# 结束自动恢复。
#
# 用法：./scripts/winbuild.sh [--target-dir ...]
set -e
cd "$(dirname "$0")/.."

WINDOWS_STDX="${CJH_WINDOWS_STDX:-/root/.cangjie/stdx/cangjie-stdx-windows-x64-1.0.5.1/windows_x86_64_cjnative/dynamic/stdx}"
if [ ! -d "$WINDOWS_STDX" ]; then
    echo "[winbuild.sh] 缺少 windows stdx: $WINDOWS_STDX"
    echo "  解压 docs/cangjie-stdx-windows-x64-1.0.5.1.zip 到 ~/.cangjie/stdx/cangjie-stdx-windows-x64-1.0.5.1/"
    exit 1
fi

cp cjpm.toml /tmp/cjpm.winbuild.toml
# link-option 换 Windows 系统库（crypt32: x509 证书；ws2_32: 网络）
sed -i 's|^  link-option = .*|  link-option = "-lcrypt32 -lws2_32"|' cjpm.toml
# 追加 windows target 的 stdx 路径（ld.lld 链接 stdx import 库需要）
if ! grep -q "x86_64-pc-windows-gnu.bin-dependencies" cjpm.toml; then
    cat >> cjpm.toml <<EOF

[target.x86_64-pc-windows-gnu.bin-dependencies]
    path-option = ["$WINDOWS_STDX"]
EOF
fi
restore() { cp /tmp/cjpm.winbuild.toml cjpm.toml; }
trap restore EXIT

echo "[winbuild.sh] 交叉构建 Windows（stdx: $WINDOWS_STDX）..."
cjpm build --target x86_64-pc-windows-gnu "$@"
echo "[winbuild.sh] 产物: target/x86_64-pc-windows-gnu/release/bin/main.exe"
