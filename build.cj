import std.process.*
import std.fs.*
import std.console.*

/**
 * cjpm 构建钩子（官方扩展点，与 cjpm.toml 同级）
 *
 * 背景：cjpm 1.0.5 的可执行产物名固定为 `main`（`[package]` 无 bin-name 字段，
 * 配置了也会被静默忽略）。本脚本在 post-build 阶段把产物复制为 `cjh`，
 * 满足"最终可执行文件名为 cjh"。
 *
 * 注意：
 * - cjpm build/test/bench 都会触发 post-build；test 阶段不产 main，需跳过（否则 cp 失败中止命令）
 * - `--skip-script` 可跳过构建脚本
 */
func stagePostBuild(): Int64 {
    // cjpm 1.0.5 可执行产物固定名为 main；post-build 复制为 cjh。
    // 仅当 main 存在时复制（test 阶段不产 main，跳过避免中止命令）
    if (!exists("target/release/bin/main")) {
        return 0
    }
    var args = Array<String>(3, repeat: "")
    args[0] = "-f"
    args[1] = "target/release/bin/main"
    args[2] = "target/release/bin/cjh"
    let (code, _, err) = executeWithOutput("cp", args)
    if (code != 0) {
        println("build.cj: cp main -> cjh failed: ${err}")
        return code
    }
    println("build.cj: 可执行文件 target/release/bin/cjh 已生成")
    return 0
}

main(): Int64 {
    match (Process.current.arguments[0]) {
        case "post-build" => stagePostBuild()
        case _ => 0
    }
}
