package cjterm

import std.time.*

/**
 * 时钟抽象（v1.3.24）
 *
 * 动机：粘贴流守护窗口（PASTE_ENTER_GUARD_MS）与到达速率窗口都是"时间判定"，
 * 而 v1.3.21/v1.3.23 两次修复都因"用真实计时在 CI 里模拟真机投递节奏"而漏判
 * （单测用 sleep 构造的节奏与 Windows Terminal 实测不一致）。把时间源抽出来，
 * 单测注入虚拟时钟即可确定性验证，不再依赖真实等待与机器速度差异。
 */
public interface Clock {
    func now(): DateTime
}

/** 生产时钟：系统墙钟 */
public class SystemClock <: Clock {
    public init() {}

    public func now(): DateTime {
        return DateTime.now()
    }
}
