# cjh 示例插件

本目录包含 cjh 插件系统的示例插件，供参考和快速上手。

## 目录结构

```
example/plugins/
├── echo-test/                    # 工具插件示例
│   ├── plugin.json               # 插件元数据
│   └── tools/
│       └── echo.sh               # 工具实现（shell 脚本）
│
└── log-pruner/                   # 事件钩子插件示例
    ├── plugin.json
    └── hooks/
        └── on_tool_result.sh     # on_tool_result 钩子
```

## 安装示例插件

将 `example/plugins/` 下的插件目录复制到 `~/.cjh/plugins/`：

```bash
cp -r example/plugins/* ~/.cjh/plugins/
chmod +x ~/.cjh/plugins/echo-test/tools/echo.sh
chmod +x ~/.cjh/plugins/log-pruner/hooks/on_tool_result.sh
```

cjh 启动时会自动扫描 `~/.cjh/plugins/` 并加载插件。

## echo-test：工具插件示例

最简单的插件——注册一个 `echo` 工具，回显传入的 `message` 参数。

### plugin.json

```json
{
  "name": "echo-test",
  "version": "1.0.0",
  "description": "测试插件：回显传入的 message 参数",
  "tools": [
    {
      "name": "echo",
      "description": "Echo back the message parameter.",
      "command": "tools/echo.sh",
      "is_read_only": true,
      "parameters": {
        "type": "object",
        "properties": {
          "message": { "type": "string", "description": "Message to echo back" }
        },
        "required": ["message"]
      }
    }
  ]
}
```

### 工具实现协议

插件工具通过**环境变量**接收参数：

| 环境变量 | 内容 |
|----------|------|
| `CJH_TOOL_ARGS` | LLM 传入的参数（JSON 字符串） |

工具脚本通过 stdout 输出结果文本（回填到消息历史），退出码 0=成功、非0=失败。

### echo.sh

```bash
#!/bin/bash
# 参数通过环境变量 CJH_TOOL_ARGS 传递（JSON 字符串）
MESSAGE=$(echo "$CJH_TOOL_ARGS" | jq -r '.message // empty')
echo "[echo plugin] message: ${MESSAGE}"
```

### 验证

```
❯ 用 echo 工具回显消息 "hello from plugin"
▶ echo message: hello from plugin
  ↳ echo: [echo plugin] message: hello from plugin
✓ 2 rounds · 1 tools · 4.062s · 4.855K tokens · 96% cached
```

## log-pruner：事件钩子插件示例

注册一个 `on_tool_result` 事件钩子——工具结果超 1000 字符时截断到头 500 + 尾 500 + 省略标记。

### plugin.json

```json
{
  "name": "log-pruner",
  "version": "1.0.0",
  "description": "工具结果裁剪钩子：超 1000 字符的结果截断到头 500 + 尾 500",
  "hooks": {
    "on_tool_result": "hooks/on_tool_result.sh"
  }
}
```

### 钩子实现协议

钩子脚本通过**环境变量**接收事件数据：

| 环境变量 | 内容 |
|----------|------|
| `CJH_HOOK_DATA` | 事件数据（JSON 字符串） |

`on_tool_result` 事件数据格式：

```json
{
  "tool": "bash",
  "content": "命令输出..."
}
```

钩子脚本通过 stdout 输出**改写后的 content**，退出码 0=正常、非0=失败（用原内容）。

### on_tool_result.sh

```bash
#!/bin/bash
CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')
LEN=${#CONTENT}

if [ "$LEN" -le 1000 ]; then
  echo "$CONTENT"
  exit 0
fi

HEAD=$(echo "$CONTENT" | head -c 500)
TAIL=$(echo "$CONTENT" | tail -c 500)
SKIPPED=$((LEN - 1000))
printf '%s\n\n[log-pruner 截断 %d 字符]\n\n%s' "$HEAD" "$SKIPPED" "$TAIL"
```

## signed-demo：带 SM2 签名的插件示例（V3 信任链 Step 1+2）

普通插件只声明工具，任何人都能改。`signed-demo` 演示**信任链**：插件带 `checksum`（防篡改）+ `publisher`/`pubkey`/`signature`（防冒充），cjh 加载时用仓颉原生 SM2 验签，零外部依赖。

### 目录结构

```
example/plugins/signed-demo/
├── plugin.json              # 带 checksum/publisher/pubkey/signature 四字段
├── tools/
│   └── greet.sh            # 工具实现
├── src/
│   └── gen_signed_demo.cj  # 签名生成小程序（演示如何签发插件）
└── cjpm.toml               # 独立 cjpm 工程配置
```

### plugin.json（带签名字段）

```json
{
  "name": "signed-demo",
  "version": "1.0.0",
  "description": "带 SM2 签名的插件 demo（V3 信任链 Step 1+2）。",
  "tools": [
    {
      "name": "greet",
      "description": "Greet someone by name.",
      "command": "tools/greet.sh",
      "is_read_only": true,
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Name of the person to greet" }
        },
        "required": ["name"]
      }
    }
  ],
  "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "publisher": "github:cjh-demo",
  "pubkey": "3059301306072a8648ce3d020106082a811ccf5501822d03420004...",
  "signature": "3045022100fe42fa103dbdeed8bc8c8665017583d8aa574878..."
}
```

**字段说明**：

| 字段 | 含义 | 由谁填写 |
|------|------|----------|
| `checksum` | 插件目录（除 plugin.json 外）的 SHA256 指纹 | 签名工具自动计算 |
| `publisher` | 发布者 ID（如 `github:alice`） | 插件作者 |
| `pubkey` | 发布者 SM2 公钥（DER 编码的 hex） | 签名工具从密钥对导出 |
| `signature` | 对 `checksum` 字段值的 SM2 签名 | 签名工具用私钥签 |

**cjh 加载时的验证流程**：

1. 算 `sha256DirExcluding(pluginDir, "plugin.json")` → 对比 `checksum` 字段（检测文件被篡改）
2. `verifySm2(pubkey, signature, checksum)` → 用公钥验签（防供应链投毒：攻击者改完文件重算 checksum 也没用，他没有私钥签不出合法 signature）
3. 任一步骤失败 → `Log.warn` + 拒绝加载

### 签名操作步骤

本 demo 提供了签名生成小程序 `src/gen_signed_demo.cj`。完整流程：

#### 步骤 1：编写插件（无签名）

先按普通插件编写 `plugin.json` 和 `tools/greet.sh`，此时不带任何签名字段。

#### 步骤 2：编译签名工具

签名工具是个独立的 cjpm 工程，依赖 `cjutil`（提供 SM2 签名/验签 API）：

```bash
cd example/plugins/signed-demo
cjpm build
```

产物在 `target/release/bin/main`。

#### 步骤 3：运行签名工具，生成 plugin.json 签名字段

**必须从工程根目录运行**（小程序用相对路径 `example/plugins/signed-demo` 定位插件）：

```bash
cd /path/to/cjh   # 工程根目录
./example/plugins/signed-demo/target/release/bin/main
```

输出示例：

```
checksum = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
pubkey   = 3059301306072a8648ce3d020106082a811ccf5501822d03420004...
signature= 3045022100fe42fa103dbdeed8bc8c8665017583d8aa574878...
self-verify: OK
Done! plugin.json updated with SM2 signature.
```

小程序做的事：

1. `sha256DirExcluding(pluginDir, "plugin.json")` 算 checksum
2. `SM2PrivateKey()` 生成 SM2 密钥对（**演示用**；真实场景私钥离线保管，不进插件包）
3. `SM2PublicKey.encodeToDer()` → hex 得到 `pubkey` 字段
4. `signSm2(privateKey, hexToBytes(checksum))` → hex 得到 `signature` 字段
5. `verifySm2(...)` 自验通过
6. 把 `checksum`/`publisher`/`pubkey`/`signature` 四个字段写回 `plugin.json`

> **注意**：本 demo 每次运行都生成新的密钥对，所以 `pubkey`/`signature` 每次不同。真实发布流程中，私钥应当持久化保管、复用同一个密钥对签发多个插件。详见[插件签名与贡献指南](../docs/插件签名与贡献指南.md) 第 4.6 节。

### 安装与使用

#### 安装

把 `signed-demo` 目录复制到 `~/.cjh/plugins/`：

```bash
cp -r example/plugins/signed-demo ~/.cjh/plugins/
chmod +x ~/.cjh/plugins/signed-demo/tools/greet.sh
```

> 复制时**不要带** `src/`、`cjpm.toml`、`target/`——那些只是签名工具的工程文件，不是插件本体：
> ```bash
> rsync -a --exclude='src' --exclude='cjpm.toml' --exclude='target' \
>   example/plugins/signed-demo/ ~/.cjh/plugins/signed-demo/
> ```

#### 验证加载

启动 cjh，带 `--debug` 可看到签名验证日志：

```bash
cjh --debug
```

日志应出现：

```
[PLUGIN] 校验和验证通过: signed-demo
[PLUGIN] SM2 签名验证通过: signed-demo publisher=github:cjh-demo
[PLUGIN] 注册工具: greet
```

#### 使用工具

在 cjh 会话里让 LLM 调用 `greet` 工具：

```
❯ 用 greet 工具向 Alice 问好
▶ greet name: Alice
  ↳ greet: [signed-demo] Hello, Alice! This plugin is SM2-signed.
✓ 2 rounds · 1 tools · ...
```

#### 篡改检测演示

修改插件脚本（模拟攻击者篡改）：

```bash
echo "echo 'tampered'" >> ~/.cjh/plugins/signed-demo/tools/greet.sh
cjh --debug
```

日志会出现校验和不匹配，插件被拒绝加载：

```
[PLUGIN] 校验和不匹配，拒绝加载: signed-demo (expected=e3b0..., actual=...)
```

恢复脚本后即可正常加载。

## 编写自己的插件

### 1. 创建插件目录

```bash
mkdir -p ~/.cjh/plugins/my-plugin/tools
```

### 2. 编写 plugin.json

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "我的插件",
  "tools": [
    {
      "name": "my_tool",
      "description": "我的工具",
      "command": "tools/my_tool.sh",
      "is_read_only": true,
      "parameters": {
        "type": "object",
        "properties": {
          "input": { "type": "string", "description": "输入参数" }
        },
        "required": ["input"]
      }
    }
  ],
  "hooks": {
    "on_tool_result": "hooks/on_tool_result.sh"
  }
}
```

### 3. 编写工具脚本

```bash
#!/bin/bash
INPUT=$(echo "$CJH_TOOL_ARGS" | jq -r '.input // empty')
echo "处理结果: ${INPUT}"
```

### 4. 编写钩子脚本（可选）

```bash
#!/bin/bash
CONTENT=$(echo "$CJH_HOOK_DATA" | jq -r '.content // empty')
# 改写 content...
echo "$CONTENT"
```

### 5. 加执行权限

```bash
chmod +x ~/.cjh/plugins/my-plugin/tools/my_tool.sh
chmod +x ~/.cjh/plugins/my-plugin/hooks/on_tool_result.sh
```

### 6. 启动 cjh 验证

```bash
cjh
❯ 用 my_tool 工具处理输入 "test"
```

## 配置

### 启用插件白名单

在 `~/.cjh/settings.json` 中配置 `enabled_plugins`：

```json
{
  "enabled_plugins": ["echo-test", "log-pruner"]
}
```

未配置或空数组 = 全部启用。

### 事件钩子列表

| 事件 | 触发时机 | 可拦截/改写 |
|------|----------|-------------|
| `on_tool_result` | 工具执行完毕、回填消息历史之前 | ✅ 改写 content |

未来扩展：`on_tool_start`、`on_delta`、`on_compaction`、`on_session_end`。

## 参考文档

- [插件系统实现方案](../docs/插件系统实现方案.md)
- [cjh 方案与架构设计](../docs/方案与架构设计-v2.md)
