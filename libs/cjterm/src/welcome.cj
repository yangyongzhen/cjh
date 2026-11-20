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
     * 更新终端 UTF-8 能力（TuiApp 启动接线：Windows enableRaw 切换控制台代码页
     * 晚于组件构造，构造时初值可能过时）
     */
    public func setUtf8(v: Bool): Unit {
        this.utf8 = v
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

        // 统一弹窗宽度 boxW：留 1 列防 setLine 截断（width==cols 时最后一列写不进去）
        let boxW = if (width > 1) { width - 1 } else { width }
        // 两栏宽度：内容行结构 │ 左(leftW) │ 右(rightW) │
        //   总宽 = 1 + 1 + leftW + 1 + 1 + 1 + rightW + 1 + 1 = leftW + rightW + 7
        //   令总宽 = boxW，则 rightW = boxW - 7 - leftW。
        // 旧式 rightW = boxW - 2 - leftW 少减 5，内容行/底边比顶边宽 5 列，
        // 被 setLine 截断后右边框缺失、中间分隔竖线错位（用户截图实锤）。
        // 窄终端（boxW < 51）放弃 24/20 的最小列宽，按比例分栏：
        // 旧实现硬保最小宽，内容行总宽超过 boxW，右边框被 setLine 截掉。
        let narrow = boxW < 51
        var leftW: Int64 = boxW * 38 / 100
        let minLeft: Int64 = if (narrow) { 1 } else { 24 }
        let minRight: Int64 = if (narrow) { 1 } else { 20 }
        if (leftW < minLeft) {
            leftW = minLeft
        }
        var rightW = boxW - 7 - leftW
        if (rightW < minRight) {
            rightW = minRight
            leftW = boxW - 7 - rightW
        }
        if (leftW < 1) {
            leftW = 1
        }
        if (rightW < 1) {
            rightW = 1
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
        let greet = if (this.sessions.size > 0) { "Welcome back!" } else { "Welcome!" }
        lines.add(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + greet + Ansi.reset())
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
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Ctrl+O      展开/折叠工具明细" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  Alt+Enter   多行编辑提交" + Ansi.reset())
        lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  y / n       审批弹窗确认/取消" + Ansi.reset())
        // 无历史会话时整块隐藏：分隔线 + 标题 + “暂无”三行纯噪声，挤掉 Tips
        if (this.sessions.size > 0) {
            lines.add(Ansi.fg(Ansi.THEME_MUTED) + "  ────────────────────────" + Ansi.reset())
            lines.add(Ansi.bold() + Ansi.fg(Ansi.THEME_ACCENT) + "Recent sessions" + Ansi.reset())
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
        if (cur == w) {
            return s
        }
        // 超宽必须裁到 w：旧实现原样返回，内容行比边框宽，setLine 截断后
        // 右边框被吃掉；截断处补 reset 防止颜色泄漏到后续空格/边框。
        // 宽字符放不下时 truncate 会提前停，仍要补空格到目标宽度。
        let base = if (cur > w) { TuiCanvas.truncateText(s, w) + Ansi.reset() } else { s }
        let baseCur = TuiCanvas.displayWidth(base)
        if (baseCur >= w) {
            return base
        }
        var sb = StringBuilder()
        sb.append(base)
        for (_ in 0..(w - baseCur)) {
            sb.append(" ")
        }
        return sb.toString()
    }

    public override func handleKey(_: KeyEvent): Bool {
        return false
    }
}
