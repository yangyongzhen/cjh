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
    // 右侧提示（如滚动位置指示）：render 时附加在横线前，每帧由上层刷新
    private var rightHint: String = ""
    // 终端 UTF-8 能力（false 时上边框/横线降级 "+--"/"-"）：
    // v1.3.16 前硬编码 UTF-8，Windows 非 65001 代码页下与 logo ASCII 混排
    private var utf8: Bool = true

    public init() {}

    /**
     * 设置终端 UTF-8 能力（TuiApp 启动时接线）
     */
    public func setUtf8(v: Bool): Unit {
        this.utf8 = v
    }

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

    /**
     * 设置右侧提示（滚动指示等；空串不显示）
     */
    public func setRightHint(hint: String): Unit {
        this.rightHint = hint
    }

    public func current(): String {
        return this.text
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        let border = Ansi.fg(Ansi.THEME_BORDER)   // 边框实线色（244，U+2500 连续实线，P2b）
        let muted = Ansi.fg(Ansi.THEME_MUTED)
        let bx = BoxChars(this.utf8)
        let hc = bx.hc
        // 整行背景卡片（P2b，≈ omp statusLineBg #121212）：行内只用 fg 改色、禁止 reset
        //（reset 会清掉背景使卡片断裂），行尾 reset 由 padBg 统一补。
        let sep = muted + " > "
        // 分段 1：模型名（# accent 色）
        let modelPart = if (this.model.size > 0) {
            Ansi.fg(Ansi.THEME_ACCENT) + "# " + this.model + sep
        } else {
            ""
        }
        // 分段 2：当前工作目录（[cwd] muted，HOME 缩写为 ~）
        let dirPart = muted + "[ " + StatusBar.homeAbbrev(StatusBar.getCwd()) + " ]"
        // 分段 3：状态（ready 徽章或自定义文本；badge 内联无 reset 以保背景）
        let statusPart = if (this.text.size == 0) {
            Ansi.fg(Ansi.THEME_OK) + "* " + muted + "ready"
        } else {
            muted + this.text
        }
        // 提示文字（warn 色）
        let hintPart = if (this.rightHint.size > 0) {
            Ansi.fg(Ansi.THEME_WARN) + " " + this.rightHint
        } else {
            ""
        }
        let content = modelPart + dirPart + sep + statusPart + hintPart
        var sb = StringBuilder()
        // 上边框：utf8 ┌─ / ascii +--（边框 THEME_BORDER 244，整行铺 bg 234）
        sb.append(border + bx.stl + bx.hc + " " + content + border + " ")
        // 横线填充撑满到 width-1（truncate 保留 cols-1 可见，防终端折行的边距），
        // padBg 再铺整行 bg 234（可见宽度已 = width-1，padBg 不额外补空格）
        let used = TuiCanvas.displayWidth(sb.toString())
        var fillN = (width - 1) - used
        if (fillN < 0) {
            fillN = 0
        }
        var i: Int64 = 0
        while (i < fillN) {
            sb.append(hc)
            i += 1
        }
        canvas.setLine(row, Ansi.padBg(sb.toString(), width - 1, Ansi.THEME_STATUS_BG))
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
