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

# 兜底自检：若进来时已是动态配置（上次运行被强杀未还原），提醒先恢复基线再跑
if grep -q '^  compile-option = ""' "$STATIC_CFG"; then
    echo "[test.sh] 警告：cjpm.toml 当前是动态配置（上次运行可能被强杀未还原）——"
    echo "         请先恢复静态基线再跑：git show <release-commit>:cjpm.toml > cjpm.toml"
fi

# 切换前备份静态配置；结束（含出错）时恢复
cp "$STATIC_CFG" "$BACKUP"
cp "$DYNAMIC_CFG" "$STATIC_CFG"
restore() { cp "$BACKUP" "$STATIC_CFG"; }
# 除 EXIT 外还接 TERM/INT/HUP：被 timeout/中断杀死时同样要还原。只 trap EXIT
# 时，一次被强杀的运行会把动态配置留在仓库里（v1.3.27 发布提交即因此把
# 动态态 + 陈旧 version 带进 git），下面这行是那次事故的根因修复
trap restore EXIT INT TERM HUP

echo "[test.sh] 已切动态配置跑测试（静态下测试框架 double free 崩溃）..."
# 配置隔离：测试进程读隔离配置目录（空），避免读到真实 ~/.cjh 的
# history/draft/settings（TuiApp init 加载真实用户数据会污染测试输入）
export CJH_CONFIG_DIR="${CJH_CONFIG_DIR:-$(mktemp -d /tmp/cjh_test_cfg.XXXXXX)}"
if [ $# -gt 0 ]; then
    cjpm test "$@"
else
    cjpm test
fi
