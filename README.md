# cjh：仓颉语言 Coding Agent

**Cangjie Harness** —— 用华为仓颉语言从零实现的交互式编码代理（coding agent）。

在终端里用自然语言描述任务（"修改某文件的某函数"、"跑测试看结果"），agent 理解意图、自主规划、调用工具（执行命令、读写文件）、观察结果、迭代直到完成。全程在终端 TUI 中呈现，可离线 mock 验证。

## 特性

- **Agent 核心**：消息状态机 + 工具调用协议 + 多轮迭代（LLM → 工具 → 结果回填 → 再调用）
- **工具系统**：bash 执行 / 文件读取 / 文件写入（JSON Schema 定义，注册即用）
- **LLM 层**：OpenAI 兼容协议（OpenAI / DeepSeek / 通义 / Moonshot 等通用）+ SSE 流式解析 + 工具调用分片累积
- **TUI**：差分渲染终端界面、termios 原始模式（C FFI）、非阻塞按键、实时 ioctl 尺寸
- **离线验证**：`--mock` 模式用脚本化 LLM 跑通完整工具链，无 API Key 也能测
- **单二进制**：仓颉 cjnative 静态编译，无运行时依赖

## 架构

```
终端 TUI（tui/）← 差分渲染 + 按键 + 尺寸
    │
Agent 运行时（agent/）← 主循环：消息状态机 + 工具调用协议
    │
工具集（tools/）← bash / read_file / write_file
    │
LLM 提供商层（llm/）← OpenAI 兼容 + SSE 流式 + mock
```

### 包划分

| 包 | 职责 |
|---|---|
| `cjh.model` | 消息模型（ChatMessage / ToolCall / ModelResponse），无依赖 |
| `cjh.llm` | LLM 提供商抽象、SSE 解析、流式累加器、mock |
| `cjh.tools` | 工具接口、注册中心、内置工具 |
| `cjh.agent` | agent 主循环编排 |
| `cjh.tui` | ANSI 控制、差分渲染、termios（C FFI） |
| `cjh` | CLI/TUI 入口与配置 |

## 快速开始

### 环境要求

- 仓颉 SDK 1.0.5（cjc / cjpm）
- stdx 扩展标准库（`setup_stdx.py` 装配）
- Linux（WebKitGTK 不需要；本项目纯终端）

### 构建

```bash
source /root/test/cj/tauri_cj/cj-env.sh   # 或你自己的 cj-env.sh

# 编译 C 终端层
mkdir -p native
gcc -shared -fPIC -fstack-protector-all src/tui/term.c -o native/libcjterm.so

# 构建
cjpm build
```

### 运行

```bash
export LD_LIBRARY_PATH=$PWD/native:<stdx动态库目录>:<仓颉runtime目录>:$LD_LIBRARY_PATH

# TUI 模式（默认，需 API Key）
export OPENAI_API_KEY=sk-xxx        # 或 DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY
export CJH_BASE_URL=...              # 可选，默认 OpenAI
export CJH_MODEL=...                 # 可选，默认 gpt-4o-mini
./target/release/bin/main

# 纯文本 CLI 模式
./target/release/bin/main --cli

# TUI + mock（无 API Key 界面演示）
CJH_MOCK=1 ./target/release/bin/main

# 离线工具链验证
./target/release/bin/main --mock
```

### 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `CJH_API_KEY` | API Key（任一） | — |
| `CJH_BASE_URL` | LLM 端点 | OpenAI |
| `CJH_MODEL` | 模型名 | gpt-4o-mini |
| `CJH_MOCK` | `1` 启用 mock | 关 |

## 开发一个工具

```cangjie
public class GrepTool <: CjhTool {
    public init() {}
    public func spec(): ToolSpec {
        var props = HashMap<String, JsonValue>()
        props.add("pattern", JsonSchema.str("要搜索的正则"))
        props.add("path", JsonSchema.str("搜索路径"))
        return ToolSpec("grep", "在文件中搜索文本", JsonSchema.object(props, ArrayList<String>(["pattern", "path"])))
    }
    public func execute(args: JsonObject): ToolResult {
        let pattern = args.get("pattern").getOrThrow().asString().getValue()
        // ... 实现搜索
        return ToolResult("结果", false)
    }
}

// 注册
let registry = ToolRegistry()
registry.register(GrepTool())
```

## 验证结果（2026-08-21）

| 验证项 | 结果 |
|---|---|
| 工具调用链（read_file → bash → 最终答复） | ✅ 端到端通过（--mock） |
| TUI 交互（输入提交、工具实时上屏、Ctrl-C 退出） | ✅ PTY 验证 |
| CLI 模式 / API Key 校验 | ✅ |
| 无 API Key 离线演示 | ✅ CJH_MOCK=1 |

## 路线

- ✅ **P0 MVP**：agent 核心 + 3 工具 + OpenAI 协议 + TUI + mock
- 🔜 P1：SSE 增量实时上屏、会话持久化（SQLite）、Anthropic 协议、工具扩展（grep/ls）
- 🔜 P2：skills 自扩展、配置系统、多提供商切换
- 🔜 P3：远端协议（client/server）

## 文档

- `方案.md` — 项目设计与实施计划
- `docs/开发文档与踩坑记录.md` — 架构、验证结果、仓颉工程踩坑

## License

MIT
