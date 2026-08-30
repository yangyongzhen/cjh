package cjh.tests

import std.fs.*
import stdx.encoding.json.*
import cjh.tools.*

/**
 * edit 工具 UTF-8 回归：多字节字符（× 等）替换不抛 Invalid utf8
 */
@Test
public class EditUtf8Test {
    @TestCase
    public func testReplaceWithMultibyteChar(): Unit {
        let path = "/tmp/cjh_edit_utf8.txt"
        // 含 ×（2 字节）和中文的文件内容
        File.writeTo(path, "function spawnBoss() {\n    bossCount++;\n    // Boss 血量随击败次数成长：首个 80，之后 ×1.35\n}\n".toArray())
        let tool = EditTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("bossCount++;\n    // Boss 血量随击败次数成长：首个 80，之后 ×1.35"))
        args.put("new_string", JsonString("bossAlive = true;\n    // Boss 血量成长 ×1.35 新版"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        // 替换成功：新内容在，旧内容不在
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("bossAlive = true"), true)
        @Assert(content.contains("bossCount++"), false)

    }

    @TestCase
    public func testMultibyteBeforeMatch(): Unit {
        let path = "/tmp/cjh_edit_utf8b.txt"
        // 匹配位置之前有 × 等多字节字符（i 逐字节前进会落在中间）
        File.writeTo(path, "价格：×100 元\n需要修改这一行\n".toArray())
        let tool = EditTool()
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("需要修改这一行"))
        args.put("new_string", JsonString("已修改 ✓"))
        let result = tool.execute(args)
        @Assert(result.isError, false)
        let content = String.fromUtf8(File.readFrom(path))
        @Assert(content.contains("已修改 ✓"), true)

    }
}
