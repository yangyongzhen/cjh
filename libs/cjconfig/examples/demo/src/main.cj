// cjconfig 最小示例：三层配置（默认/文件/环境变量）+ 模板生成 + 保留用户字段
package cfg_demo

import cjconfig.*
import stdx.encoding.json.*

main(): Int64 {
    // 1. 声明字段（独立演示目录）
    let cfg = ConfigStore("cfg_demo", "/tmp/cjconfig_demo")
    cfg.defineStr("model", "gpt-4o-mini", "CFG_DEMO_MODEL", "LLM 模型")
    cfg.defineInt("max_iters", 10, "CFG_DEMO_MAX_ITERS", "最大迭代")
    cfg.defineBool("verbose", false, "", "详细输出")
    cfg.load()

    println("默认 model: ${cfg.getStr("model")}")
    println("默认 max_iters: ${cfg.getInt("max_iters")}")

    // 2. 环境变量覆盖（不设置则用默认；可 export CFG_DEMO_MODEL=xxx 覆盖）
    println("env 覆盖后 model: ${cfg.getStr("model")}")

    // 3. 修改 + 保存（首次自动生成模板）
    cfg.setStr("model", "deepseek-chat")
    cfg.setInt("max_iters", 50)
    cfg.save()
    println("已保存: ${cfg.configPath()}")

    // 4. 重新加载验证持久化
    let cfg2 = ConfigStore("cfg_demo", "/tmp/cjconfig_demo")
    cfg2.defineStr("model", "gpt-4o-mini", "", "LLM 模型")
    cfg2.defineInt("max_iters", 10, "", "最大迭代")
    cfg2.load()
    println("重新加载 model: ${cfg2.getStr("model")}, max_iters: ${cfg2.getInt("max_iters")}")
    return 0
}
