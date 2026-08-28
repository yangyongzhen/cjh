package cjterm

/**
 * 通用列表选择组件
 *
 * 封装 TUI 中"上下箭头选择 + Enter 确认 + Esc 取消"的交互模式。
 * 参照 ConfirmDialog 的封装模式：visible 控制显示，handleKey 处理按键，
 * onSelect/onCancel 回调返回结果，paint 渲染列表 + 高亮选中项。
 *
 * 用法：
 *   let sel = ListSelect()
 *   sel.title = "选择会话"
 *   sel.items = ["会话1 (3 msgs)", "会话2 (5 msgs)", ...]
 *   sel.onSelect = { idx => /* 用户选中第 idx 项 */ }
 *   sel.onCancel = { => /* 用户按 Esc 取消 */ }
 *   sel.show()
 *   // 在按键处理里：
 *   if (sel.visible) { sel.handleKey(key); ... }
 *   // 在渲染里：
 *   sel.paint(canvas, row, width, height)
 */

import std.collection.ArrayList

/**
 * 列表选择按键处理结果
 */
public enum ListSelectResult {
    | Ignored    // 未消费按键
    | Moved      // 选中项移动（上下箭头/PageUp/PageDown）
    | Selected   // 按 Enter，选中当前项
    | Cancelled  // 按 Esc 取消
}

public class ListSelect {
    // ===== 状态 =====
    public var visible: Bool = false
    public var title: String = "选择"
    public var items: ArrayList<String> = ArrayList<String>()
    public var selectedIndex: Int64 = 0
    public var scrollOffset: Int64 = 0   // 列表滚动偏移
    public var maxVisible: Int64 = 20    // 最多显示行数

    // ===== 回调 =====
    public var onSelect: ?(Int64) -> Unit = None    // 选中回调（参数=选中索引）
    public var onCancel: ?() -> Unit = None         // 取消回调

    /**
     * 显示列表选择
     * @param items 列表项文本
     * @param title 标题（显示在列表顶部）
     * @param initial 初始选中项索引（默认 0）
     */
    public func show(items: ArrayList<String>, title: String, initial: Int64): Unit {
        this.items = items
        this.title = title
        this.selectedIndex = initial
        this.scrollOffset = 0
        this.visible = true
    }

    /**
     * 隐藏列表选择
     */
    public func hide(): Unit {
        this.visible = false
        this.items = ArrayList<String>()
        this.selectedIndex = 0
        this.scrollOffset = 0
    }

    /**
     * 处理按键
     * @return ListSelectResult 描述按键处理结果
     */
    public func handleKey(key: KeyEvent): ListSelectResult {
        if (!this.visible) { return ListSelectResult.Ignored }

        // 上下箭头：移动选中项
        if (key.isArrowUp) {
            if (this.selectedIndex > 0) {
                this.selectedIndex -= 1
                this.adjustScroll()
                return ListSelectResult.Moved
            }
            return ListSelectResult.Ignored
        }
        if (key.isArrowDown) {
            if (this.selectedIndex < this.items.size - 1) {
                this.selectedIndex += 1
                this.adjustScroll()
                return ListSelectResult.Moved
            }
            return ListSelectResult.Ignored
        }

        // PageUp/PageDown：翻页移动
        if (key.isPageUp) {
            let newPos = this.selectedIndex - this.maxVisible
            this.selectedIndex = if (newPos < 0) { 0 } else { newPos }
            this.adjustScroll()
            return ListSelectResult.Moved
        }
        if (key.isPageDown) {
            let newPos = this.selectedIndex + this.maxVisible
            let maxIdx = this.items.size - 1
            this.selectedIndex = if (newPos > maxIdx) { maxIdx } else { newPos }
            this.adjustScroll()
            return ListSelectResult.Moved
        }

        // Enter：选中当前项
        if (key.isEnter) {
            let idx = this.selectedIndex
            this.hide()
            match (this.onSelect) {
                case Some(cb) => cb(idx)
                case None => ()
            }
            return ListSelectResult.Selected
        }

        // Esc：取消
        if (key.escapeSeq == TermEsc.ESC) {
            this.hide()
            match (this.onCancel) {
                case Some(cb) => cb()
                case None => ()
            }
            return ListSelectResult.Cancelled
        }

        // 其他键不处理
        return ListSelectResult.Ignored
    }

    /**
     * 调整滚动偏移，确保选中项可见
     */
    private func adjustScroll(): Unit {
        // 选中项在可视区域下方：滚动到选中项在底部
        if (this.selectedIndex >= this.scrollOffset + this.maxVisible) {
            this.scrollOffset = this.selectedIndex - this.maxVisible + 1
        }
        // 选中项在可视区域上方：滚动到选中项在顶部
        if (this.selectedIndex < this.scrollOffset) {
            this.scrollOffset = this.selectedIndex
        }
        // 不能为负
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }
    }

    /**
     * 渲染列表选择
     *
     * @param lines 已有渲染行列表（追加到末尾）
     * @param width 可用宽度
     * @return 渲染行数
     */
    public func paint(lines: ArrayList<String>, width: Int64): Int64 {
        if (!this.visible) { return 0 }
        if (this.items.size == 0) {
            lines.add(this.styleTitle(width))
            lines.add("  (空列表)")
            return 2
        }

        // 标题行
        lines.add(this.styleTitle(width))

        // 列表项
        let maxIdx = this.items.size - 1
        let startIdx = this.scrollOffset
        let endIdx = startIdx + this.maxVisible - 1
        let actualEnd = if (endIdx > maxIdx) { maxIdx } else { endIdx }

        for (i in startIdx..actualEnd + 1) {
            let item = this.items[i]
            let isSelected = (i == this.selectedIndex)

            // 截断超长项
            let maxItemWidth = width - 6   // 留 " ▸ " + 序号
            var displayItem = item
            if (displayItem.size > maxItemWidth) {
                displayItem = displayItem[0..maxItemWidth]
            }

            // 选中项高亮（反色）
            if (isSelected) {
                let line = " " + Ansi.esc() + "[7m▸ ${displayItem}" + Ansi.esc() + "[0m"
                lines.add(line)
            } else {
                let line = "   ${displayItem}"
                lines.add(line)
            }
        }

        // 底部提示行
        lines.add("  ↑↓ 选择 · Enter 确认 · Esc 取消")

        // 计算渲染行数
        let itemCount = actualEnd - startIdx + 1
        return 1 + itemCount + 1   // 标题 + 列表项 + 提示
    }

    /**
     * 渲染列表选择到 TuiCanvas（零胶水接入 TuiApp 主渲染管线）
     *
     * @param canvas TuiCanvas（setLine 写指定行）
     * @param startRow 起始行（0-based）
     * @param cols 可用列宽
     * @param maxRows 最多可用行数（含标题/提示）；超出部分由内部滚动处理
     * @return 实际占用行数（0 表示不可见）
     */
    public func paintCanvas(canvas: TuiCanvas, startRow: Int64, cols: Int64, maxRows: Int64): Int64 {
        if (!this.visible) { return 0 }
        if (maxRows < 2) { return 0 }   // 至少要 1 标题 + 1 提示

        // 根据 maxRows 动态调整 maxVisible，确保标题+列表+提示不溢出
        // 可见列表行 = maxRows - 2（标题1 + 提示1）
        let listLines = maxRows - 2
        if (listLines < 1) { return 0 }

        // 选中项移出可视区域时，先调整滚动偏移
        //（与 adjustScroll 类似，但可视高度按本次 maxRows 计算）
        if (this.selectedIndex > this.scrollOffset + listLines - 1) {
            this.scrollOffset = this.selectedIndex - listLines + 1
        }
        if (this.selectedIndex < this.scrollOffset) {
            this.scrollOffset = this.selectedIndex
        }
        if (this.scrollOffset < 0) {
            this.scrollOffset = 0
        }

        var row = startRow

        // 标题行
        canvas.setLine(row, this.styleTitle(cols))
        row += 1

        // 空列表
        if (this.items.size == 0) {
            canvas.setLine(row, "  (空列表)")
            return 2
        }

        // 列表项
        let maxIdx = this.items.size - 1
        let startIdx = this.scrollOffset
        let endIdx = startIdx + listLines - 1
        let actualEnd = if (endIdx > maxIdx) { maxIdx } else { endIdx }

        let maxItemWidth = cols - 6   // 留 " ▸ " + 序号
        for (i in startIdx..actualEnd + 1) {
            let item = this.items[i]
            let isSelected = (i == this.selectedIndex)

            var displayItem = item
            if (displayItem.size > maxItemWidth) {
                displayItem = displayItem[0..maxItemWidth]
            }

            if (isSelected) {
                let line = " " + Ansi.esc() + "[7m▸ ${displayItem}" + Ansi.esc() + "[0m"
                canvas.setLine(row, line)
            } else {
                let line = "   ${displayItem}"
                canvas.setLine(row, line)
            }
            row += 1
        }

        // 底部提示行
        canvas.setLine(row, "  ↑↓ 选择 · Enter 确认 · Esc 取消")
        row += 1

        // 实际占用行数 = 标题1 + 列表项数 + 提示1
        let used = 1 + (actualEnd - startIdx + 1) + 1
        return used
    }

    /**
     * 渲染标题行（带下划线）
     */
    private func styleTitle(width: Int64): String {
        return Ansi.esc() + "[1;4m ${this.title}" + Ansi.esc() + "[0m"
    }
}
