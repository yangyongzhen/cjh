#!/usr/bin/env bash
# 仓颉 SDK 环境配置（tauri_cj 开发环境）
# 用法: source cj-env.sh
export CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
# stdx 动态库（替代 rpath；链接选项已平台无关化）
export CJH_STDX_DIR="${CJH_STDX_DIR:-/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.0.5.1/dynamic/stdx}"
export LD_LIBRARY_PATH="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:$CJH_STDX_DIR:${LD_LIBRARY_PATH:-}"
