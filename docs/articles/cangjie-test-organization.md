# 632 个用例怎么摆：一个仓颉工程的测试分层与门禁

> 以 `cjh`（仓颉实现的终端编码代理）为例。仓颉语言、`cjpm` 构建、单仓多包。
> 本文只讲"怎么组织 + 怎么保证不退化"，不讲怎么跑通一个 hello world。

## 一、先看规模：测试不是一个目录，而是三层

```
src/tests/            44 个文件  439 例   （cjh.tests，只测可导入的部分）
src/core_funcs_test.cj           28 例    （根包 cjh 的函数测试）
libs/cjterm/src/tests/           96 例    （独立库包）
libs/cjllm/src/tests/            40 例
libs/cjutil/src/tests/           13 例
libs/cjcfg/src/tests/             8 例
libs/cjconfig/src/tests/          7 例
libs/cjlog/src/tests/             1 例
```

合计 632 例。这个结构不是一开始就设计好的，是被仓颉的编译模型一步步逼出来的。

## 二、为什么根包的测试必须单独放一个文件

仓颉里 **executable 根包不能被别的包 import**。想给 `cjh` 根包里的函数写测试，
最自然的想法是放进 `src/tests/`（package `cjh.tests`），但那样编译直接失败：

```
error: package 'cjh' cannot be imported
```

于是约定变成：

- 根包（`cjh`）的函数测试 → 只能放 `src/core_funcs_test.cj`，和根包同包
- 能被导入的（工具、网关、协议、Web 层）→ 放 `src/tests/`，独立 package `cjh.tests`

这条不是风格偏好，是编译器约束。写成规范后少走很多弯路：审 PR 时看测试落在哪个目录，
就知道作者有没有搞错包边界。

## 三、库包测试为什么不并入主工程

`libs/` 下每个目录都是一个独立包（`cjterm` 终端渲染、`cjllm` 模型接入、`cjutil` 基础设施、
`cjcfg` 配置与权限、`cjlog` 日志）。它们有各自的 `cjpm.toml`，因此：

- 根工程的 `cjpm test` **不会**跑到库包测试，必须 `cd libs/cjterm && cjpm test`
- CI 里两条命令分开跑，报告分开看（`scripts/test.sh` + 逐库）

好处是库包可以独立发布、独立被别的仓颉项目复用；代价是门禁要多记一条命令。
这个代价是划算的——把通用能力塞进业务包的耦合，比多跑一条命令贵得多。

## 四、用例隔离：三条硬规矩

测试串味是仓颉工程里最常见的"随机红"。三条规矩解决 90% 的问题：

**1. 配置目录隔离。** TUI/配置层初始化时会读真实用户数据（`~/.cjh` 的 history、draft、
settings），测试进程一旦读到，输入就被污染。所以测试进程统一走：

```bash
export CJH_CONFIG_DIR="$(mktemp -d /tmp/cjh_test_cfg.XXXXXX)"
```

`scripts/test.sh` 里固定做这件事，`tui_pty_test.py` 也做同样的事。

**2. 临时文件一律 `/tmp/cjh_ut_*`。** 每个用例独立目录，或用辅助函数
`testTempDir()` / `removeTree()`。

**3. `Directory.create` 不幂等。** 对已存在的目录直接抛异常——共享目录的测试类，
每个 `@TestCase` 开头必须先清理上一例的残留，否则单独跑绿、连着跑红。

## 五、断言放在"可观察契约"上，不放在私有实现上

工具类测试的写法差异最大。两种写法：

```cangjie
// ✗ 测私有实现：重构即碎
@Assert(tool.parseArgs(raw).get("path").isSome())

// ✓ 走公共 API，断言对外契约
let r = tool.execute(args)
@Assert(!r.isError, "expected success")
@Assert(r.content.contains("ok"))
```

后者只依赖 `ToolResult{isError, content, diff}` 这个对外契约：换内部结构测试不动，
但换契约测试必定变红——这才是我们想要的耦合方向。

同样的思路用在模型接入层：不真连 OpenAI，传一个替身 `LlmProvider`（`StubProviderFactory`、
`SlowProvider`、`TruncatingProvider`），在 `chatStream` 里按剧本吐帧。这样"上游返回错误"
"上游超时""上游截断"这些分支全都能被稳定复现，不用靠网络运气。

## 六、门禁脚本：为什么它要改配置

`cjpm.toml` 默认静态链接（`--static --static-std`），产物单文件零依赖，可直接分发。
但静态链接下 `cjpm test` 会 **double free 崩溃**（仓颉运行时 + 测试框架的组合 bug，
发布二进制本身正常）。

所以 `scripts/test.sh` 做的是"切配置跑测试、跑完还原"：

```bash
cp "$STATIC_CFG" "$BACKUP"     # 备份静态
cp "$DYNAMIC_CFG" "$STATIC_CFG" # 切动态
restore() { cp "$BACKUP" "$STATIC_CFG"; }
trap restore EXIT INT TERM HUP   # 关键：不只 EXIT
```

`trap` 那行踩过一次事故：只 trap `EXIT` 时，一次被 `timeout`/`Ctrl-C` 强杀的运行会把
**动态配置留在仓库里**，随后一次发布提交就把动态态 + 陈旧版本号带进了 git。补上
`INT TERM HUP` 之后同类事故再没发生过。

脚本另外做了兜底自检：进来若发现 `cjpm.toml` 已是动态态（上次被强杀没还原），
先警告"请先恢复静态基线"，避免在错误的基线上继续跑。

## 七、仓颉测试的语法坑清单

这些坑的共同点是：**编译期或运行期的报错信息不指向真正的原因**。记下来能省几小时。

| 坑 | 现象 | 正确写法 |
|---|---|---|
| 零参 lambda | 语法错 | `{ => ... }` |
| 命名参数 | `p!:` 才支持 | 普通参数按位置传 |
| 默认参数 | 不支持 | 显式传全参 |
| 字符串迭代 | 拿到 `Byte` 不是字符 | 与 `120u8` 这类字面量比较 |
| `text[i]` | 同上，给 `Byte` | `Byte = UInt8`，字面量写 `0x41u8` |
| `StringBuilder.append(Byte)` | 按**十进制整数**输出（大坑） | 整段 `String` 切片拼接，别逐字节 append |
| 块注释 | 内含 `/*` 序列触发嵌套注释解析 | 注释里别写 `/*` |
| 枚举期望值断言 | `unable to infer generic argument` | `match` 转 `Bool` 再 `@Assert` |
| `append` 返回值 | `StringBuilder.append` 返回 `Unit` | 不能链式调用 |

## 八、不为了绿而改测试

门禁之所以有意义，是因为它挡得住"为了让流水线变绿而弱化断言"。这条要写进规范：

- 构建/测试红了 → 找**根因**修。禁止删测试、注释断言、`@Ignore`、放宽类型来消除红灯
- 修 bug → 先写**能复现该 bug 的失败测试**，再修到绿
- 新功能 → 主路径 + 错误路径 + 一个边界，缺一不可

一句"改动小/时间紧"就跳过测试，等于把这个门禁换成装饰。

## 九、怎么跑

```bash
source /opt/cangjie/cangjie/envsetup.sh   # cjpm 不在默认 PATH
./scripts/test.sh                          # 主工程全量（自动切动态、结束还原）
./scripts/test.sh --filter "*grep*"        # 只跑某一组
cd libs/cjterm && cjpm test                # 库包单独跑（主脚本不覆盖）
python3 scripts/tui_pty_test.py            # TUI 改动另加：伪终端驱动真实 TUI
```

TUI 那条值得单独说：终端 UI 的很多行为（差分渲染、光标定位、粘贴解码）在纯单元测试里
测不出来，只能在真实伪终端里跑。它比单元测试慢、比单元测试脆，但它是唯一能兜住"界面
看起来没坏、其实输入丢字"这类问题的手段。

## 小结

一个仓颉工程的测试组织，本质上要回答三个问题：

1. **放哪里**：根包 / `cjh.tests` / 独立库包 —— 由编译模型决定，不是喜好
2. **怎么隔离**：配置目录、临时目录、非幂等 API —— 决定测试是否能连着跑
3. **怎么不被绕过**：门禁脚本 + "先复现再修"的规矩 —— 决定这套东西半年后还在不在

632 个用例的价值不在数字，而在于它们让"改一行代码"不必靠祈祷。
