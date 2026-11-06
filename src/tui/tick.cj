package cjh.tui

/**
 * 每秒节拍判据（agent 心跳计时 / 后台面板淡出共用）。
 *
 * 契约：一个锚点**只判一次**秒，判到点后在**同一分支内**驱动所有按秒逻辑。
 *
 * 反例（曾经的真实 bug，2026-11-06 用户实测）：TuiApp 主循环里心跳分支先
 * `lastTick = now`，面板分支紧接着又拿同一个 lastTick 判
 * `(nowBg - lastTick).toSeconds() >= 1` → 恒得 0 秒 ⇒ `bgPanel.tick()` 一次
 * 都不执行 ⇒ 终态任务永不淡出、面板一直挂着已结束任务（现象："已结束的后台
 * 任务槽位没有自动释放"）。用户连发三次 bash_start（三次完整回合、agent 全程
 * 忙）时 100% 复现。
 *
 * @param nowSec 当前时刻（unix 秒）
 * @param lastSec 上次驱动的时刻（unix 秒）
 * @return true = 到点，调用方应立即把锚点推进到 nowSec
 */
public func secondElapsed(nowSec: Int64, lastSec: Int64): Bool {
    return nowSec - lastSec >= 1
}
