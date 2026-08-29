// cjcfg 最小示例：配置读取 + 工作区管理（使用隔离的演示目录）
//
// 说明：配置加载用默认目录（~/.cjh，首次自动生成模板）；
// 工作区操作用独立目录 /tmp/cjh_cfg_demo，不影响真实配置。
package cfg_demo

import cjcfg.*

main(): Int64 {
    // 1. 配置加载（首次自动生成 settings.json/auth.json 模板）
    let cfg = CjhConfig()
    println("model: ${cfg.model}")
    println("baseUrl: ${cfg.baseUrl}")
    println("configDir: ${cfg.configDir}")

    // 2. 工作区 CRUD + 最近访问排序 + 持久化（独立目录演示）
    let ws = WorkspaceManager("/tmp/cjh_cfg_demo")
    ws.add("/home/user/proj-a", "proj-a")
    ws.add("/home/user/proj-b", "")
    ws.touch("/home/user/proj-a")   // 更新最近访问
    ws.save()
    let list = ws.list()
    println("工作区数: ${list.size}（最近访问优先）")
    for (w in list) {
        println("  ${w.name} @ ${w.path}")
    }

    // 3. 跨平台主目录（Windows USERPROFILE / POSIX HOME）
    println("homeDir: ${EnvFfi.homeDir()}")

    // 4. 重新加载验证持久化（新实例从磁盘读）
    let ws2 = WorkspaceManager("/tmp/cjh_cfg_demo")
    println("重新加载后工作区数: ${ws2.list().size}")
    return 0
}
