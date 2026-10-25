# npm 发布说明（维护者）

cjh 通过 npm 分发时拆成三个包，主包只放启动器，二进制在平台包里：

| 目录 | 包名 | 内容 |
| --- | --- | --- |
| `npm/cjh` | `cjh` | `bin/cjh.js` 启动器 + 英文 README（约 2 KB） |
| `npm/cli-linux-x64` | `@cjh/cli-linux-x64` | Linux x64 二进制（压缩后约 5.8 MB） |
| `npm/cli-win32-x64` | `@cjh/cli-win32-x64` | Windows x64 二进制（压缩后约 4.9 MB） |

平台包用 `os` / `cpu` 字段声明适用范围，主包用 `optionalDependencies` 依赖它们，npm 只装匹配当前平台的那个。

## 发布流程

```bash
# 1. 先把产物构建到 dist/（Linux 二进制 + Windows exe）
./scripts/winbuild.sh                       # 交叉编译 Windows
cp target/release/bin/cjh dist/cjh-linux-x64
cp target/x86_64-pc-windows-gnu/release/bin/main.exe dist/cjh-windows-x64.exe

# 2. 校验（只打包不发布，会打印三个包的体积与内容清单）
./scripts/npm_publish.sh

# 3. 登录并真发布
npm login --registry https://registry.npmjs.org
./scripts/npm_publish.sh --publish
```

脚本会做三件事：把 `dist/` 的二进制 `install -m 0755` 到平台包的 `bin/`、以 `cjpm.toml` 的 `version` 为唯一来源对齐三个包的版本号（含主包的 `optionalDependencies`）、按 **平台包 → 主包** 的顺序发布。

发布顺序不能颠倒：主包里写的是精确版本号，平台包没先上架的话，用户装主包时 `optionalDependencies` 解析不到东西。

## 四个必须注意的坑

1. **registry 必须显式指定**。本机 `~/.npmrc` 的 `registry` 指向 `registry.npmmirror.com`，直接 `npm publish` 会推到镜像站然后失败。脚本里已经写死 `--registry https://registry.npmjs.org`，手敲命令时别漏。
2. **scoped 包必须加 `--access public`**。`@cjh/cli-*` 不加会按私有包处理并被拒。脚本已带。
3. **开了 2FA 的账号要 OTP**。`npm publish` 需要一次性密码：交互终端里 npm 会提示输入，但脚本在非 TTY（CI / agent）下没有提示、只会 `EOTP` 直接失败。用 `NPM_OTP=123456 ./scripts/npm_publish.sh --publish` 显式传入；长期自动化建议建一个 **Automation** 类型的 granular token 写进 `~/.npmrc`，可完全绕过 OTP。
4. **二进制不入版本库**。`npm/cli-*/bin/cjh*` 已在 `.gitignore` 里，由脚本从 `dist/` 拷入。别为了"省事"把 17 MB 的二进制提交进去。

## 发版检查清单

- [ ] `cjpm.toml` 的 `version` 已改成新版本（脚本以它为准，其余三处自动同步）
- [ ] `dist/cjh-linux-x64` 与 `dist/cjh-windows-x64.exe` 是新版本（`strings` 能查到版本号）
- [ ] `./scripts/npm_publish.sh` 三个包体积正常（主包 KB 级、平台包 5 MB 级）
- [ ] 发布后 `npm i -g cjh` 起得来，`npx cjh` 在干净目录可用
- [ ] npm 页面（README、repository、license）显示正常

## 已知限制

- 只发布 `linux-x64` 与 `win32-x64`。其它平台（`darwin-*`、`linux-arm64`）目前没有预编译产物，启动器会明确报「no prebuilt binary」并给出 Release 链接，而不是抛一个看不懂的 ENOENT。
- `--version` / `-v` 与 `--help` / `-h` 都已支持：版本输出形如 `cjh v1.5.3`，与 cjterm 的 `Logo.VERSION` 同源（`testCliVersionTextMatchesLogoVersion` 兜住发版漏改）；帮助是纯文本用法清单，不进 TUI、不读配置。
