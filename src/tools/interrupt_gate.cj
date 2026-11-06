package cjh.tools

import std.sync.*

/**
 * 中断门：跨线程共享"已请求中断"信号。
 *
 * 为什么需要它：用户 Ctrl+C / TUI 看门狗只把 `Agent.interruptFlag` 置位，而工具执行
 * 期间没有任何人查询这个标志 —— 工具在跑（bash 长命令、`find` 遍历大目录、web_fetch）
 * 时中断要等工具自己返回才生效。实测（2026-11-06 15:52）：两个工具（bash + glob）开始
 * 执行后 181s 无返回，看门狗在 15:55:09 打出"已请求中断"，随后日志再无一行、回合
 * 从未结束，用户只能强退。
 *
 * 用法：Agent.interrupt() 置位、Agent.run 入口清零；工具在自己的等待循环（如
 * BashSession 每 50ms 轮询一次）里调用 `requested()`，命中即立刻杀掉子进程并返回。
 */
public class InterruptGate {
    private static let flag: AtomicInt64 = AtomicInt64(0)

    public static func request(): Unit {
        flag.store(1)
    }

    public static func clear(): Unit {
        flag.store(0)
    }

    public static func requested(): Bool {
        flag.load() != 0
    }
}
