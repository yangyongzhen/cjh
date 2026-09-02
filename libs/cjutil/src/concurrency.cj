package cjutil

import std.time.*

/**
 * 预算竞速结果载体：持有任务返回值或任务异常（runWithBudget 内部使用）
 */
class BudgetOutcome<T> {
    public var value: ?T = None
    public var error: ?Exception = None
}

/**
 * 操作超预算被放弃（网络停滞 / 目标不可达 / 写黑洞）
 */
public class BudgetTimeoutException <: Exception {
    public init(label: String, budgetMs: Int64) {
        super("${label} 超预算（${budgetMs}ms 无响应）")
    }
}

/**
 * 操作被中断（用户 Ctrl+C / 空闲看门狗）
 */
public class BudgetCancelledException <: Exception {
    public init(label: String) {
        super("${label} 被中断")
    }
}

/**
 * 预算竞速：spawn 子任务执行 task，主线程每 pollMs 轮询结果并检查 isCancelled，
 * 超 budgetMs 立即抛 BudgetTimeoutException 放弃子任务。
 *
 * 背景（2026-09-02 Thinking 442s 事故）：仓颉裸 socket 的 connect/write 没有超时参数——
 * TcpSocket.connect（含 DNS 解析）/ TLS 握手 / write 都可能无限阻塞；abort() 的 close()
 * 也打不断 connect（this.socket 在 connect 返回后才赋值，挂死期间为 None，abort 空转）。
 * 首个请求一旦卡死，整个回合永久挂起、所有中断全部失效。
 * 本原语把任意"可能无限阻塞"的阶段变成有界、可中断的阶段。
 *
 * 语义（探针实测验证）：
 *   - task 正常 → 返回其值（T=Unit 亦支持）
 *   - task 抛异常 → 原样重抛（rethrow，不包装）
 *   - 超预算 → BudgetTimeoutException（子任务被放弃，线程待内核 unblock 后自行回收）
 *   - isCancelled() 为 true → BudgetCancelledException（≤pollMs 内生效）
 *
 * 注意：task 内不得让未捕获异常逃出（本原语已用载体收住）——否则仓颉运行时会
 * 额外向 stderr 打印异常报告，污染 TUI 输入框（与 stdx.net.http readTimer WARN 同源）。
 *
 * @param label 阶段名（错误信息用，如 "connect" / "写请求"）
 * @param budgetMs 总预算（毫秒）
 * @param pollMs 轮询间隔（毫秒，同时是中断响应延迟）
 * @param isCancelled 中断检查（每轮轮询开头调用）
 * @param task 要执行的任务（在 spawn 子任务中运行）
 */
public func runWithBudget<T>(label: String, budgetMs: Int64, pollMs: Int64, isCancelled: () -> Bool, task: () -> T): T {
    let box = BudgetOutcome<T>()
    let fut: Future<Unit> = spawn {
        try {
            box.value = Some(task())
        } catch (e: Exception) {
            box.error = Some(e)
        }
    }
    let start = DateTime.now()
    while (box.error.isNone() && box.value.isNone()) {
        if (isCancelled()) {
            throw BudgetCancelledException(label)
        }
        try {
            fut.get(Duration.millisecond * pollMs)
        } catch (e: TimeoutException) {
            // poll 超时：正常路径，继续下一轮（预算/取消检查在循环内）
        }
        if ((DateTime.now() - start).toMilliseconds() > budgetMs) {
            throw BudgetTimeoutException(label, budgetMs)
        }
    }
    if (box.error.isSome()) {
        throw box.error.getOrThrow()
    }
    return box.value.getOrThrow()
}
