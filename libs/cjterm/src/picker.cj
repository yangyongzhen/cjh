package cjterm

import std.collection.*

/**
 * 列表选择器组件（可复用）：候选列表 + 方向键选择 + 高亮当前项。
 *
 * 参考 omp TUI 思路：组件只负责"内容模型 + 选中态"，渲染交给上层
 * （上层通过差分渲染只重绘变化行）。本组件用于 / 命令下拉补全、
 * 模型切换列表等场景。
 */
public class ListPicker {
    private var items: ArrayList<String> = ArrayList<String>()
    private var selected: Int64 = 0
    private var visible: Bool = false

    public init() {}

    /**
     * 显示候选列表（光标默认指向首项）
     */
    public func show(list: ArrayList<String>): Unit {
        this.items = list
        this.selected = 0
        this.visible = (this.items.size > 0)
    }

    /**
     * 隐藏下拉框
     */
    public func hide(): Unit {
        this.visible = false
        this.items = ArrayList<String>()
    }

    public func isVisible(): Bool {
        return this.visible
    }

    public func size(): Int64 {
        return this.items.size
    }

    /**
     * 当前选中索引（-1 表示无可选项）
     */
    public func selectedIndex(): Int64 {
        if (!this.visible || this.items.size == 0) {
            return -1
        }
        return this.selected
    }

    /**
     * 当前选中项文本（无可选项返回 ""）
     */
    public func current(): String {
        if (!this.visible || this.items.size == 0) {
            return ""
        }
        return this.items[this.selected]
    }

    /**
     * 光标下移（循环到底部回绕）
     */
    public func next(): Unit {
        if (this.items.size == 0) {
            return
        }
        this.selected += 1
        if (this.selected >= this.items.size) {
            this.selected = 0
        }
    }

    /**
     * 光标上移（循环到顶部回绕）
     */
    public func prev(): Unit {
        if (this.items.size == 0) {
            return
        }
        this.selected -= 1
        if (this.selected < 0) {
            this.selected = this.items.size - 1
        }
    }

    /**
     * 渲染下拉框行数组（每行已着色，选中项高亮），最大 maxRows 行。
     * 返回的数组长度固定为 maxRows，空项为 ""（由上层决定绘制位置）
     */
    public func render(maxRows: Int64): Array<String> {
        var out = Array<String>(maxRows, repeat: "")
        if (!this.visible || this.items.size == 0) {
            return out
        }
        // 滚动窗口：确保选中项可见
        var start = 0
        if (this.selected >= maxRows) {
            start = this.selected - maxRows + 1
        }
        var n: Int64 = 0
        while (n < maxRows) {
            let idx = start + n
            if (idx >= this.items.size) {
                break
            }
            let text = this.items[idx]
            if (idx == this.selected) {
                out[n] = Ansi.bg(Ansi.THEME_ACCENT) + Ansi.fg(Ansi.COLOR_BLACK) +
                    "❯ " + text + Ansi.reset()
            } else {
                out[n] = Ansi.fg(Ansi.THEME_MUTED) + "  " + text + Ansi.reset()
            }
            n += 1
        }
        return out
    }
}
