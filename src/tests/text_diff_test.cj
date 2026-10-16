package cjh.tests

import stdx.encoding.json.*
import cjh.tools.*
import cjh.web.*
import cjh.gateway.*
import cjutil.*

/**
 * 结构化 diff 单元测试（客户端约定 #7）
 *
 * 三层覆盖：
 * - 纯函数：unifiedDiffText / buildDiffInfo（空差异、单行改、新增、追加、长文件上下文截取、sha 一致）
 * - 工具级：write_file / edit / append_file 成功后 ToolResult.diff 的真实内容（走 execute 公共 API）
 * - 帧级：ToolResultEvent 带 / 不带 diff 的 JSON 形状（有 diff 才出现 diff 键）
 */
@Test
public class TextDiffPureTest {
    @TestCase
    public func testNoChangeReturnsEmpty(): Unit {
        @Assert(unifiedDiffText("a\nb\n", "a\nb\n", "x.txt"), "")
        // 无变化 → 不算 diff（调用方据此不带 diff 字段，而不是带一个空 diff）
        var carried = false
        if (let Some(_) <- buildDiffInfo("x.txt", "same\n", "same\n")) {
            carried = true
        }
        @Assert(carried, false)
    }

    @TestCase
    public func testSingleLineChangeWithContext(): Unit {
        let oldText = "l1\nl2\nl3\nold4\nl5\nl6\n"
        let newText = "l1\nl2\nl3\nnew4\nl5\nl6\n"
        let diff = unifiedDiffText(oldText, newText, "f.txt")
        @Assert(diff.contains("--- a/f.txt\n"), true)
        @Assert(diff.contains("+++ b/f.txt\n"), true)
        @Assert(diff.contains("@@ -1,6 +1,6 @@\n"), true)
        @Assert(diff.contains("-old4\n"), true)
        @Assert(diff.contains("+new4\n"), true)
        // 公共行以空格前缀出现（上下文行）
        @Assert(diff.contains(" l3\n"), true)
        @Assert(diff.contains(" l5\n"), true)
    }

    @TestCase
    public func testNewFileIsAllAdditions(): Unit {
        let diff = unifiedDiffText("", "a\nb\n", "new.txt")
        @Assert(diff.contains("@@ -1,0 +1,2 @@\n"), true)
        @Assert(diff.contains("+a\n"), true)
        @Assert(diff.contains("+b\n"), true)
        // 新文件不该出现删除行
        @Assert(diff.contains("\n-"), false)
    }

    @TestCase
    public func testAppendIsAdditionsOnly(): Unit {
        let diff = unifiedDiffText("a\n", "a\nb\n", "t.txt")
        @Assert(diff.contains("+b\n"), true)
        @Assert(diff.contains("-a"), false)
        @Assert(diff.contains(" a\n"), true)
    }

    @TestCase
    public func testLongFileContextIsClipped(): Unit {
        // 20 行，只改第 15 行：hunk 应从第 12 行起（15-3），共 3+1+3=7 行
        var oldLines = StringBuilder()
        var newLines = StringBuilder()
        for (i in 1..21) {
            if (i == 15) {
                oldLines.append("old15\n")
                newLines.append("new15\n")
            } else {
                oldLines.append("line${i}\n")
                newLines.append("line${i}\n")
            }
        }
        let diff = unifiedDiffText(oldLines.toString(), newLines.toString(), "big.txt")
        @Assert(diff.contains("@@ -12,7 +12,7 @@\n"), true)
        @Assert(diff.contains("-old15\n"), true)
        @Assert(diff.contains("+new15\n"), true)
        // 第 11 行在上下文窗口外，不该出现
        @Assert(diff.contains("line11\n"), false)
    }

    @TestCase
    public func testBuildDiffInfoShas(): Unit {
        let before = "x\ny\n"
        let after = "x\nz\n"
        var carried = false
        if (let Some(d) <- buildDiffInfo("p.txt", before, after)) {
            carried = true
            @Assert(d.path, "p.txt")
            @Assert(d.beforeSha, sha256HexStr(before))
            @Assert(d.afterSha, sha256HexStr(after))
            @Assert(d.unifiedDiff.contains("+z\n"), true)
            // JSON 形状：客户端按这四个键渲染 / 识别版本
            let obj = d.toJson()
            @Assert(obj.containsKey("path"), true)
            @Assert(obj.containsKey("unified_diff"), true)
            @Assert(obj.containsKey("before_sha"), true)
            @Assert(obj.containsKey("after_sha"), true)
        }
        @Assert(carried, true)
    }
}

@Test
public class DiffInToolResultTest {
    private let dir: String = testTempDir("textdiff_tools")

    @TestCase
    public func testWriteNewFileCarriesDiff(): Unit {
        let path = this.dir + "/w1.txt"
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("line1\nline2\n"))
        let result = WriteTool().execute(args)
        @Assert(result.isError, false)
        var carried = false
        if (let Some(d) <- result.diff) {
            carried = true
            @Assert(d.path, path)
            @Assert(d.unifiedDiff.contains("+line1\n"), true)
            // 新文件：旧内容为空
            @Assert(d.beforeSha, sha256HexStr(""))
            @Assert(d.afterSha, sha256HexStr("line1\nline2\n"))
        }
        @Assert(carried, true)
    }

    @TestCase
    public func testWriteSameContentHasNoDiff(): Unit {
        let path = this.dir + "/w2.txt"
        var args1 = JsonObject()
        args1.put("path", JsonString(path))
        args1.put("content", JsonString("same\n"))
        let first = WriteTool().execute(args1)
        @Assert(first.isError, false)
        var firstCarried = false
        if (let Some(_) <- first.diff) { firstCarried = true }
        @Assert(firstCarried, true)

        // 内容没变 → 不该报 diff（"无变化"和"变了"必须能区分）
        var args2 = JsonObject()
        args2.put("path", JsonString(path))
        args2.put("content", JsonString("same\n"))
        let second = WriteTool().execute(args2)
        @Assert(second.isError, false)
        var secondCarried = false
        if (let Some(_) <- second.diff) { secondCarried = true }
        @Assert(secondCarried, false)
    }

    @TestCase
    public func testEditToolCarriesDiff(): Unit {
        let path = this.dir + "/e1.txt"
        writeTextFile(path, "aa\nbb\ncc\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("bb"))
        args.put("new_string", JsonString("BB"))
        let result = EditTool().execute(args)
        @Assert(result.isError, false)
        var carried = false
        if (let Some(d) <- result.diff) {
            carried = true
            @Assert(d.path, path)
            @Assert(d.unifiedDiff.contains("-bb\n"), true)
            @Assert(d.unifiedDiff.contains("+BB\n"), true)
            @Assert(d.beforeSha, sha256HexStr("aa\nbb\ncc\n"))
            @Assert(d.afterSha, sha256HexStr(readTextFile(path)))
        }
        @Assert(carried, true)
    }

    @TestCase
    public func testEditFailureHasNoDiff(): Unit {
        let path = this.dir + "/e2.txt"
        writeTextFile(path, "aa\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("old_string", JsonString("not-present"))
        args.put("new_string", JsonString("x"))
        let result = EditTool().execute(args)
        // 错误路径不该带 diff（没改动就没有 diff 可言）
        @Assert(result.isError, true)
        var carried = false
        if (let Some(_) <- result.diff) { carried = true }
        @Assert(carried, false)
    }

    @TestCase
    public func testAppendFileCarriesDiff(): Unit {
        let path = this.dir + "/a1.txt"
        writeTextFile(path, "a\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("b\n"))
        let result = AppendFileTool().execute(args)
        @Assert(result.isError, false)
        var carried = false
        if (let Some(d) <- result.diff) {
            carried = true
            @Assert(d.beforeSha, sha256HexStr("a\n"))
            @Assert(d.afterSha, sha256HexStr("a\nb\n"))
            @Assert(d.unifiedDiff.contains("+b\n"), true)
        }
        @Assert(carried, true)
    }

    @TestCase
    public func testAppendMissingFileHasNoDiff(): Unit {
        let path = this.dir + "/a2_missing.txt"
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("content", JsonString("b\n"))
        let result = AppendFileTool().execute(args)
        @Assert(result.isError, true)
        var carried = false
        if (let Some(_) <- result.diff) { carried = true }
        @Assert(carried, false)
    }

    @TestCase
    public func testHashlineEditCarriesDiff(): Unit {
        let path = this.dir + "/h1.txt"
        writeTextFile(path, "a\nb\nc\n")
        var args = JsonObject()
        args.put("path", JsonString(path))
        args.put("patch", JsonString("@@2\n-b\n+B2"))
        let result = HashlineEditTool().execute(args)
        @Assert(result.isError, false)
        var carried = false
        if (let Some(d) <- result.diff) {
            carried = true
            @Assert(d.path, path)
            @Assert(d.unifiedDiff.contains("-b\n"), true)
            @Assert(d.unifiedDiff.contains("+B2\n"), true)
            @Assert(d.beforeSha, sha256HexStr("a\nb\nc\n"))
            @Assert(d.afterSha, sha256HexStr("a\nB2\nc\n"))
        }
        @Assert(carried, true)
    }
}

@Test
public class DiffFrameTest {
    @TestCase
    public func testToolResultFrameCarriesDiff(): Unit {
        let info = DiffInfo("f.txt", "--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n",
            "aaa", "bbb")
        let event = ToolResultEvent("edit", "edit 成功", false)
        event.diff = Some(info)
        event.meta = FrameMeta("s1", "t1", "m1")
        let json = event.toJson()
        // 断言不绑定序列化的空格风格（key 带引号即可命中）
        @Assert(json.contains("tool_result"), true)
        @Assert(json.contains("\"diff\""), true)
        @Assert(json.contains("f.txt"), true)
        @Assert(json.contains("aaa"), true)
        @Assert(json.contains("bbb"), true)
        // 帧身份仍在（v2 契约不许因加字段而丢）
        @Assert(json.contains("\"session_id\""), true)
        @Assert(json.contains("s1"), true)
    }

    @TestCase
    public func testToolResultFrameOmitsDiffWhenAbsent(): Unit {
        let event = ToolResultEvent("bash", "hello", false)
        let json = event.toJson()
        // 无 diff 时不许出现 diff 键（老客户端 / 非文件工具路径不变）
        @Assert(json.contains("\"diff\""), false)
        @Assert(json.contains("hello"), true)
    }
}
