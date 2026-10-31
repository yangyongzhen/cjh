package cjh.tests

import cjh.tools.*

/**
 * shell PATH 修复（`shell_path.cj`）单测。
 *
 * 背景：cjh 用绝对路径找到 Git Bash，但它的 `/usr/bin` 未必在继承的 PATH 上，
 * agent 跑 `cat`/`sed`/`grep` 就是 `command not found`（127）。修复方式是往会话里
 * 追加 `<shell 目录>` 与 `<shell 上级>/usr/bin`（幂等、不覆盖用户 PATH）。
 * 这里覆盖：路径转换、目录推导、修复片段内容、非 bash 模式为空。
 */
@Test
public class ShellPathTest {

    @TestCase
    public func testMsysPathOfConvertsWindowsPath(): Unit {
        @Assert(msysPathOf("D:\\Program Files\\Git\\bin"), "/D/Program Files/Git/bin")
        @Assert(msysPathOf("D:/Program Files/Git/bin"), "/D/Program Files/Git/bin")
        // 已是 POSIX 形式：原样返回
        @Assert(msysPathOf("/usr/local/bin"), "/usr/local/bin")
        // 空输入
        @Assert(msysPathOf("   "), "")
    }

    @TestCase
    public func testMsysDirOfStripsFileAndSeparators(): Unit {
        @Assert(msysDirOf("D:\\Program Files\\Git\\bin\\bash.exe"), "/D/Program Files/Git/bin")
        @Assert(msysDirOf("/d/Program Files/Git/bin/"), "/d/Program Files/Git/bin")
        @Assert(msysDirOf("/bin/bash"), "/bin")
        // 没有目录部分 → 空串（调用方据此不加东西）
        @Assert(msysDirOf("bash"), "")
    }

    @TestCase
    public func testShellPathDirsIncludesUsrBin(): Unit {
        let dirs = shellPathDirs("D:\\Program Files\\Git\\bin\\bash.exe")
        @Assert(dirs.size >= 2, true)
        @Assert(dirs[0], "/D/Program Files/Git/bin")
        @Assert(dirs[1], "/D/Program Files/Git/usr/bin")
    }

    @TestCase
    public func testShellPathFixIsGuardedAndAppends(): Unit {
        let fix = shellPathFix("D:\\Program Files\\Git\\bin\\bash.exe", true)
        @Assert(fix.contains("if [ -z \"$__CJH_PATH_FIXED\" ]"), true)  // 幂等守卫
        @Assert(fix.contains("__CJH_PATH_FIXED=1"), true)
        // 追加而非覆盖：保留原 PATH
        @Assert(fix.contains("PATH=\"$PATH:"), true)
        @Assert(fix.contains("/D/Program Files/Git/usr/bin"), true)
        @Assert(fix.endsWith("fi; "), true)                              // 可直接拼在命令前
    }

    @TestCase
    public func testShellPathFixEmptyForPowerShellMode(): Unit {
        // PowerShell 模式没有这套 git 目录约定，必须返回空串（不能拼坏命令）
        @Assert(shellPathFix("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", false).size, 0)
        // shell 路径无目录部分时也不产出垃圾
        @Assert(shellPathFix("bash", true).size, 0)
    }
}
