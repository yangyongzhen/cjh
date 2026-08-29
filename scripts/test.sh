#!/usr/bin/env bash
# 单元测试（自动切换动态链接配置）
#
# 背景：cjpm.toml 默认静态链接（--static，产物单文件零依赖，可直接分发运行）；
# 但静态链接下 cjpm test 进程会 double free 崩溃（SIGSEGV，仓颉运行时/测试框架
# 组合 bug，发布二进制正常）。本脚本临时切动态配置跑测试，结束后恢复静态。
#
# 用法：./scripts/test.sh [--filter "*Xxx*"]
set -e
cd "$(dirname "$0")/.."

STATIC_CFG="cjpm.toml"
DYNAMIC_CFG="cjpm.toml.dynamic.bak"
BACKUP="/tmp/cjpm.static.last.toml"

if [ ! -f "$DYNAMIC_CFG" ]; then
    echo "[test.sh] 缺少动态配置备份 $DYNAMIC_CFG，先导出："
    echo "  从 cjpm.toml 手动改：stdx 路径 dynamic/ + compile-option 清空，另存为 $DYNAMIC_CFG"
    exit 1
fi

# 切换前备份静态配置；结束（含出错）时恢复
cp "$STATIC_CFG" "$BACKUP"
cp "$DYNAMIC_CFG" "$STATIC_CFG"
restore() { cp "$BACKUP" "$STATIC_CFG"; }
trap restore EXIT

echo "[test.sh] 已切动态配置跑测试（静态下测试框架 double free 崩溃）..."
if [ $# -gt 0 ]; then
    cjpm test "$@"
else
    cjpm test
fi
