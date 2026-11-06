package cjh.tests

import std.time.*
import cjh.tools.*
import cjh.web.*

/**
 * Web 侧后台任务收割（v7 槽位账）
 *
 * Web 入口没有 TUI 那种每秒节拍：任务终态若没人 `bash_poll`，就只能靠「推账时点
 * 顺手收割」反映到面板上。这里钉住这条路径——推一次账，任务状态就必须跟上。
 */
@Test
public class WebBgHarvestTest {
    @TestCase
    public func testPushSlotsHarvestsTerminalState(): Unit {
        let dir = testTempDir("web_bg_harvest")
        let reg = BackgroundTaskRegistry(BgTaskConfig(8, 600000, 64, 0), dir)
        setCurrentBackgroundRegistry(reg)
        try {
            let r = reg.start("echo web-harvest", "web", "", "/bin/bash", true, 0, 0)
            @Assert(r.ok, true)
            // 刻意不调 poll / kill：Web 侧唯一的收割入口就是推账时点
            sleep(Duration.millisecond * 800)
            // 无连接时 pushSlots 只做收割就返回，正好是最需要它的场景
            BgTaskBroadcaster().pushSlots()
            match (reg.find(r.taskId)) {
                case Some(t) =>
                    @Assert(t.state().wire(), "succeeded")
                    @Assert(t.exitCode(), 0)
                case None =>
                    // 刚起的任务必定在表里：查不到说明登记路径坏了
                    @Assert("present", "missing")
            }
        } finally {
            reg.killAll()
            // 全局注册表没有"清空"接口，换一份空表，避免污染后续用例
            setCurrentBackgroundRegistry(BackgroundTaskRegistry(BgTaskConfig(8, 600000, 64, 0), dir))
            removeTree(dir)
        }
    }
}
