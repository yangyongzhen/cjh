// cjlog 最小示例：级别日志 + 异步落盘 + 异常堆栈
package logdemo

import cjlog.*
import std.convert.Parsable

main(): Int64 {
    Log.info("cjlog demo 启动")
    Log.warn("配置缺失，使用默认值")
    Log.debug("debug 消息（需 CJH_LOG_LEVEL=DEBUG 才落盘）")
    try {
        let v = Int64.parse("abc")
        println(v)
    } catch (e: Exception) {
        Log.error("解析失败", e)
    }
    Log.shutdown()
    println("完成：cjh.log / error.log 已写入当前目录")
    return 0
}
