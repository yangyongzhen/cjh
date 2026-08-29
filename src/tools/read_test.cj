package cjh.tools

import std.collection.*
import stdx.encoding.json.*
import std.fs.*
import std.process.*
import cjllm.ToolSpec

/**
 * 删除文件辅助函数（仓颉 File.remove 签名不匹配，用 bash rm -f）
 */
func rmFile(path: String): Unit {
    var args = Array<String>(3, repeat: "")
    args[0] = "-c"
    args[1] = "rm -f '" + path + "'"
    let _ = executeWithOutput("/bin/bash", args)
}

/**
 * ReadTool 单元测试
 * 覆盖三种模式：小文件全文、大文件默认 200 行、offset+limit 分段
 * 验证：行号格式 <N>\t<content>、截断提示、重复读提示
 */
@Test
public class ReadToolTest {

    @TestCase
    public func testSmallFileFullContent(): Unit {
        // 创建小文件（< 200 行）
        let path = "/tmp/cjh_read_test_small.txt"
        let content = "line1\nline2\nline3\n"
        File.writeTo(path, content.toArray())

        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        let result = tool.execute(args)

        @Assert(result.isError, false)
        // 验证行号前缀格式：<N>\t<content>
        @Assert(result.content.contains("1\tline1"), true)
        @Assert(result.content.contains("2\tline2"), true)
        @Assert(result.content.contains("3\tline3"), true)

        // 清理
        try { rmFile(path) } catch (e: Exception) {}
    }

    @TestCase
    public func testLargeFileDefaultLimit(): Unit {
        // 创建大文件（> 200 行，触发默认 limit=200）
        let path = "/tmp/cjh_read_test_large.txt"
        let sb = StringBuilder()
        for (i in 0..250) {
            sb.append("line${i}\n")
        }
        File.writeTo(path, sb.toString().toArray())

        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        let result = tool.execute(args)

        @Assert(result.isError, false)
        // 验证默认返回前 200 行（行号 1 到 200）
        @Assert(result.content.contains("1\tline0"), true)
        @Assert(result.content.contains("200\tline199"), true)
        // 第 201 行不应出现（默认 limit=200）
        @Assert(result.content.contains("line200"), false)

        // 清理
        try { rmFile(path) } catch (e: Exception) {}
    }

    @TestCase
    public func testOffsetLimitRange(): Unit {
        // 创建测试文件（300 行）
        let path = "/tmp/cjh_read_test_range.txt"
        let sb = StringBuilder()
        for (i in 0..300) {
            sb.append("line${i}\n")
        }
        File.writeTo(path, sb.toString().toArray())

        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("offset", JsonInt(50))
        args.put("limit", JsonInt(10))
        let result = tool.execute(args)

        @Assert(result.isError, false)
        // 验证返回第 50-59 行（offset=50, limit=10）
        @Assert(result.content.contains("50\tline49"), true)
        @Assert(result.content.contains("59\tline58"), true)
        // 第 49 行和第 60 行不应出现
        @Assert(result.content.contains("line48"), false)
        @Assert(result.content.contains("line59"), false)

        // 清理
        try { rmFile(path) } catch (e: Exception) {}
    }

    @TestCase
    public func testRepeatReadHint(): Unit {
        // 测试重复读提示（读同一文件 ≥3 次）
        let path = "/tmp/cjh_read_test_repeat.txt"
        File.writeTo(path, "hello\n".toArray())

        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))

        // 第 1 次读：无提示
        let r1 = tool.execute(args)
        @Assert(r1.content.contains("[提示]"), false)

        // 第 2 次读：无提示
        let r2 = tool.execute(args)
        @Assert(r2.content.contains("[提示]"), false)

        // 第 3 次读：应有提示
        let r3 = tool.execute(args)
        @Assert(r3.content.contains("[提示]"), true)

        // 清理
        try { rmFile(path) } catch (e: Exception) {}
    }

    @TestCase
    public func testLineRangeHintForLongContent(): Unit {
        // 测试长内容翻页提示（无 offset/limit 且结果 > 2000 字符）
        let path = "/tmp/cjh_read_test_longhint.txt"
        let sb = StringBuilder()
        for (i in 0..150) {
            // 每行约 20 字符，150 行约 3000 字符，触发翻页提示
            sb.append("line${i}paddingxx\n")
        }
        File.writeTo(path, sb.toString().toArray())

        let tool = ReadTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        let result = tool.execute(args)

        @Assert(result.isError, false)
        // 150 行 < 200 行阈值，走小文件全文分支
        // 内容较长时应有翻页提示
        @Assert(result.content.contains("[提示]"), true)

        // 清理
        try { rmFile(path) } catch (e: Exception) {}
    }
}
