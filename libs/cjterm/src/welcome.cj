package cjterm

import std.collection.*

/**
 * WelcomeView：启动欢迎视图（参考 omp 首次启动画面）
 *
 * 两栏边框布局：
 *   ╭─── cjh · Harness made by Cangjie ──────────────╮
 *   │   Welcome back!          │ Tips                │
 *   │     ▀████████             │ / 命令：/new /resume│
 *   │     ██▀▀▀▀▀▀             │ Tab/←→ 切换视图     │
 *   │     ██                    │ Ctrl+E 多行编辑     │
 *   │     ██▄▄▄▄▄▄             │ ────────────────    │
 *   │     ▄████████             │ Recent sessions    │
 *   │   ⬢ deepseek-v4-flash    │ • hello            │
 *   ╰──────────────────────────┴────────────────────╯
 *
 * 左栏：欢迎语 + CJ logo + 模型名；右栏：Tips + 最近会话。
 * 不消费按键（滚动等由其他组件处理）。
 */
public class WelcomeView <: Component {
    private var sessions: ArrayList<String> = ArrayList<String>()
    private var model: String = ""
    private var utf8: Bool = true

    public init() {}

    public init(utf8: Bool) {
        this.utf8 = utf8
    }

    /**
     * 设置最近会话摘要列表（• 前缀展示）
     */
    public func setSessions(list: ArrayList<String>): Unit {
        this.sessions = list
    }

    /**
     * 设置模型名（左栏展示）
     */
    public func setModel(name: String): Unit {
        this.model = name
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let tl = if (this.utf8) { "╭" } else { "+" }
        let tr = if (this.utf8) { "╮" } else { "+" }
        let bl = if (this.utf8) { "╰" } else { "+" }
        let br = if (this.utf8) { "╯" } else { "+" }
        let hc = if (this.utf8) { "─" } else { "-" }
        let vc = if (this.utf8) { "│" } else { "|" }
        let tc = if (this.utf8) { "┴" } else { "+" }

        // 统一弹窗宽度 boxW（铺满 width 列；setLine 按 cols-1 截断，width==cols 时刚好）
        let boxW = width
        // 两栏宽度：内容行结构 │ 左(leftW) │ 右(rightW) │
        //   总宽 = 1 + 1 + leftW + 1 + 1 + 1 + rightW + 1 + 1 = leftW + rightW + 7
        //   令总宽 = boxW - 1（留 1 列防 setLine 截断），则 rightW = boxW - 2 - leftW
        var leftW: Int64 = boxW * 38 / 100
        if (leftW < 24) {
            leftW = 24
        }
        var rightW = boxW - 2 - leftW
        if (rightW < 20) {
            rightW = 20
            leftW = boxW - 2 - rightW
            if (leftW < 10) {
                leftW = 10
            }
        }

        // 行 0：顶边框 + 标题（标题后填充横线到 boxW-1，再接 ╮）
        var top = StringBuilder()
        top.append(tl)
        top.append(hc)
        top.append(hc)
        top.append(hc)
        top.append(" ")
        top.append(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + "cjh · Harness made by Cangjie" + Ansi.reset())
        top.append("  " + Ansi.fg(Ansi.THEME_OK) + Logo.VERSION + Ansi.reset())
        top.append(" ")
        let topUsed = TuiCanvas.displayWidth(top.toString())   // 已构建部分可见宽度
        var topFill = boxW - 1 - topUsed   // 填充到 boxW-1，留 1 列给 ╮
        if (topFill < 0) {
            topFill = 0
        }
        var tfi: Int64 = 0
        while (tfi < topFill) {
            top.append(hc)
            tfi += 1
        }
        top.append(tr)
        canvas.setLine(row, top.toString())

        // 左右栏内容行集合（每行可含 ANSI）
        let leftLines = this.leftLines()
        let rightLines = this.rightLines()
        let maxRows = if (leftLines.size > rightLines.size) { leftLines.size } else { rightLines.size }
        let contentH = height - 2
        let rows = if (maxRows < contentH) { maxRows } else { contentH }

        for (i in 0..rows) {
            let left = if (i < leftLines.size) { leftLines[i] } else { "" }
            let right = if (i < rightLines.size) { rightLines[i] } else { "" }
            // 内容行总宽 = leftW + rightW + 7，令其 = boxW - 1（与顶边框对齐）
            var sb = StringBuilder()
            sb.append(vc)
            sb.append(" ")
            sb.append(WelcomeView.padRight(left, leftW))
            sb.append(" ")
            sb.append(vc)
            sb.append(" ")
            sb.append(WelcomeView.padRight(right, rightW))
            sb.append(" ")
            sb.append(vc)
            canvas.setLine(row + 1 + i, sb.toString())
        }

        // 底边框：╰────┴────╯（总宽 = boxW-1，与顶边框对齐）
        var bottom = StringBuilder()
        bottom.append(bl)
        // 左栏段：leftW + 2 列横线
        var bli: Int64 = 0
        while (bli < leftW + 2) {
            bottom.append(hc)
            bli += 1
        }
        bottom.append(tc)
        // 右栏段：rightW + 2 列横线
        var bri: Int64 = 0
        while (bri < rightW + 2) {
            bottom.append(hc)
            bri += 1
        }
        bottom.append(br)
        canvas.setLine(row + 1 + rows, bottom.toString())

        return rows + 2
    }

    /**
     * 左栏内容：欢迎语 + CJ logo（5 行）+ 模型名
     */
    private func leftLines(): ArrayList<String> {
        let lines = ArrayList<String>()
        lines.add("")
        lines.add(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + "Welcome back!" + Ansi.reset())
        lines.add("")
        let logo = Logo.renderLinesModern(this.utf8)
        for (l in logo) {
            lines.add(l)
        }
        lines.add("")
        let modelLine = if (this.model.size > 0) {
            Ansi.fg(Ansi.THEME_ACCENT) + "⬢ " + this.model + Ansi.reset()
        } else {
            ""
        }
        lines.add(modelLine)
        return lines
    }

    /**
     * 右栏内容：Tips + 分隔线 + Recent sessions
     */
    private func rightLines(): ArrayList<String> {
        let lines = ArrayList<String>()
        lines.add(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + "Tips" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  / 命令：/new /resume /model /help" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Tab / ←→   切换视图（对话/帮助）" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+E      多行输入编辑" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Alt+Enter   多行编辑提交" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  y / n       审批弹窗确认/取消" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  ────────────────────────" + Ansi.reset())
        lines.add(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + "Recent sessions" + Ansi.reset())
        if (this.sessions.size == 0) {
            lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  • 暂无历史会话" + Ansi.reset())
        } else {
            // 最多展示 6 条
            let maxShow = if (this.sessions.size > 6) { 6 } else { this.sessions.size }
            for (i in 0..maxShow) {
                lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  • " + this.sessions[i] + Ansi.reset())
            }
        }
        lines.add("")
        return lines
    }

    /**
     * 右填充空格到指定显示宽度（ANSI 感知：转义序列不计宽）
     */
    private static func padRight(s: String, w: Int64): String {
        let cur = TuiCanvas.displayWidth(s)
        if (cur >= w) {
            return s
        }
        var sb = StringBuilder()
        sb.append(s)
        for (_ in 0..(w - cur)) {
            sb.append(" ")
        }
        return sb.toString()
    }

    public override func handleKey(key: KeyEvent): Bool {
        return false
    }
}
