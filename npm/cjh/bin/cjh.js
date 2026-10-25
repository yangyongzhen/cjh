#!/usr/bin/env node
"use strict";

// 启动器：把 npm 安装的对应平台二进制交给 stdio，参数与退出码原样透传。
// 二进制本体在 @cjh/cli-<platform>-<arch> 里，主包不含任何平台代码。

const { spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

const PLATFORM_PACKAGES = {
  "linux-x64": { pkg: "@cjh/cli-linux-x64", binary: "cjh" },
  "win32-x64": { pkg: "@cjh/cli-win32-x64", binary: "cjh.exe" },
};

const RELEASES = "https://atomgit.com/qq8864/cjh/releases";

function fail(message) {
  process.stderr.write(message + "\n");
  process.exit(1);
}

const target = PLATFORM_PACKAGES[`${process.platform}-${process.arch}`];

if (target === undefined) {
  fail(
    `cjh: no prebuilt binary for "${process.platform}-${process.arch}".\n` +
      `Published platforms: ${Object.keys(PLATFORM_PACKAGES).join(", ")}.\n` +
      `Download a release instead: ${RELEASES}`
  );
}

function resolveBinary() {
  // 正常路径：optional dependency 装上了
  try {
    const pkgJson = require.resolve(`${target.pkg}/package.json`);
    const candidate = path.join(path.dirname(pkgJson), "bin", target.binary);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  } catch (_) {
    // 未装（--no-optional、镜像站丢弃 optional deps、或不支持该平台）
  }
  // 兜底：与启动器同目录，便于本地开发/离线放置
  const local = path.join(__dirname, target.binary);
  return fs.existsSync(local) ? local : null;
}

const binary = resolveBinary();

if (binary === null) {
  fail(
    `cjh: the platform package "${target.pkg}" is not installed.\n` +
      `This usually means optional dependencies were skipped\n` +
      `(npm installed with --no-optional / --omit=optional, or a mirror that drops them).\n` +
      `Retry with: npm install -g cjh --include=optional\n` +
      `Or download the binary directly: ${RELEASES}`
  );
}

const child = spawn(binary, process.argv.slice(2), { stdio: "inherit" });

child.on("error", (err) => {
  fail(`cjh: failed to start "${binary}": ${err.message}`);
});

child.on("exit", (code, signal) => {
  if (signal !== null) {
    // 透传 Ctrl-C 这类信号语义
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code === null ? 1 : code);
});
