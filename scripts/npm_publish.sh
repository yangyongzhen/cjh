#!/usr/bin/env bash
# 把 dist/ 里已构建好的二进制打成 npm 包并发布。
#
#   ./scripts/npm_publish.sh              # 只打包校验（默认，不发布）
#   ./scripts/npm_publish.sh --publish    # 真正发布到 registry.npmjs.org
#
# 发布顺序：平台包 → 主包。主包声明了带精确版本号的 optionalDependencies，
# 平台包必须先存在，否则装主包时会因为解析不到依赖而退化。
set -euo pipefail

REGISTRY=https://registry.npmjs.org
# 开了 2FA 的账号发布必须带一次性密码：交互终端里 npm 会提示输入，
# 但脚本常在非 TTY 环境（CI / agent）下跑，那里没有提示、只会 EOTP 直接失败，
# 故支持显式传入：NPM_OTP=123456 ./scripts/npm_publish.sh --publish
OTP_FLAG=""
if [ -n "${NPM_OTP:-}" ]; then
  OTP_FLAG="--otp=$NPM_OTP"
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MODE=dry-run
case "${1:-}" in
  --publish) MODE=publish ;;
  --dry-run | "") MODE=dry-run ;;
  *)
    echo "用法: $0 [--dry-run|--publish]" >&2
    exit 2
    ;;
esac

# 版本号唯一来源：cjpm.toml
VERSION=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' cjpm.toml | head -1)
if [ -z "$VERSION" ]; then
  echo "无法从 cjpm.toml 读取 version" >&2
  exit 1
fi

LINUX_BIN=dist/cjh-linux-x64
WIN_BIN=dist/cjh-windows-x64.exe
for f in "$LINUX_BIN" "$WIN_BIN"; do
  if [ ! -f "$f" ]; then
    echo "缺少产物: $f —— 先跑打包流程（winbuild.sh + 拷贝二进制）再执行本脚本" >&2
    exit 1
  fi
done

echo "版本: $VERSION"
echo "模式: $MODE（registry: $REGISTRY）"

if [ "$MODE" = "publish" ] && ! npm whoami --registry "$REGISTRY" >/dev/null 2>&1; then
  echo "未登录 npm。先执行：npm login --registry $REGISTRY" >&2
  exit 1
fi

# 二进制由 dist 拷入，不入版本库；install 保证可执行位
mkdir -p npm/cli-linux-x64/bin npm/cli-win32-x64/bin
install -m 0755 "$LINUX_BIN" npm/cli-linux-x64/bin/cjh
install -m 0755 "$WIN_BIN" npm/cli-win32-x64/bin/cjh.exe

# 三个包的版本号与主包 optionalDependencies 一起对齐，避免手改漏一处
node - "$VERSION" <<'JS'
const fs = require("fs");
const version = process.argv[2];
const targets = [
  "npm/cjh/package.json",
  "npm/cli-linux-x64/package.json",
  "npm/cli-win32-x64/package.json",
];
for (const file of targets) {
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  json.version = version;
  if (json.optionalDependencies) {
    for (const dep of Object.keys(json.optionalDependencies)) {
      json.optionalDependencies[dep] = version;
    }
  }
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
  console.log("  版本对齐: " + file);
}
JS

publish_pkg() {
  local dir=$1
  local name
  name=$(node -p "require('./$dir/package.json').name")
  echo "==> $name@$VERSION"
  if [ "$MODE" = "publish" ]; then
    # scoped 包必须 public，否则默认按私有发布并被拒
    (cd "$dir" && npm publish --registry "$REGISTRY" --access public $OTP_FLAG)
  else
    (cd "$dir" && npm pack --dry-run --registry "$REGISTRY")
  fi
}

publish_pkg npm/cli-linux-x64
publish_pkg npm/cli-win32-x64
publish_pkg npm/cjh

echo
if [ "$MODE" = "publish" ]; then
  echo "发布完成：npm i -g cjh 或 npx cjh 即可使用"
else
  echo "校验完成（未发布）。确认无误后执行：./scripts/npm_publish.sh --publish"
fi
