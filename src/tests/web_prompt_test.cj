package cjh.tests

import cjutil.*
import std.collection.*
import std.sync.*
import cjllm.*
import cjcfg.*
import cjh.agent.*
import cjh.tools.*
import cjh.gateway.*

/**
 * Web 入口提示词注入（issue #16）：
 *   1. 网关建会话必须用 promptBuilder 组装的提示词，而不是 config.systemPrompt 原值
 *   2. 未注入时保持旧行为
 *   3. 热刷新：在线空闲会话立即换装；回合运行中的会话延到下一回合开始前换装
 */

/**
 * 记录每次 chatStream 收到的 system 消息；release=false 时阻塞，模拟回合运行中。
 * 用 Mutex 保护，避免测试线程与 agent 线程的读写不同步。
 */
class PromptCaptureProvider <: LlmProvider {
    private let lock = Mutex()
    private let prompts: ArrayList<String> = ArrayList<String>()
    private var releaseFlag: Bool = false

    public func setRelease(v: Bool): Unit {
        this.lock.lock()
        try {
            this.releaseFlag = v
        } finally {
            this.lock.unlock()
        }
    }

    public func promptCount(): Int64 {
        this.lock.lock()
        try {
            return Int64(this.prompts.size)
        } finally {
            this.lock.unlock()
        }
    }

    public func promptAt(i: Int64): String {
        this.lock.lock()
        try {
            return this.prompts[i]
        } finally {
            this.lock.unlock()
        }
    }

    public func chatStream(messages: ArrayList<ChatMessage>, _: ArrayList<ToolSpec>,
        _: (String) -> Unit, _: (String) -> Unit, _: (Int64) -> Unit,
        _: () -> Bool): ModelResponse {
        this.lock.lock()
        try {
            this.prompts.add(messages[0].content)
        } finally {
            this.lock.unlock()
        }
        while (true) {
            this.lock.lock()
            let done = this.releaseFlag
            this.lock.unlock()
            if (done) {
                break
            }
            sleep(Duration.millisecond * 10)
        }
        return ModelResponse("ok", ArrayList<ToolCall>())
    }
}

func promptTestConfig(): CjhConfig {
    let cfg = CjhConfig()
    cfg.systemPrompt = "BASE-ONLY-7788"
    cfg.maxIterations = 3
    return cfg
}

func promptWaitUntil(cond: () -> Bool, timeoutMs: Int64): Bool {
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

@Test
public class WebPromptInjectionTest {

    @TestCase
    public func testWebSessionUsesComposedPrompt(): Unit {
        let cfg = promptTestConfig()
        let gateway = ChannelGateway(cfg, MockProvider(tmpPath("cjh_ut_web_prompt_mock.txt")),
            ToolRegistry(), None)
        gateway.promptBuilder = Some({ => "BASE-ONLY-7788\n\n## Available skills\nMARKER-SKILL-BODY-7788" })
        let agent = gateway.createSession("web", "c1")
        let hist = agent.history()
        @Assert(hist.size > 0, true)
        @Assert(hist[0].role, "system")
        @Assert(hist[0].content.contains("MARKER-SKILL-BODY-7788"), true)
    }

    @TestCase
    public func testWithoutBuilderKeepsBasePrompt(): Unit {
        let cfg = promptTestConfig()
        let gateway = ChannelGateway(cfg, MockProvider(tmpPath("cjh_ut_web_prompt_mock2.txt")),
            ToolRegistry(), None)
        let agent = gateway.createSession("web", "c1")
        @Assert(agent.history()[0].content, "BASE-ONLY-7788")
    }

    @TestCase
    public func testReloadRefreshesIdleSessions(): Unit {
        let cfg = promptTestConfig()
        let gateway = ChannelGateway(cfg, MockProvider(tmpPath("cjh_ut_web_prompt_mock3.txt")),
            ToolRegistry(), None)
        let body = ArrayList<String>()
        body.add("V1")
        gateway.promptBuilder = Some({ => body[0] })
        let a = gateway.createSession("web", "c1")
        let b = gateway.createSession("web", "c2")
        @Assert(a.history()[0].content, "V1")
        body[0] = "V2-MARKER-7788"
        let (refreshed, chars) = gateway.refreshSystemPrompts()
        @Assert(refreshed, 2)
        @Assert(chars, Int64("V2-MARKER-7788".size))
        @Assert(a.history()[0].content, "V2-MARKER-7788")
        @Assert(b.history()[0].content, "V2-MARKER-7788")
        // 新建会话同样拿新内容
        let c = gateway.createSession("web", "c3")
        @Assert(c.history()[0].content, "V2-MARKER-7788")
    }

    @TestCase
    public func testReloadWithoutBuilderReportsUnavailable(): Unit {
        let cfg = promptTestConfig()
        let gateway = ChannelGateway(cfg, MockProvider(tmpPath("cjh_ut_web_prompt_mock4.txt")),
            ToolRegistry(), None)
        let (refreshed, chars) = gateway.refreshSystemPrompts()
        @Assert(refreshed, -1)
        @Assert(chars, 0)
    }

    @TestCase
    public func testRefreshDuringRunDefersToNextRound(): Unit {
        let provider = PromptCaptureProvider()
        let agent = Agent(provider, ToolRegistry(),
            AgentConfig("BASE-ONLY-7788", 3, Capability(), 0, 0, 2, 6000, "", "prompt-refresh"))
        let done = ArrayList<Bool>()
        done.add(false)
        spawn {
            try {
                let _ = agent.run("first")
            } finally {
                done[0] = true
            }
        }
        @Assert(promptWaitUntil({ => provider.promptCount() == 1 }, 5000), true)
        // 回合运行中刷新：本轮 prompt 不变，下一轮生效
        agent.refreshSystemPrompt("MID-RUN-V2-7788")
        @Assert(provider.promptAt(0), "BASE-ONLY-7788")
        provider.setRelease(true)
        @Assert(promptWaitUntil({ => done[0] }, 5000), true)

        // 第二回合：换装后的提示词
        provider.setRelease(false)
        done[0] = false
        spawn {
            try {
                let _ = agent.run("second")
            } finally {
                done[0] = true
            }
        }
        @Assert(promptWaitUntil({ => provider.promptCount() == 2 }, 5000), true)
        @Assert(provider.promptAt(1), "MID-RUN-V2-7788")
        provider.setRelease(true)
        @Assert(promptWaitUntil({ => done[0] }, 5000), true)
    }
}
