#!/usr/bin/env bash
# 单一版本源：VERSION（不带 v）。同步 cjpm.toml 与 Logo.VERSION。
# Web/MCP 的版本号在编译期从 Logo.VERSION 派生，无需改写。
set -euo pipefail
raw="${1:-}"
if [ -z "$raw" ]; then
  echo "usage: $0 <version>  (e.g. 1.6.16)" >&2
  exit 2
fi
ver="${raw#v}"
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid version: $raw" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$ver" > "$root/VERSION"
sed -i -E "s/^([[:space:]]*version[[:space:]]*=[[:space:]]*\")[^\"]+/\1$ver/" "$root/cjpm.toml"
sed -i -E "s/(public static const VERSION: String = \")v[^\"]+(\")/\1v$ver\2/" "$root/libs/cjterm/src/logo.cj"
echo "version -> $ver"
grep -E '^[[:space:]]*version[[:space:]]*=' "$root/cjpm.toml"
grep -E 'public static const VERSION' "$root/libs/cjterm/src/logo.cj"
