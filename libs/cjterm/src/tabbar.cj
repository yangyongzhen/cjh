package cjterm

import std.collection.*

/**
 * TabBar：标签栏组件（可复用）
 *
 * - 标签列表（add/clear/setActive）+ 高亮渲染当前标签
 * - 左右方向键切换；Tab 键循环切换（非 Shift+Tab，单 Tab 前进）
 * - 鼠标点击标签行选中（需宿主启用鼠标模式并传入鼠标按键事件）
 * - 标签超宽时自动截断（canvas 行截断兜底）
 * - 消费按键：左右方向键 / Tab（返回 true）；其余不消费
 *
 * 用途：多视图切换（对话/设置/工具）、分组导航（可复用，不绑 agent 逻辑）。
 */
public class TabBar <: Component {
    private var tabs: ArrayList<String> = ArrayList<String>()
    private var active: Int64 = 0
    private var visible: Bool = true
    // 标签切换回调（参数为选中索引）
    public var onSelect: (Int64) -> Unit = { _ => }

    public init() {}

    public init(tabs: ArrayList<String>) {
        this.tabs = tabs
        this.active = 0
    }

    /**
     * 显示/隐藏标签栏
     */
    public func setVisible(v: Bool): Unit {
        this.visible = v
    }

    public func isVisible(): Bool {
        return this.visible
    }

    /**
     * 添加标签
     */
    public func add(label: String): Unit {
        this.tabs.add(label)
    }

    /**
     * 清空标签
     */
    public func clear(): Unit {
        this.tabs = ArrayList<String>()
        this.active = 0
    }

    /**
     * 设置标签列表（整体替换，保留越界修正）
     */
    public func setTabs(list: ArrayList<String>): Unit {
        this.tabs = list
        this.clampActive()
    }

    /**
     * 当前选中索引
     */
    public func activeIndex(): Int64 {
        return this.active
    }

    /**
     * 当前选中标签文本（无标签返回 ""）
     */
    public func current(): String {
        if (this.tabs.size == 0) {
            return ""
        }
        return this.tabs[this.active]
    }

    /**
     * 设置选中索引（越界修正并触发回调）
     */
    public func setActive(i: Int64): Unit {
        var idx = i
        if (this.tabs.size == 0) {
            idx = 0
        } else if (idx < 0) {
            idx = 0
        } else if (idx >= this.tabs.size) {
            idx = this.tabs.size - 1
        }
        if (idx != this.active) {
            this.active = idx
            this.onSelect(idx)
        }
    }

    /**
     * 切换到下一个标签（循环回绕）
     */
    public func next(): Unit {
        if (this.tabs.size == 0) {
            return
        }
        this.setActive((this.active + 1) % this.tabs.size)
    }

    /**
     * 切换到上一个标签（循环回绕）
     */
    public func prev(): Unit {
        if (this.tabs.size == 0) {
            return
        }
        let i = this.active - 1
        this.setActive(if (i < 0) { this.tabs.size - 1 } else { i })
    }

    public override func render(canvas: TuiCanvas, row: Int64, width: Int64, height: Int64): Int64 {
        if (!this.visible) {
            return 0
        }
        // 记录渲染行（供鼠标点击坐标换算）
        this.lastRenderRow = row
        var sb = StringBuilder()
        if (this.tabs.size == 0) {
            canvas.setLine(row, Ansi.fg(Ansi.THEME_MUTED) + "（无标签）" + Ansi.reset())
            return 1
        }
        for (i in 0..this.tabs.size) {
            let label = this.tabs[i]
            if (i == this.active) {
                // 选中：主题色底 + 黑字
                sb.append(Ansi.bg(Ansi.THEME_ACCENT) + Ansi.fg(Ansi.COLOR_BLACK) + " " + label + " " + Ansi.reset())
            } else {
                sb.append(Ansi.fg(Ansi.THEME_MUTED) + " " + label + " " + Ansi.reset())
            }
            // 标签间分隔
            if (i < this.tabs.size - 1) {
                sb.append(Ansi.fg(Ansi.THEME_MUTED) + "│" + Ansi.reset())
            }
        }
        canvas.setLine(row, sb.toString())
        return 1
    }

    public override func handleKey(key: KeyEvent): Bool {
        if (!this.visible || this.tabs.size == 0) {
            return false
        }
        // 左右方向键切换
        if (key.isArrowLeft) {
            this.prev()
            return true
        }
        if (key.isArrowRight) {
            this.next()
            return true
        }
        // Tab 前进循环
        if (key.isTab) {
            this.next()
            return true
        }
        // 鼠标点击：仅左键（0）命中本行（渲染行由宿主传入 render 时已记录）
        if (key.isMouse && key.mouseButton == 0 && key.mouseY == this.lastRenderRow + 1) {
            let col = key.mouseX  // 1-based
            // 用累积宽度命中标签：逐标签累加 " label " + 分隔符，定位点击落在哪个标签
            var acc: Int64 = 0
            for (i in 0..this.tabs.size) {
                let label = this.tabs[i]
                let w = this.runeCount(label) + 2  // 左右各一空格
                if (col >= acc + 1 && col <= acc + w) {
                    this.setActive(i)
                    return true
                }
                acc += w + 1  // 分隔符占 1 列
            }
            return true  // 命中标签行但未落在标签上：消费（不穿透）
        }
        return false
    }

    // 最近一次渲染的起始行（供鼠标点击坐标换算；0-based 存，点击时 +1 转 1-based）
    private var lastRenderRow: Int64 = -1

    /**
     * 码点数
     */
    private func runeCount(s: String): Int64 {
        var n: Int64 = 0
        for (_ in s.toRuneArray()) {
            n += 1
        }
        return n
    }

    private func clampActive(): Unit {
        if (this.tabs.size == 0) {
            this.active = 0
            return
        }
        if (this.active >= this.tabs.size) {
            this.active = this.tabs.size - 1
        }
        if (this.active < 0) {
            this.active = 0
        }
    }
}
