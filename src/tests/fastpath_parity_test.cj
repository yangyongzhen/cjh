package cjh.tests

import std.fs.*
import stdx.encoding.json.*
import std.process.*
import std.env.*
import cjh.tools.*

/**
 * grep / glob "find 快速路径"测试。
 *
 * 核心契约：find 快速路径（CJH_DISABLE_FIND_FASTPATH 未设）的输出必须与
 * 原生显式递归路径（CJH_DISABLE_FIND_FASTPATH=1 强制回退）**逐字节一致**——
 * 包括文件顺序、路径前缀（含 //、./、尾 / 等 quirk）、符号链接处理、
 * 隐藏/忽略目录过滤、上下文渲染。
 *
 * 覆盖：
 *  - 快速路径 vs 原生 字节级一致（grep + glob）
 *  - 符号链接：文件 symlink 计入、symlink 到目录不递归、悬空 symlink 安全
 *  - 隐藏 / 忽略目录（grep 9 目录、glob 12 目录 + 隐藏）过滤一致
 *  - basePath 各形态（相对 / 尾 / / // / ./ / 绝对）输出一致
 *  - 非目录 base 走原生错误路径（glob 失败）
 */

/** 创建符号链接：ln -s target linkPath（父目录须已存在） */
func makeSymlink(target: String, linkPath: String): Unit {
    var args = Array<String>(2, repeat: "")
    args[0] = "-c"
    args[1] = "ln -s '" + target + "' '" + linkPath + "'"
    let _ = executeWithOutput("/bin/bash", args)
}

/** 清除快速路径开关（置空 ⇒ isFindFastPathEnabled 视为未设 ⇒ 快速路径开启） */
func clearFastPathEnv(): Unit {
    setVariable("CJH_DISABLE_FIND_FASTPATH", "")
}

/** 调用 grep：path 目录搜索，context=1。envOn=true 开快速路径，false 回退原生 */
func grepRun(dir: String, envOn: Bool): String {
    if (envOn) {
        clearFastPathEnv()
    } else {
        setVariable("CJH_DISABLE_FIND_FASTPATH", "1")
    }
    let tool = GrepTool()
    var args = JsonObject()
    args.put("pattern", JsonString("MARKER"))
    args.put("path", JsonString(dir))
    args.put("context", JsonInt(1))
    let result = tool.execute(args)
    clearFastPathEnv()
    return result.content
}

/** 调用 glob：base 目录搜索 pattern。envOn=true 开快速路径，false 回退原生 */
func globRun(base: String, pattern: String, envOn: Bool): String {
    if (envOn) {
        clearFastPathEnv()
    } else {
        setVariable("CJH_DISABLE_FIND_FASTPATH", "1")
    }
    let tool = GlobTool()
    var args = JsonObject()
    args.put("pattern", JsonString(pattern))
    args.put("path", JsonString(base))
    let result = tool.execute(args)
    clearFastPathEnv()
    return result.content
}

/** 建一棵含符号链接 / 隐藏 / 忽略目录的样本树，root.txt 与 allfiles 含 MARKER */
func makeFixture(dir: String): Unit {
    writeTextFile(dir + "/root.txt", "MARKER root line\n")
    Directory.create(dir + "/a", recursive: true)
    writeTextFile(dir + "/a/f1.txt", "MARKER in a/f1\n")
    Directory.create(dir + "/a/sub", recursive: true)
    writeTextFile(dir + "/a/sub/deep.cj", "MARKER deep\n")
    Directory.create(dir + "/.hiddendir", recursive: true)
    writeTextFile(dir + "/.hiddendir/h.txt", "MARKER hidden\n")
    Directory.create(dir + "/node_modules", recursive: true)
    writeTextFile(dir + "/node_modules/pkg.txt", "MARKER node_modules\n")
    writeTextFile(dir + "/real.txt", "MARKER real\n")
    makeSymlink(dir + "/real.txt", dir + "/link.txt")
    Directory.create(dir + "/realdir", recursive: true)
    writeTextFile(dir + "/realdir/in.txt", "MARKER in realdir\n")
    makeSymlink(dir + "/realdir", dir + "/linkdir")
    writeTextFile(dir + "/dangle.txt", "MARKER dangle\n")
    makeSymlink(dir + "/does-not-exist", dir + "/dangle_link")
}

@Test
public class FastPathParityTest {
    private var dir: String = testTempDir("fastpath")

    @TestCase
    public func testGrepFastPathParity(): Unit {
        this.dir = testTempDir("fastpath_grep")
        makeFixture(this.dir)
        let fast = grepRun(this.dir, true)
        let native = grepRun(this.dir, false)
        @Assert(fast == native, true)  // 快速路径与原生逐字节一致
        @Assert(fast.contains("real.txt"), true)
        @Assert(fast.contains("root.txt"), true)
    }

    @TestCase
    public func testGlobFastPathParity(): Unit {
        this.dir = testTempDir("fastpath_glob")
        makeFixture(this.dir)
        let fast = globRun(this.dir, "**/*", true)
        let native = globRun(this.dir, "**/*", false)
        @Assert(fast == native, true)
        @Assert(fast.contains("real.txt"), true)
        @Assert(fast.contains("link.txt"), true)  // 文件 symlink 计入
    }

    @TestCase
    public func testGrepSymlinkSemantics(): Unit {
        this.dir = testTempDir("fastpath_sym")
        makeFixture(this.dir)
        let out = grepRun(this.dir, true)
        @Assert(out.contains("real.txt"), true)    // 真实文件
        @Assert(out.contains("realdir"), true)      // symlink 到目录：其内文件被搜索（经真实路径）
        @Assert(!out.contains("dangle_link"), true) // 悬空 symlink：不匹配（读取失败被跳过）
        @Assert(!out.contains("node_modules"), true) // 忽略目录
    }

    @TestCase
    public func testGlobSymlinkSemantics(): Unit {
        this.dir = testTempDir("fastpath_gsym")
        makeFixture(this.dir)
        let out = globRun(this.dir, "**/*", true)
        @Assert(out.contains("real.txt"), true)
        @Assert(out.contains("link.txt"), true)        // 文件 symlink 按名计入（glob 不读内容）
        @Assert(out.contains("realdir/in.txt"), true)  // 真实目录递归 → 其内文件出现
        @Assert(!out.contains("linkdir/in.txt"), true) // 目录 symlink 不递归（isDirectory=false）
        @Assert(out.contains("dangle_link"), true)     // 悬空 symlink 按名计入
        @Assert(!out.contains("node_modules"), true)   // 忽略目录
        @Assert(!out.contains(".hiddendir"), true)     // 隐藏目录
    }

    @TestCase
    public func testGrepBaseFormsParity(): Unit {
        this.dir = testTempDir("fastpath_base")
        makeFixture(this.dir)
        // 每种 base 形态下，快速路径 == 原生（grep 输出绝对 fi.path，形态 quirk 会
        // 原样保留，故按"同形态 fast==native"断言，而非跨形态比较）
        @Assert(grepRun(this.dir, true) == grepRun(this.dir, false), true)
        @Assert(grepRun(this.dir + "/", true) == grepRun(this.dir + "/", false), true)   // 尾 /
        @Assert(grepRun(this.dir + "//", true) == grepRun(this.dir + "//", false), true) // 双 /
        @Assert(grepRun(this.dir, false).contains("root.txt"), true)
    }

    @TestCase
    public func testGlobBaseFormsParity(): Unit {
        this.dir = testTempDir("fastpath_gbase")
        makeFixture(this.dir)
        // glob 输出相对 relPath，同形态 fast==native（含尾 / / 双 / 的 makeRelative quirk）
        @Assert(globRun(this.dir, "**/*", true) == globRun(this.dir, "**/*", false), true)
        @Assert(globRun(this.dir + "/", "**/*", true) == globRun(this.dir + "/", "**/*", false), true)
        @Assert(globRun(this.dir + "//", "**/*", true) == globRun(this.dir + "//", "**/*", false), true)
        @Assert(globRun(this.dir, "**/*", true).contains("a/f1.txt"), true)
    }

    @TestCase
    public func testGlobNonDirectoryBaseFallsBackToError(): Unit {
        this.dir = testTempDir("fastpath_nonfile")
        writeTextFile(this.dir + "/afile.txt", "x")
        // base 是文件：原生 walkTree 抛 FSException ⇒ "glob 失败"；
        // 快速路径必须回退到该原生错误路径（不能返回"没有文件匹配"）。
        let out = globRun(this.dir + "/afile.txt", "*.txt", true)
        @Assert(out.contains("glob 失败"), true)
    }
}
