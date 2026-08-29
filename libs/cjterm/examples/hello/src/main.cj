// cjterm 最小示例：raw 模式读键 + 差分渲染画布
//
// 运行：cjpm run  （在 examples/hello 目录，依赖 cjterm 源码路径）
package hello

import cjterm.*
import std.collection.*
import std.time.*

func drawFrame(term: Term, n: Int64): Unit {
    let (rows, cols) = TermSize.get()
    if (rows < 5) {
        return
    }
    let canvas = TuiCanvas()
    // 首帧/尺寸变化时 sizeChanged=true 强制全量重绘
    canvas.begin(rows, cols, term.sizeChanged())
    // 标题行
    canvas.setLine(0, Ansi.fg(Ansi.THEME_ACCENT) + "cjterm demo · ${n} frames" + Ansi.reset())
    // 分隔线（全宽）
    var sep = ""
    for (i in 0..cols) {
        sep += "─"
    }
    canvas.setLine(1, Ansi.fg(Ansi.THEME_MUTED) + sep + Ansi.reset())
    // 状态行
    canvas.setLine(rows - 1, Ansi.fg(Ansi.THEME_MUTED) + "q/Ctrl+C 退出 · 窗口缩放实时重排" + Ansi.reset())
    print(canvas.flush(), flush: true)
}

main(): Int64 {
    let term = Term()
    term.enableRaw()
    print(Ansi.clearScreen(), flush: true)
    print(Ansi.hideCursor(), flush: true)
    var n: Int64 = 0
    while (true) {
        drawFrame(term, n)
        n += 1
        // 非阻塞读键
        if (let Some(k) <- term.readKey()) {
            if (k.isCtrlC || (k.ch == 113 && !k.isEsc)) {  // Ctrl+C 或 q
                break
            }
        }
        sleep(Duration.millisecond * 16)
    }
    print(Ansi.showCursor(), flush: true)
    term.disableRaw()
    return 0
}
