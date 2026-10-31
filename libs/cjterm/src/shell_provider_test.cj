package cjterm

/*
 * ShellProvider 的候选推导（v1.6.2）——**纯函数单测**。
 *
 * 现场：Git 装在 `D:\Program Files\Git`，而旧实现只写死 `C:\Program Files\...` 三个候选、
 * 且不校验存在性 → shellPath 指向不存在的文件，bash 工具任何命令都报
 * `ProcessException: The system cannot find the file specified`。
 *
 * 这里钉四件事：PATH 推导、环境变量候选、去重、不瞎猜。
 */

import std.collection.*

@Test
public func testBashPathFromGitExe(): Unit {
    // 标准安装：<Git>\cmd\git.exe → <Git>\bin\bash.exe
    @Assert(ShellProvider.bashPathFromGitExe("D:\\Program Files\\Git\\cmd\\git.exe"),
        "D:\\Program Files\\Git\\bin\\bash.exe")
    // mingw64 里的 git 也能推导到同一个 bash
    @Assert(ShellProvider.bashPathFromGitExe("D:\\Program Files\\Git\\mingw64\\bin\\git.exe"),
        "D:\\Program Files\\Git\\bin\\bash.exe")
    // 已经是 bash 就直接用
    @Assert(ShellProvider.bashPathFromGitExe("D:\\Program Files\\Git\\bin\\bash.exe"),
        "D:\\Program Files\\Git\\bin\\bash.exe")
    // 不是 Git 目录：不瞎猜
    @Assert(ShellProvider.bashPathFromGitExe("C:\\Windows\\System32\\git.exe"), "")
    @Assert(ShellProvider.bashPathFromGitExe(""), "")
}

@Test
public func testCandidatesFromEnvAndPath(): Unit {
    let path = "C:\\Windows\\System32;D:\\Program Files\\Git\\cmd;D:\\Program Files\\Git\\mingw64\\bin"
    let langs = ShellProvider.windowsBashCandidates("C:\\Program Files", "C:\\Program Files",
        "C:\\Program Files (x86)", "C:\\Users\\me\\AppData\\Local", path, ["D"])
    // 环境变量候选
    @Assert(langs.contains("C:\\Program Files\\Git\\bin\\bash.exe"), true)
    @Assert(langs.contains("C:\\Program Files (x86)\\Git\\bin\\bash.exe"), true)
    @Assert(langs.contains("C:\\Users\\me\\AppData\\Local\\Programs\\Git\\bin\\bash.exe"), true)
    // PATH 推导出 D 盘的 Git（这就是本机真实场景）
    @Assert(langs.contains("D:\\Program Files\\Git\\bin\\bash.exe"), true)
    // 去重：PATH 里两个 Git 段推导出同一个 bash，只留一份
    var n: Int64 = 0
    for (c in langs) {
        if (c == "D:\\Program Files\\Git\\bin\\bash.exe") {
            n += 1
        }
    }
    @Assert(n, 1)
}

@Test
public func testCandidatesTolerateEmptyInputs(): Unit {
    // 全空：不抛、不崩（此时 ShellProvider 会降级 PowerShell）
    let langs = ShellProvider.windowsBashCandidates("", "", "", "", "", Array<String>(0, repeat: ""))
    @Assert(langs.size, 0)
}
