package cjh.tests

import std.collection.*
import std.sync.*
import stdx.encoding.json.*
import cjcfg.*
import cjllm.*
import cjh.gateway.*
import cjh.tools.*
import cjh.web.*

/**
 * WS 审批通道单元测试（客户端约定 #6）
 *
 * 覆盖：同意 → 工具真执行；拒绝 → 工具拿到拒绝结果且回合照常收尾；
 *       超时 → 按拒绝收场并明确回 approval_timeout；
 *       未知 / 缺 request_id → 结构化错误（不静默）；
 *       回合等审批时取消 → 立刻按拒绝放行（不必空等满超时）。
 *
 * 全部通过渠道收到的事件断言（observable 契约），不触碰私有实现。
 */

/**
 * 第一轮发一个 read_file 调用的 provider 替身
 *
 * 用 read_file 而不是 bash 触发审批：bash 会同时命中工具域与命令域（两次审批），
 * 而资源域（fs）审批只命中路径检查——一次调用恰好一个审批请求，断言才干净。
 */
public class ReadCallProvider <: LlmProvider {
    private let path: String
    public var calls: Int64 = 0

    public init(path: String) {
        this.path = path
    }

    public func chatStream(_: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        onDelta: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        _: () -> Bool): ModelResponse {
        this.calls += 1
        if (this.calls == 1) {
            var args = JsonObject()
            args.put("path", JsonString(this.path))
            var list = ArrayList<ToolCall>()
            list.add(ToolCall("call_read", "read_file", args))
            return ModelResponse("我先读一下文件。", list)
        }
        return ModelResponse("读完了。", ArrayList<ToolCall>())
    }
}

/**
 * 造一个「恰好一次审批」的严格模式配置：
 *   tools 放行 read_file → 工具域 Allow（不审批）
 *   approval=["fs"] + 空 fsAllow → 路径域命中审批规则（一次审批）
 */
func approvalConfig(): CjhConfig {
    let cfg = CjhConfig()
    cfg.systemPrompt = "审批通道测试"
    cfg.maxIterations = 3
    cfg.capability.enabled = true
    cfg.capability.tools.add("read_file")
    cfg.capability.approval.add("fs")
    return cfg
}

/**
 * 字节级子串查找（不额外依赖 String API；中文按 UTF-8 字节序列同样正确）
 */
func approvalTextHas(text: String, needle: String): Bool {
    let t = text.toArray()
    let n = needle.toArray()
    if (n.size == 0 || t.size < n.size) {
        return false
    }
    for (i in 0..(t.size - n.size + 1)) {
        var hit = true
        for (j in 0..n.size) {
            if (t[i + j] != n[j]) {
                hit = false
                break
            }
        }
        if (hit) {
            return true
        }
    }
    return false
}

/**
 * 等条件成立（测试用；到期返回最后一次判定结果，交由断言报错）
 */
func approvalWaitUntil(cond: () -> Bool, timeoutMs: Int64): Bool {
    var waited: Int64 = 0
    while (waited < timeoutMs) {
        if (cond()) {
            return true
        }
        sleep(Duration.millisecond * 10)
        waited += 10
    }
    return cond()
}

/**
 * 搭一个带审批能力的网关与渠道（含一个真实存在的待读文件）
 */
func buildApprovalGateway(dir: String, timeoutMs: Int64): (ChannelGateway, CaptureChannel) {
    let path = dir + "/target.txt"
    writeTextFile(path, "cjh-approval-marker\n")
    let registry = ToolRegistry()
    registry.register(ReadTool())
    let gateway = ChannelGateway(approvalConfig(), ReadCallProvider(path), registry,
        Some(StubProviderFactory("")))
    gateway.approvalTimeoutMs = timeoutMs
    let ch = CaptureChannel()
    gateway.registerChannel("test", ch)
    return (gateway, ch)
}

@Test
public class ApprovalChannelTest {

    @TestCase
    public func testApproveLetsToolRun(): Unit {
        let dir = testTempDir("gw_approval_allow")
        let (gateway, ch) = buildApprovalGateway(dir, 8000)
        gateway.handleUserMessage("test", "chat1", "读一下文件", None)

        // 回合停在审批上：渠道收到审批请求，且此时还没有 done
        @Assert(approvalWaitUntil({ => ch.approvals.size > 0 }, 5000), true)
        @Assert(ch.approvals.size, 1)
        @Assert(ch.dones, 0)
        let info = ch.approvals[0]
        @Assert(info.toolName, "read_file")
        @Assert(info.requestId.size > 0, true)
        @Assert(info.meta.turnId.size > 0, true)
        @Assert(info.expiresInMs, 8000)

        gateway.handleApprovalResponse("test", "chat1", info.requestId, true)
        @Assert(approvalWaitUntil({ => ch.dones > 0 }, 8000), true)
        @Assert(ch.doneReasons[0], "stop")
        @Assert(ch.errors.size, 0)
        // 同意后工具真的执行了：读到文件内容，且不是错误结果
        @Assert(ch.toolResultErrors.size > 0, true)
        @Assert(ch.toolResultErrors[0], false)
        @Assert(approvalTextHas(ch.toolResultTexts[0], "cjh-approval-marker"), true)
    }

    @TestCase
    public func testDenyKeepsTurnAliveWithRefusal(): Unit {
        let dir = testTempDir("gw_approval_deny")
        let (gateway, ch) = buildApprovalGateway(dir, 8000)
        gateway.handleUserMessage("test", "chat1", "读一下文件", None)
        @Assert(approvalWaitUntil({ => ch.approvals.size > 0 }, 5000), true)

        gateway.handleApprovalResponse("test", "chat1", ch.approvals[0].requestId, false)
        @Assert(approvalWaitUntil({ => ch.dones > 0 }, 8000), true)
        // 拒绝不等于回合失败：工具拿到拒绝结果，回合正常收尾（stop）
        @Assert(ch.doneReasons[0], "stop")
        @Assert(ch.toolResultErrors[0], true)
        @Assert(approvalTextHas(ch.toolResultTexts[0], "操作被用户拒绝"), true)
        // 有人明确拒绝了，就不该再报超时
        @Assert(ch.errors.size, 0)
    }

    @TestCase
    public func testTimeoutDeniesAndReportsCode(): Unit {
        let dir = testTempDir("gw_approval_timeout")
        let (gateway, ch) = buildApprovalGateway(dir, 400)
        gateway.handleUserMessage("test", "chat1", "读一下文件", None)
        // 谁也没答复：到期必须自己收场，并把原因如实报出来
        @Assert(approvalWaitUntil({ => ch.dones > 0 }, 8000), true)
        @Assert(ch.approvals.size, 1)
        @Assert(ch.toolResultErrors[0], true)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "approval_timeout")
    }

    @TestCase
    public func testUnknownApprovalIdIsNotSilent(): Unit {
        let dir = testTempDir("gw_approval_unknown")
        let (gateway, ch) = buildApprovalGateway(dir, 8000)
        // 没有未决请求时答复：回结构化错误，而不是静默丢掉
        gateway.handleApprovalResponse("test", "chat1", "s1#t9#a9", true)
        @Assert(ch.errors.size, 1)
        @Assert(ch.errors[0].code, "approval_unknown")

        gateway.handleApprovalResponse("test", "chat1", "", true)
        @Assert(ch.errors.size, 2)
        @Assert(ch.errors[1].code, "approval_bad_request")
    }

    @TestCase
    public func testCancelReleasesApprovalImmediately(): Unit {
        let dir = testTempDir("gw_approval_cancel")
        // 超时给 30s：若取消没能唤醒等待中的审批，本用例会等到超时才收场（即失败）
        let (gateway, ch) = buildApprovalGateway(dir, 30000)
        gateway.handleUserMessage("test", "chat1", "读一下文件", None)
        @Assert(approvalWaitUntil({ => ch.approvals.size > 0 }, 5000), true)

        gateway.handleCancel("test", "chat1", "")
        @Assert(ch.cancelleds.size, 1)
        @Assert(ch.cancelleds[0].wasRunning, true)

        // 3s 内收场（远小于 30s 超时）→ 证明取消真的把审批按拒绝放行了
        @Assert(approvalWaitUntil({ => ch.dones > 0 }, 3000), true)
        @Assert(ch.doneReasons[0], "cancelled")
        @Assert(ch.toolResultErrors[0], true)
    }

    @TestCase
    public func testApprovalRequestJsonShape(): Unit {
        // 帧形状固定：客户端据 request_id 回传、据 args 展示"到底要动什么"
        var args = JsonObject()
        args.put("path", JsonString("/tmp/secret.txt"))
        let ev = ApprovalRequestEvent("s1#t1#a1", "read_file", args, "文件操作需人工确认")
        ev.meta = FrameMeta("s1", "s1#t1", "s1#t1#m1")
        ev.expiresInMs = 300000

        let p = JsonValue.fromStr(ev.toJson()).asObject()
        @Assert(getStr(p, "type"), "approval_request")
        @Assert(getStr(p, "request_id"), "s1#t1#a1")
        @Assert(getStr(p, "tool"), "read_file")
        @Assert(getStr(p, "reason"), "文件操作需人工确认")
        @Assert(getInt(p, "expires_in_ms"), 300000)
        @Assert(getStr(p, "session_id"), "s1")
        @Assert(getStr(p, "turn_id"), "s1#t1")
        @Assert(getStr(p, "message_id"), "s1#t1#m1")
        match (p.get("args")) {
            case Some(v) => @Assert(getStr(v.asObject(), "path"), "/tmp/secret.txt")
            case None => @Assert("args 缺失", "")
        }
    }
}
