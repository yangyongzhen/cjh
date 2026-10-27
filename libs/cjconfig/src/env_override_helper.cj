package cjconfig

/**
 * 测试辅助：环境变量覆盖用例的平台差异（文件级函数才允许加 @When——
 * `@TestCase` 方法上加 @When 会被 Test 宏拒绝："unexpected conditional compilation directive"）。
 *
 * POSIX：用 libc setenv 真设环境变量，返回期望值；
 * Windows：无 setenv，返回哨兵值（wantIters < 0），调用方据此跳过 env 段——
 * 该路径由 Linux 侧门禁覆盖，不在这里假装通过。
 */
@When[os != "Windows"]
func envOverrideValues(): (String, Int64) {
    setEnvForTest("CJCONFIG_TEST_MODEL", "deepseek-chat")
    setEnvForTest("CJCONFIG_TEST_ITERS", "42")
    return ("deepseek-chat", 42)
}

@When[os == "Windows"]
func envOverrideValues(): (String, Int64) {
    return ("", -1)
}
