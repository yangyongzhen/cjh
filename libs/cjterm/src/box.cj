package cjterm

/**
 * Box：带边框的布局容器组件（可复用）
 *
 * - 边框：UTF-8 box-drawing（╭╮╰╯─│），非 UTF-8 降级 ASCII（+-+-|）
 * - 标题：左上角内嵌（可空），右侧填充补足
 * - 内嵌子组件：render 时先画边框，再在内容区（去掉顶/底边框 + 左右内边距）
 *   委托子组件渲染（子组件返回行数即内容高度）
 * - 鼠标点击边框区域：消费不穿透（容器语义）
 * - 消费按键：委托给内嵌子组件；子组件不消费时也不穿透（容器为焦点边界）
 *
 * 用途：面板分组、对话框外壳、布局分区（可复用，不绑 agent 逻辑）。
 */
public class Box <: Component {
    private var title: String = ""
    private var utf8: Bool = true
    // 内嵌子组件（可为 None：纯装饰性面板）
    private var child: Option<Component> = None
    // 左右内边距（边框内侧留白列数）
    private var padX: Int64 = 1
    // 标题是否加粗着色（默认主题色）
    private var titleStyled: Bool = true

    public init() {}

    public init(utf8: Bool) {
        this.utf8 = utf8
    }

    public init(title: String, utf8: Bool) {
        this.title = title
        this.utf8 = utf8
    }

    /**
     * 设置标题（空串不显示）
     */
    public func setTitle(t: String): Unit {
        this.title = t
    }

    /**
     * 设置内嵌子组件
     */
    public func setChild(c: Component): Unit {
        this.child = Some(c)
    }

    /**
     * 清空内嵌子组件
     */
    public func clearChild(): Unit {
        this.child = None
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        // 边框字符
        let tl = if (this.utf8) { "╭" } else { "+" }
        let tr = if (this.utf8) { "╮" } else { "+" }
        let bl = if (this.utf8) { "╰" } else { "+" }
        let br = if (this.utf8) { "╯" } else { "+" }
        let hc = if (this.utf8) { "─" } else { "-" }
        let vc = if (this.utf8) { "│" } else { "|" }

        // 标题行（左上角）
        var top = StringBuilder()
        top.append(tl)
        top.append(hc)
        if (this.title.size > 0) {
            top.append(" ")
            if (this.titleStyled) {
                top.append(Ansi.fg(Ansi.THEME_ACCENT) + Ansi.bold() + this.title + Ansi.reset())
            } else {
                top.append(this.title)
            }
            top.append(" ")
        }
        // 补齐标题行剩余边框（按可见标题宽度近似，canvas 截断兜底）
        top.append(this.fill(hc, width - 1 - this.visibleTitleWidth() - (if (this.title.size > 0) { 2 } else { 0 })))
        top.append(tr)
        canvas.setLine(row, top.toString())

        // 内容区：顶边框下一行起，height-2 行（底部留边框行）
        let innerH = height - 2
        if (let Some(c) <- this.child) {
            let used = c.render(canvas, row + 1 + 1, width - 2 * (this.padX + 1), innerH - 1)
            // 子组件内容未填满时，补空白内容行（含左右边框）
            var r: Int64 = used
            while (r < innerH - 1) {
                canvas.setLine(row + 1 + r, vc + this.fill(" ", width - 2) + vc)
                r += 1
            }
        } else {
            // 无子组件：空内容行
            var r: Int64 = 0
            while (r < innerH - 1) {
                canvas.setLine(row + 1 + r, vc + this.fill(" ", width - 2) + vc)
                r += 1
            }
        }

        // 底边框
        canvas.setLine(row + height - 1, bl + this.fill(hc, width - 2) + br)
        return height
    }

    public override func handleKey(key: KeyEvent): Bool {
        // 委托内嵌子组件；子组件未消费时也不穿透（容器是焦点边界）
        if (let Some(c) <- this.child) {
            return c.handleKey(key)
        }
        return true
    }

    /**
     * 标题可见宽度（码点数；含着色视为原始标题长度，近似值）
     */
    private func visibleTitleWidth(): Int64 {
        var n: Int64 = 0
        for (_ in this.title.toRuneArray()) {
            n += 1
        }
        return n
    }

    /**
     * 重复字符填充（n 为负数时返回空串）
     */
    private func fill(ch: String, n: Int64): String {
        if (n <= 0) {
            return ""
        }
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < n) {
            sb.append(ch)
            i += 1
        }
        return sb.toString()
    }
}
