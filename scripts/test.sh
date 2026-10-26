#!/usr/bin/env bash
# 单元测试（自动切换动态链接配置）
#
# 背景：cjpm.toml 默认静态链接（--static，产物单文件零依赖，可直接分发运行）；
# 但静态链接下 cjpm test 进程会 double free 崩溃（SIGSEGV，仓颉运行时/测试框架
# 组合 bug，发布二进制正常）。本脚本临时切动态配置跑测试，结束后恢复静态。
#
# 用法：./scripts/test.sh [--filter "*Xxx*"]
# 仓库卫生：动态配置由本脚本从静态基线自动派生为 cjpm.toml.dynamic.bak
# （已 gitignore，不入库），版本库只保留 cjpm.toml 静态基线。
set -e
cd "$(dirname "$0")/.."

STATIC_CFG="cjpm.toml"
DYNAMIC_CFG="cjpm.toml.dynamic.bak"
BACKUP="/tmp/cjpm.static.last.toml"

# 动态配置不再作为 .bak 文件入库（仓库卫生：版本库只留 cjpm.toml 静态基线），
# 由本脚本从静态基线自动派生：stdx 路径 static→dynamic + 清空 compile-option。
# 兜底自检：若进来时已是动态配置（上次运行被强杀未还原），直接停。
# 否则接下来「备份 → 覆盖 → 恢复」会把这份脏配置原样备份、再原样写回，
# 跑完看着正常，实际仓库已被污染（v1.3.27 发布提交就是这样带进动态态的）。
if grep -q '^  compile-option = ""' "$STATIC_CFG"; then
    echo "[test.sh] 错误：cjpm.toml 当前是动态配置（上次运行被强杀未还原），拒绝继续。" >&2
    echo "         先恢复静态基线：git show <release-commit>:cjpm.toml > cjpm.toml" >&2
    exit 1
fi

# 每次运行都从当前静态基线重新派生。早先写成「文件不存在才生成」，版本升级后
# .bak 仍停在旧版本（连 version 行都是旧的），中途被打断就会把旧版本号带进工作区。
sed -e 's|/static/stdx|/dynamic/stdx|g' \
    -e 's|^  compile-option = .*|  compile-option = ""|' \
    "$STATIC_CFG" > "$DYNAMIC_CFG"
echo "[test.sh] 已从 cjpm.toml 派生动态配置 $DYNAMIC_CFG（不入库）"

# 派生只允许动链接相关两行：版本号等其它行必须原样，否则说明派生逻辑写歪了
base_ver=$(grep -m1 -E '^[[:space:]]*version[[:space:]]*=' "$STATIC_CFG")
dyn_ver=$(grep -m1 -E '^[[:space:]]*version[[:space:]]*=' "$DYNAMIC_CFG")
if [ "$base_ver" != "$dyn_ver" ]; then
    echo "[test.sh] 错误：派生配置版本行与基线不一致（基线: $base_ver / 派生: $dyn_ver）" >&2
    exit 1
fi

# 切换前备份静态配置；结束（含出错）时恢复
cp "$STATIC_CFG" "$BACKUP"
cp "$DYNAMIC_CFG" "$STATIC_CFG"
restore() {
    cp "$BACKUP" "$STATIC_CFG"
    # 恢复后核对：不一致就喊出来，别让「看起来已恢复」掩盖事实
    diff -q "$BACKUP" "$STATIC_CFG" >/dev/null 2>&1 || \
        echo "[test.sh] 警告：cjpm.toml 恢复后与备份不一致，请核对 $BACKUP" >&2
}
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
