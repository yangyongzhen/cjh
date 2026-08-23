package cjh.tui

import cjterm.*

/**
 * Markdown 增量渲染器：把 LLM 回复中的 markdown 语法转为 ANSI 高亮
 *
 * 支持（流式安全，增量 token 逐个处理）：
 * - **粗体** → 加粗
 * - `行内代码` → 青色
 * - ``` 代码块 → 灰底/斜体
 * - 保持其余文本原样
 *
 * 用法：对 onDelta 的每个增量片段调用 process()，返回渲染后的 ANSI 字符串。
 */
public class MarkdownRender {
    private var boldOn: Bool = false
    private var inlineCodeOn: Bool = false
    private var codeBlockOn: Bool = false
    private var pendingStar: Bool = false   // 等下一个 * 确认 **
    private var pendingBacktick: Bool = false
    private var codeBlockStart: Bool = false  // 遇到 ``` 且还没确定

    public init() {}

    /**
     * 处理一个增量片段，返回带 ANSI 高亮的字符串
     *
     * 注意：必须用 toRuneArray() 迭代码点而非 for-in 迭代 String——
     * 仓颉 for-in 迭代 String 得 Byte，Rune(byte) 重建会把中文拆成
     * Latin-1 形态乱码（"你好"→"ä½\xa0å¥½"）
     */
    public func process(delta: String): String {
        var sb = StringBuilder()
        for (r in delta.toRuneArray()) {
            let s = r.toString()
            if (s == "*") {
                if (this.pendingStar) {
                    // ** 成对 → 切换粗体
                    this.boldOn = !this.boldOn
                    sb.append(if (this.boldOn) { Ansi.bold() } else { Ansi.reset() })
                    this.pendingStar = false
                } else {
                    this.pendingStar = true
                }
                continue
            }
            if (this.pendingStar) {
                // 单 * 是普通字符
                sb.append("*")
                this.pendingStar = false
            }
            if (s == "`") {
                // 三连 ` 是代码块，单 ` 是行内代码（简化：按连续个数切换）
                if (this.codeBlockStart) {
                    // ``` 闭合
                    this.codeBlockOn = !this.codeBlockOn
                    sb.append(Ansi.reset())
                    this.codeBlockStart = false
                } else if (this.pendingBacktick) {
                    // `` 可能是代码块开始
                    this.codeBlockStart = true
                    this.codeBlockOn = true
                    sb.append(Ansi.fg(Ansi.THEME_MUTED))
                    this.pendingBacktick = false
                } else {
                    this.pendingBacktick = true
                    // 先按行内代码处理，若下一帧是 ` 再转代码块
                    this.inlineCodeOn = !this.inlineCodeOn
                    sb.append(if (this.inlineCodeOn) { Ansi.fg(Ansi.THEME_ACCENT) } else { Ansi.reset() })
                }
                continue
            }
            if (this.pendingBacktick) {
                sb.append("`")
                this.pendingBacktick = false
            }
            sb.append(s)
        }
        return sb.toString()
    }

    /**
     * 流式结束时调用：关闭所有未闭合状态，返回收尾 ANSI
     */
    public func finish(): String {
        var sb = StringBuilder()
        if (this.codeBlockOn) {
            sb.append(Ansi.reset())
            this.codeBlockOn = false
        }
        if (this.inlineCodeOn) {
            sb.append(Ansi.reset())
            this.inlineCodeOn = false
        }
        if (this.boldOn) {
            sb.append(Ansi.reset())
            this.boldOn = false
        }
        return sb.toString()
    }
}
