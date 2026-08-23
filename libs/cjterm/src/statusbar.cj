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
        let sep = Ansi.fg(Ansi.THEME_MUTED) + " > " + Ansi.reset()
        let muted = Ansi.fg(Ansi.THEME_MUTED)
        let border = Ansi.fg(Ansi.COLOR_BLUE)
        let hc = "-"
        // 分段 1：模型名（# accent 色；ASCII 宽度恒定 1 列）
        let modelPart = if (this.model.size > 0) {
            Ansi.fg(Ansi.THEME_ACCENT) + "# " + this.model + Ansi.reset() + sep
        } else {
            ""
        }
        // 分段 2：当前工作目录（[cwd] muted，HOME 缩写为 ~；避免 📁 等 emoji 宽度歧义）
        let dirPart = Ansi.fg(Ansi.THEME_MUTED) + "[ " + StatusBar.homeAbbrev(StatusBar.getCwd()) + " ]" + Ansi.reset()
        // 分段 3：状态（ready 徽章或自定义文本）
        let statusPart = if (this.text.size == 0) {
            Logo.badge("ready", Ansi.THEME_OK)
        } else {
            this.text
        }
        // ASCII 上边框：+-- 内容 ->------+（边框蓝色醒目，标识输入框位置）
        let content = modelPart + dirPart + sep + statusPart
        var sb = StringBuilder()
        sb.append(border + "+-- " + Ansi.reset())
        sb.append(content)
        sb.append(border + " ->" + Ansi.reset())
        // 右侧横线填充：used + fillN + 1(+) 必须 ≤ cols-1（truncate 上限）
        let used = TuiCanvas.displayWidth(sb.toString())
        var fillN = width - used - 2
        if (fillN < 0) {
            fillN = 0
        }
        sb.append(border)
        var i: Int64 = 0
        while (i < fillN) {
            sb.append(hc)
            i += 1
        }
        sb.append("+" + Ansi.reset())
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
