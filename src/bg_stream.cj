package cjh

import cjh.tools.*

/**
 * 后台任务 → 会话流补记（面板退役后的可见性兜底）
 *
 * 背景：后台任务原先靠屏幕底部一块常驻紧凑条呈现。那块面板退役后，任务的
 * 起/停全靠会话流里的工具行（`● 标题` + `└ BashStart(...)`）承担——但工具行
 * 只覆盖"模型主动调用"的那些时刻：一个没人 bash_poll 的任务跑完了，流里就
 * 没有任何痕迹，用户只能去翻日志或猜。
 *
 * 所以这里给**终态事件**补一条流记录：状态 + 耗时 + 退出码。启动事件不补
 * （bash_start 的工具行已经写了），running 期间的耗时变化也不补（那会变成
 * 每秒一条的刷屏）。输出正文仍归 bash_poll 交付，补记只给"结论"。
 */

/**
 * 状态事件 → 补记文本（空串表示不补记）
 *
 * 只补终态：succeeded / failed / timeout / killed。running 返回空。
 */
public func bgStreamNotice(info: BgTaskEventInfo): String {
    let rawLabel = info.label.trimAscii()
    let label: String = if (rawLabel.size > 0) { rawLabel } else { info.taskId }
    let dur = fmtBgDuration(info.elapsedMs)
    match (info.state) {
        case BgSucceeded => return "✔ ${label} 完成 · ${dur}"
        case BgFailed => return "✘ ${label} 失败（exit ${info.exitCode}） · ${dur}"
        case BgTimedOut => return "⏱ ${label} 超时 · ${dur}"
        case BgKilled => return "⊘ ${label} 已取消"
        case BgRunning => return ""
    }
}

/**
 * 后台任务耗时的人类可读形式：`42s` / `1m02s` / `1h02m`
 *
 * 毫秒向下取整到秒——补记是结论行，不是秒表（面板当年要靠秒级的量刷心跳，
 * 这里不需要）。
 */
public func fmtBgDuration(ms: Int64): String {
    let t: Int64 = if (ms > 0) { ms / 1000 } else { 0 }
    if (t < 60) {
        return "${t}s"
    }
    if (t < 3600) {
        let m = t / 60
        let r = t % 60
        return if (r == 0) { "${m}m" } else { "${m}m${pad2(r)}s" }
    }
    let h = t / 3600
    let m = (t % 3600) / 60
    return if (m == 0) { "${h}h" } else { "${h}h${pad2(m)}m" }
}

/** 两位补零（1m02s 而不是 1m2s：等宽对齐，扫一眼不会看成 12s） */
private func pad2(n: Int64): String {
    return if (n < 10) { "0${n}" } else { "${n}" }
}
