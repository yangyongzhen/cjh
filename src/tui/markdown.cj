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
 *
 * 反引号状态机（v2，修复三连代码块失效）：
 * 连续反引号先累积计数（跨帧保留），遇到非反引号字符时统一 flush：
 *   count >= 3 → 代码块开/关切换
 *   count 1-2  → 行内代码开/关切换
 * 旧实现逐字符处理，第 2 个反引号就开代码块、第 3 个立即关闭，
 * ``` 代码块渲染完全失效且 inlineCodeOn 状态残留。
 */
public class MarkdownRender {
    private var boldOn: Bool = false
    private var inlineCodeOn: Bool = false
    private var codeBlockOn: Bool = false
    private var pendingStar: Bool = false      // 等下一个 * 确认 **
    private var tickCount: Int64 = 0           // 未决反引号计数（跨帧累积，遇非反引号 flush）

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
            if (s == "`") {
                // 累积反引号，不立即输出（需等序列结束才知道是行内还是代码块）
                this.tickCount += 1
                continue
            }
            // 遇到非反引号：先 flush 累积的反引号
            this.flushTicks(sb)
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
            sb.append(s)
        }
        return sb.toString()
    }

    /**
     * 处理累积的反引号：>=3 切代码块，1-2 切行内代码
     */
    private func flushTicks(sb: StringBuilder): Unit {
        if (this.tickCount == 0) {
            return
        }
        if (this.tickCount >= 3) {
            this.codeBlockOn = !this.codeBlockOn
            sb.append(if (this.codeBlockOn) { Ansi.fg(Ansi.THEME_MUTED) } else { Ansi.reset() })
        } else {
            this.inlineCodeOn = !this.inlineCodeOn
            sb.append(if (this.inlineCodeOn) { Ansi.fg(Ansi.THEME_ACCENT) } else { Ansi.reset() })
        }
        this.tickCount = 0
    }

    /**
     * 流式结束时调用：flush 未决反引号 + 关闭所有未闭合状态，返回收尾 ANSI
     */
    public func finish(): String {
        var sb = StringBuilder()
        this.flushTicks(sb)
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
