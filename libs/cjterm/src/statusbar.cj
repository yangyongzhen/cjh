package cjterm

import std.env.*

/**
 * StatusBar：底部状态行组件（参考 omp 分段式状态栏）
 *
 * 分段布局：⬢ 模型  ›  📁 cwd  ›  ● 状态
 * - 模型名 accent 色（setModel 设置）
 * - 当前工作目录 muted 色（📁 前缀，HOME 缩写为 ~）
 * - 状态文本（setStatus）；为空时回退显示 "ready" 徽章
 * - 分段用 muted 的 › 分隔（对齐 omp 的 > 分隔风格）
 * - 不消费按键（滚动等由其他组件处理）
 */
public class StatusBar <: Component {
    private var text: String = ""
    private var model: String = ""

    public init() {}

    /**
     * 设置状态文本（空串显示默认徽章）
     */
    public func setStatus(t: String): Unit {
        this.text = t
    }

    /**
     * 设置模型名（状态栏分段显示）
     */
    public func setModel(name: String): Unit {
        this.model = name
    }

    public func current(): String {
        return this.text
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let sep = Ansi.fg(Ansi.THEME_MUTED) + " › " + Ansi.reset()
        // 分段 1：模型名（⬢ accent 色）
        let modelPart = if (this.model.size > 0) {
            Ansi.fg(Ansi.THEME_ACCENT) + "⬢ " + this.model + Ansi.reset() + sep
        } else {
            ""
        }
        // 分段 2：当前工作目录（📁 muted，HOME 缩写为 ~）
        let dirPart = Ansi.fg(Ansi.THEME_MUTED) + "📁 " + StatusBar.homeAbbrev(StatusBar.getCwd()) + Ansi.reset()
        // 分段 3：状态（ready 徽章或自定义文本）
        let statusPart = if (this.text.size == 0) {
            Logo.badge("ready", Ansi.THEME_OK)
        } else {
            this.text
        }
        // omp 风格上边框：╭── 内容 ─▶────╮（内容靠左，右侧 ▶ 指示 + 圆角收尾）
        let content = modelPart + dirPart + sep + statusPart
        let contentW = TuiCanvas.displayWidth(content)
        var sb = StringBuilder()
        sb.append(Ansi.fg(Ansi.THEME_MUTED))
        sb.append("╭── ")
        sb.append(Ansi.reset())
        sb.append(content)
        sb.append(Ansi.fg(Ansi.THEME_MUTED))
        sb.append(" ─▶")
        let fillN = width - 8 - contentW
        if (fillN > 0) {
            for (_ in 0..fillN) {
                sb.append("─")
            }
        }
        sb.append("╮")
        sb.append(Ansi.reset())
        canvas.setLine(row, sb.toString())
        return 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        return false
    }

    /**
     * 当前工作目录（std.env，返回 Path，转 String）
     */
    private static func getCwd(): String {
        try {
            return getWorkingDirectory().toString()
        } catch (e: Exception) {
            return ""
        }
    }

    /**
     * HOME 缩写：/home/user/x → ~/x（参考 omp 状态栏的 📁 路径显示）
     */
    private static func homeAbbrev(path: String): String {
        if (path.size == 0) {
            return path
        }
        try {
            let home = getHomeDirectory().toString()
            if (home.size > 0 && path.startsWith(home)) {
                let tail = path[home.size..path.size]
                return "~" + tail
            }
        } catch (e: Exception) {
            ()
        }
        return path
    }
}
