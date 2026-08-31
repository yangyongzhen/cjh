package cjh.tui

import cjterm.*

main(): Int64 {
    let m = MarkdownRender()
    let f1 = m.process("```python\n")
    let f2 = m.process("def foo(x):\n")
    let f3 = m.process("    return x + 42\n")
    let f4 = m.process("```")
    let tail = m.finish()
    eprintln("[dbg] f1='${f1}' f2='${f2}' f3='${f3}' f4='${f4}' tail='${tail}'")
    return 0
}
