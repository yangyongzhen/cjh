# cjh 库集合（libs/）

cjh 的分层库目录。按发布性质分两类：

## 可独立发布库（贡献仓颉生态）

| 库 | 定位 | 依赖 | 发布难度 |
|---|---|---|---|
| **cjterm** | 终端 UI 组件库（ANSI/差分渲染/组件/TerminalBackend 跨平台终端层） | 零依赖（仅 std） | ★ |
| **cjlog** | 异步日志库（级别/双文件/异常堆栈） | 零依赖（仅 std） | ★ |
| **cjconfig** | 通用分层配置库（环境变量 > 文件 > 默认值） | 仅官方 stdx.json | ★ |
| **cjutil** | 工具库（UTF-8/SHA-256/SM2/网页提取/BM25/JSON 修复/SSRF/FFI） | 官方 stdx | ★★ |
| **cjllm** | LLM 协议库（OpenAI/Anthropic/Ollama/Mock） | cjutil + cjlog + stdx | ★★★ |

每个库自带 README / LICENSE(MIT) / examples / .github CI 模板 / docs/发布指南.md，
独立仓库发布步骤见各库 docs/发布指南.md。

## cjh 内部库（不独立发布）

| 库 | 定位 | 说明 |
|---|---|---|
| **cjcfg** | cjh 配置/安全/会话层 | **架构必要**：CjhConfig 类型需被 cjh.web / cjh.tui 等子包 import，而仓颉 executable 根包不能被导入 → 配置层必须在根包外。但它是 cjh 应用专属（settings schema/capability/工作区/会话），**非通用可复用库，不参与独立发布**。通用能力已剥离：EnvFfi → cjutil，配置机制 → cjconfig |

## 依赖方向

```
cjlog ← cjllm ← cjcfg ←（cjh 应用：tui/web/tools）
cjutil ─┘        ┘
cjconfig（独立，供任意应用）
cjterm（独立，供任意 TUI 应用）
```
