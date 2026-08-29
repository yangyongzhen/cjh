package cjh.agent

import std.fs.*
import cjlog.*

/**
 * 工具结果截断器（对标 Pi spill extension）
 *
 * 从 Agent 私有方法提取为公共类，便于单元测试（曾因零测试覆盖导致
 * 截断逻辑 6000/8000 阈值错乱等 bug 潜伏）。
 *
 * 设计：
 * - 超过阈值的工具结果保留头尾 + 中间省略标记
 * - 完整结果落盘到 spillDir/<sessionId>/<toolCallId>.txt
 * - 省略标记包含落盘文件路径（回溯钥匙），模型可用 read_file 按需读回
 */
public class ToolResultTruncator {

    /**
     * 工具差异化截断阈值（对标 Pi v0.13.2）
     * @param configMax 全局配置阈值（0 或负数 = 禁用截断）
     */
    public static func maxChars(toolName: String, configMax: Int64): Int64 {
        // 全局禁用截断（0 或负数）→ 返回一个大数，等价于不截断
        if (configMax <= 0) {
            return Int64.Max
        }
        match (toolName) {
            // bash 输出（构建/测试/搜索）经常很长，占 prompt 大头；2000 字符激进截断，
            // 完整结果仍落盘 spillDir，模型可用 read_file 回溯，信息不丢
            case "bash" => 2000
            case "list_dir" => 4000
            // read_file 是按需读取工具，LLM 已通过 offset/limit 控制读取量；
            // 截断会导致 LLM 看到不完整内容，反复重读，浪费轮次
            case "read_file" => Int64.Max
            case _ => configMax
        }
    }

    /**
     * 截断 + 落盘 + 回溯钥匙
     * @return 截断后的内容（未超阈值时原样返回）
     */
    public static func truncate(content: String, toolName: String, configMax: Int64,
        spillDir: String, sessionId: String, toolCallId: String): String {
        let maxChars = ToolResultTruncator.maxChars(toolName, configMax)
        // 按 Rune（字符）计数，避免按字节切片截断在多字节 UTF-8 中间
        let runes = content.toRuneArray()
        let charCount = Int64(runes.size)
        if (maxChars <= 0 || charCount <= maxChars) {
            return content
        }
        let headLen: Int64 = maxChars / 2
        let tailLen: Int64 = maxChars - headLen
        var headSb = StringBuilder()
        for (i in 0..Int64(headLen)) {
            headSb.append(String(runes[i]))
        }
        let tailStart = charCount - tailLen
        var tailSb = StringBuilder()
        for (i in Int64(tailStart)..charCount) {
            tailSb.append(String(runes[i]))
        }
        let skipped = charCount - maxChars

        // 落盘完整结果（回溯路径）
        var spillHint = ""
        if (spillDir.size > 0 && sessionId.size > 0) {
            let path = spillDir + "/" + sessionId + "/" + toolCallId + ".txt"
            writeSpill(path, content)
            spillHint = "，完整结果已保存：" + path + "，可用 read_file 读取"
        }
        return headSb.toString()
            + "\n\n…[已截断 " + skipped.toString() + " 字符" + spillHint + "]…\n\n"
            + tailSb.toString()
    }

    /**
     * 落盘写入完整工具结果
     */
    private static func writeSpill(path: String, content: String): Unit {
        try {
            // 从完整路径里取出目录部分（最后一次 "/" 之前）
            match (path.lastIndexOf("/")) {
                case Some(dirEnd) =>
                    let dir = path[0..dirEnd]
                    if (!exists(dir)) {
                        Directory.create(dir, recursive: true)
                    }
                case None => ()
            }
            File.writeTo(path, content.toArray())
        } catch (e: Exception) {
            Log.warn("spill 落盘失败: ${e}")
            // 落盘失败不影响截断本身，只是丢了回溯路径
        }
    }
}
