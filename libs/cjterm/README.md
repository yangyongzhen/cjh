# cjterm · 仓颉原生终端 UI 库

**零依赖、跨平台的 TUI 组件库**——用华为仓颉语言实现，不依赖任何第三方库（仅仓颉标准库）。

终端里用组件拼出完整交互界面：ANSI 控制、差分渲染、输入框/编辑器/表单/列表选择/确认框、状态栏/TabBar/任务面板、跨平台终端层（termios / Win32 Console）。

## 特性

| 特性 | 说明 |
|---|---|
| **零依赖** | 仅仓颉 std 标准库，无任何第三方包（`cjpm.toml` dependencies 为空） |
| **跨平台终端层** | `TerminalBackend` 抽象 + `@When[os]` 条件编译：Linux/macOS 用 termios（纯 libc FFI），Windows 用 Win32 Console API + VT 输出。一份源码多平台二进制 |
| **差分渲染** | `TuiCanvas` 全量声明 + 增量输出（帧间 diff），低开销刷新，自动感知 resize 清缓存 |
| **原始模式输入** | 逐键读取（含 UTF-8 多字节/方向键/功能键/鼠标 SGR/粘贴），与平台无关的 `KeyEvent` 语义 |
| **组件化** | `Component` 接口 + Box/InputBox/MultiLineEditor/FormDialog/ConfirmDialog/OutputView/Spinner/StatusBar/TabBar/TasksPanel/ListSelect/ListPicker/Logo |
| **主题** | 6 套内置配色（starfrost/classic/catppuccin/rose-pine/solarized/monokai） |

## 快速开始

```toml
# cjpm.toml
[package]
  name = "my-tui-app"
  version = "0.1.0"
  output-type = "executable"

[dependencies]
  cjterm = { path = "../cjterm" }   # 或发布后：cjterm = "0.1.0"
```

```cangjie
package myapp

import cjterm.*
import std.collection.*

main(): Int64 {
    // 1. 原始模式 + 清屏
    let term = Term()
    term.enableRaw()
    print(Ansi.clearScreen(), flush: true)

    // 2. 画一帧：logo + 分隔线 + 状态行
    let (rows, cols) = TermSize.get()
    let canvas = TuiCanvas()
    canvas.begin(rows, cols, true)
    canvas.setLine(0, Logo.renderLinesModern(term.isUtf8())[0])
    canvas.setLine(1, Ansi.fg(Ansi.THEME_ACCENT) + "=".repeat(cols) + Ansi.reset())
    canvas.setLine(rows - 1, Ansi.fg(Ansi.THEME_MUTED) + "q 退出" + Ansi.reset())
    print(canvas.flush(), flush: true)

    // 3. 读键循环
    while (true) {
        if (let Some(k) <- term.readKey()) {
            if (k.isCtrlC || k.ch == 113 /* q */) { break }   // Ctrl+C 或 q
        }
        sleep(Duration.millisecond * 10)
    }

    term.disableRaw()
    return 0
}
```

## API 概览

### 终端层（跨平台）

| 类型 | 说明 |
|---|---|
| `Term` | 终端控制器：`enableRaw()/disableRaw()/readKey()/waitInput()/size()/sizeChanged()/isUtf8()/enterAltScreen()` 等 |
| `KeyEvent` | 平台无关按键事件：`ch/isEsc/isEnter/isCtrlC/isBackspace/isTab/isArrow*/isPage*/isMouse/isPaste/text` |
| `TerminalBackend` | 终端后端接口（raw 模式/输入探测/读键/尺寸/UTF-8/stderr 屏蔽）；`PosixTerminalBackend`（termios）与 `WindowsTerminalBackend`（Win32）由 `createTerminalBackend()` 条件编译选择 |
| `TermSize` | 实时终端尺寸（resize 感知） |
| `TermEnv` / `TermEsc` | 环境变量读取 / 转义序列常量 |
| `Stderr` | stderr 屏蔽（TUI 全屏防污染） |

### 渲染

| 类型 | 说明 |
|---|---|
| `Ansi` | ANSI 控制：颜色（`fg/bg` 256 色）、光标、清屏、备用屏、鼠标模式；主题色常量 |
| `TuiCanvas` | 差分渲染画布：`begin(rows, cols, sizeChanged)` → `setLine(row, text)` → `flush()` |
| `Screen` | 屏幕网格 + `diff(old)` 增量输出 |
| `Component` | 组件接口（`render(canvas, ...)`） |

### 组件

| 组件 | 用途 |
|---|---|
| `Box` | 带标题的边框容器 |
| `InputBox` | 单行输入框 |
| `MultiLineEditor` | 多行编辑器（Ctrl+E 进入模式） |
| `FormDialog` | 表单弹窗（多字段，支持密码掩码） |
| `ConfirmDialog` | 确认弹窗（y/n） |
| `OutputView` | 可滚动输出区（流式追加） |
| `Spinner` | 加载动画 |
| `StatusBar` / `TabBar` / `TasksPanel` | 状态行 / 视图标签栏 / 任务列表面板 |
| `ListSelect` / `ListPicker` | 列表选择（滚动/高亮/分页） |
| `Logo` | 彩色 logo 渲染 |

## 跨平台说明

终端层 `TerminalBackend` 把平台差异（原始模式/按键/尺寸/stderr）抽象为接口：

- **POSIX**（Linux/macOS）：termios/ioctl/select 纯 libc FFI，无外部 .so
- **Windows**（10 1809+ / Windows Terminal）：VT 输出（`EnableVirtualTerminalProcessing`）+ Win32 Console API 输入（`ReadConsoleInputW`），依赖仅 kernel32.dll（系统自带）

渲染层（ANSI/VT 转义 + 差分渲染）天然跨平台，无需分平台实现。构建：

```bash
cjpm build                                   # 当前平台
cjc src/*.cj --target x86_64-pc-windows-gnu  # 交叉编译 Windows（需 stdx 无关，纯 std）
```

## 测试

```bash
cjpm test
```

## 许可

MIT
