# cjutil · 仓颉通用工具库

**文本处理 + 密码学 + 网络安全的仓颉工具集**——仅依赖官方 stdx 扩展库（无第三方包）。

## 模块

| 模块 | 文件 | 功能 |
|---|---|---|
| **UTF-8 工具** | `utf8.cj` | 字节安全截断（不切坏多字节字符）、安全解码（非法序列替换） |
| **哈希** | `sha256.cj` | SHA-256（输入/文件/流式）、HMAC-SHA256 |
| **国密 SM2** | `sm2.cj` | SM2 加解密 + 签名（仓颉 stdx.crypto 原生，零外部依赖） |
| **网页正文提取** | `article_reader.cj` | HTML 正文/标题提取、按句/按块分块（chunkBySentence/chunkBySize）、正文压缩 |
| **HTML 清洗** | `html_cleaner.cj` | HTML → Markdown（`HtmlCleaner.toMarkdown`） |
| **BM25 检索** | `bm25.cj` | 经典 BM25 检索 + 字符 bigram 索引（中文友好） |
| **HTTP 客户端** | `http_client.cj` | 带超时/重定向/SSRF 防护的 HTTP 请求 |
| **JSON 修复** | `jsonrepair.cj` | 损坏 JSON 的智能修复（截断/尾逗号/单引号等） |
| **SSRF 防护** | `ssrf.cj` | 私网 IP/域名检测（Web 抓取安全） |
| **跨平台 FFI** | `env_ffi.cj` | `EnvFfi`：getenv / 运行时 chdir / 跨平台 homeDir（Windows USERPROFILE → POSIX HOME） |

## 快速开始

```toml
[dependencies]
  cjutil = { path = "../cjutil" }   # 或发布后：cjutil = "0.1.0"
```

```cangjie
import cjutil.*

main() {
    // UTF-8 安全截断（不切坏中文）
    let s = truncateUtf8("你好世界 hello", 7)
    println(s)                        // "你好世"（第 7 字节落在中文字符则前移）

    // SHA-256
    let digest = sha256Hex("hello".toArray())
    println(digest)                   // 2cf24dba...

    // HTML → Markdown
    let md = HtmlCleaner.toMarkdown("<h1>标题</h1><p>正文</p>")
    println(md)
}
```

## 依赖

- 仓颉 std 标准库 + **官方 stdx**（`stdx.net.http` / `stdx.crypto` / `stdx.encoding.json` 等）
- 无任何第三方包；SM2/SHA-256 用仓颉 `stdx.crypto` 原生实现，零外部密码学库

## 许可

MIT
