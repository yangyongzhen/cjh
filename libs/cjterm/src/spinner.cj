package cjterm

/**
 * Spinner：加载指示器组件（帧动画，可复用）
 *
 * - 帧序列：UTF-8 终端用 braille 转圈（⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏），
 *   非 UTF-8 降级 |/-\（对齐 Logo/TuiCanvas 的降级策略）
 * - tick() 推进一帧；render() 渲染 "帧 + 文案"
 * - 不消费按键（纯展示组件）
 *
 * 用法（宿主每帧）：
 *   if (busy) { spinner.tick(); spinner.render(canvas, row, cols, 1) }
 */
public class Spinner <: Component {
    private static let FRAMES_UTF8: Array<String> = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]
    private static let FRAMES_ASCII: Array<String> = ["|", "/", "-", "\\"]

    private var frames: Array<String> = Spinner.FRAMES_ASCII
    private var index: Int64 = 0
    private var label: String = ""

    public init() {}

    public init(utf8: Bool, label: String) {
        this.frames = if (utf8) { Spinner.FRAMES_UTF8 } else { Spinner.FRAMES_ASCII }
        this.label = label
    }

    /**
     * 设置文案（如 "思考中…"）
     */
    public func setLabel(l: String): Unit {
        this.label = l
    }

    /**
     * 当前帧字符
     */
    public func frame(): String {
        return this.frames[this.index]
    }

    /**
     * 推进到下一帧（到末尾回绕）
     */
    public func tick(): Unit {
        this.index += 1
        if (this.index >= this.frames.size) {
            this.index = 0
        }
    }

    /**
     * 回到第一帧
     */
    public func reset(): Unit {
        this.index = 0
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        canvas.setLine(row, Ansi.fg(Ansi.THEME_ACCENT) + this.frame() + " " + this.label + Ansi.reset())
        return 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        return false
    }
}
