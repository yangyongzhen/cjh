#!/usr/bin/env bash
# 库包单元测试（libs/<lib> 是各自独立的包，根 ./scripts/test.sh 不覆盖）
#
# 背景：根包 `cjpm test` 只跑 cjh.tests；libs/ 下每个库是独立包，必须
# `cd libs/<lib> && cjpm test`。历史上 libs/cjcfg 的 capability_test 因语义
# 变更未同步而红了数周无人发现（门禁盲区），本脚本把"库包测试"收敛成一条
# 命令并在末尾汇总，便于并入交付检查清单。
#
# 用法：./scripts/test_libs.sh            # 全部库
#       ./scripts/test_libs.sh cjcfg      # 只跑指定库（可多个）
set -e
cd "$(dirname "$0")/.."

if ! command -v cjpm >/dev/null 2>&1; then
    echo "[test_libs.sh] 找不到 cjpm：先 source /opt/cangjie/cangjie/envsetup.sh" >&2
    exit 127
fi

# 选定库：显式传参，或自动发现 libs/*/cjpm.toml
LIBS=""
if [ $# -gt 0 ]; then
    LIBS="$*"
else
    for d in libs/*/; do
        [ -f "${d}cjpm.toml" ] && LIBS="$LIBS $(basename "$d")"
    done
fi

FAILED_LIBS=""
ROWS=""
TOTAL_ALL=0
PASSED_ALL=0
FAILED_ALL=0

for lib in $LIBS; do
    if [ ! -f "libs/$lib/cjpm.toml" ]; then
        echo "[test_libs.sh] 跳过 $lib：libs/$lib/cjpm.toml 不存在" >&2
        continue
    fi
    echo "[test_libs.sh] === libs/$lib ==="
    log="/tmp/cjh_testlib_${lib}.log"
    rc=0
    if ( cd "libs/$lib" && cjpm test ) >"$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    # 输出带 ANSI 色码，先剥色再取数
    clean=$(sed 's/\x1b\[[0-9;]*m//g' "$log")
    t=$(echo "$clean" | grep -oE 'TOTAL: [0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
    p=$(echo "$clean" | grep -oE 'PASSED: [0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
    f=$(echo "$clean" | grep -oE 'FAILED: [0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
    [ -z "$t" ] && t="-"
    [ -z "$p" ] && p="-"
    [ -z "$f" ] && f="-"

    if [ "$rc" -ne 0 ]; then
        FAILED_LIBS="$FAILED_LIBS $lib"
        echo "[test_libs.sh] $lib 失败（rc=$rc），日志：$log" >&2
        # 把失败用例行直接抛出来，省去翻日志
        echo "$clean" | grep -E 'FAILED ] CASE|Assert' | head -10 >&2 || true
    fi
    if [ "$t" != "-" ]; then TOTAL_ALL=$((TOTAL_ALL + t)); fi
    if [ "$p" != "-" ]; then PASSED_ALL=$((PASSED_ALL + p)); fi
    if [ "$f" != "-" ]; then FAILED_ALL=$((FAILED_ALL + f)); fi
    ROWS="$ROWS
$(printf '%-10s %6s %8s %7s %4s' "$lib" "$t" "$p" "$f" "$rc")"
done

echo
echo "── 库包测试汇总 ──"
printf '%-10s %6s %8s %7s %4s\n' "lib" "TOTAL" "PASSED" "FAILED" "rc"
echo "$ROWS" | sed '/^$/d'
printf '%-10s %6s %8s %7s %4s\n' "合计" "$TOTAL_ALL" "$PASSED_ALL" "$FAILED_ALL" "-"
echo

if [ -n "$FAILED_LIBS" ]; then
    echo "[test_libs.sh] 失败库包：$FAILED_LIBS" >&2
    exit 1
fi
echo "[test_libs.sh] 全部库包测试通过"
