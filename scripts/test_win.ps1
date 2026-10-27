<#
.SYNOPSIS
    Windows 原生测试门禁（尽力而为 + 明确报告缺件，绝不假装绿）。

.DESCRIPTION
    对齐 Linux 侧 scripts/test.sh + scripts/test_libs.sh 的三件事：

      1) 根包 cjh：从 cjpm.toml 静态基线**临时派生** Windows 可用配置
         （清 --static、link-option 换系统库、补 [target.x86_64-w64-mingw32] stdx 路径），
         跑 cjpm build + cjpm test，结束时（含异常/中断）恢复原配置。
      2) libs/*：逐包 cjpm test（等同 test_libs.sh）。
      3) 汇总 + 退出码：0=全绿；1=有用例失败；2=环境缺件（windows stdx 未装）
         导致没能完整验证。

    为什么 Windows 上需要单独一份：
      - `scripts/test.sh` / `test_libs.sh` 是 bash + `/tmp` + `source /opt/cangjie/...`
        （Linux 开发机路径），Windows 上跑不起来；
      - 根 `cjpm.toml` 是 Linux 静态链接基线（`--static --static-std` + Linux rpath +
        `[target.x86_64-unknown-linux-gnu.bin-dependencies]`），Windows 上 `--static`
        还会被仓颉工具链静默忽略（已知上游问题）；
      - 仓颉 stdx 按平台独立发布：`~/.cangjie/stdx` 只有 ohos-aarch64 时，任何
        `import stdx.*` 的包（cjutil/cjcfg/cjllm/根包）都无法编译。

    缺件时的安装提示（二选一）：
      a) 官方下载器：cangjie_stdx 仓库的 downloader.ps1（按平台/版本自动落位）；
      b) 手动：把 cangjie-stdx-windows-x64-<ver>.zip 解到
         `%USERPROFILE%\.cangjie\stdx\cangjie-stdx-windows-x64-<ver>\`，
         即存在 `windows_x86_64_cjnative\static\stdx` 目录。
    也可用环境变量 CJH_WINDOWS_STDX 直接指向该 stdx 目录。

    本文件必须保存为 **UTF-8 with BOM**：Windows PowerShell 5.1 读无 BOM 的 UTF-8
    脚本会按 ANSI 解码，中文注释会把语法分析带崩。

.PARAMETER Libs
    只跑 libs/*，跳过根包。

.PARAMETER Root
    只跑根包，跳过 libs。

.PARAMETER Only
    只跑指定 lib（名字，不含路径），如 `-Only cjterm,cjlog`。

.PARAMETER Filter
    透传给 cjpm test 的用例过滤，如 `-Filter "*AgentsPanel*"`。

.PARAMETER NoRestore
    调试用：不恢复 cjpm.toml（默认一定会恢复）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_win.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_win.ps1 -Only cjterm -Filter "*AgentsPanel*"
    pwsh -File scripts/test_win.ps1 -Libs
#>
[CmdletBinding()]
param(
    [switch]$Libs,
    [switch]$Root,
    [string[]]$Only = @(),
    [string]$Filter = "",
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo

function Say([string]$msg, [string]$color = "Gray") {
    Write-Host $msg -ForegroundColor $color
}

function Strip-Ansi([string]$s) {
    if (-not $s) { return "" }
    return [regex]::Replace($s, "\x1b\[[0-9;]*[A-Za-z]", "")
}

# 跑原生命令：临时把 ErrorActionPreference 调回 Continue——
# cjpm/cjc 会往 stderr 写 warning，PS 在 Stop 模式下会把原生 stderr 当终止错误。
function Run-Native([string]$exe, [string[]]$cmdArgs, [string]$workdir) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $workdir
    try {
        $raw = & $exe @cmdArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Out = (Strip-Ansi $raw); Code = $code }
}

# ---------------------------------------------------------------- 环境准备
if (-not $env:CANGJIE_HOME) {
    foreach ($cand in @("D:\Program Files (x86)\Cangjie", "C:\Program Files (x86)\Cangjie",
            "D:\Program Files\Cangjie", "C:\Program Files\Cangjie")) {
        if (Test-Path (Join-Path $cand "bin\cjc.exe")) {
            $env:CANGJIE_HOME = $cand
            break
        }
    }
}
if (-not $env:CANGJIE_HOME -or -not (Test-Path (Join-Path $env:CANGJIE_HOME "bin\cjc.exe"))) {
    Say "× 找不到仓颉工具链：请设置 CANGJIE_HOME 指向 SDK 根目录（含 bin\cjc.exe）" "Red"
    Pop-Location
    exit 2
}
$cjroot = $env:CANGJIE_HOME
# cjc/cjpm 及运行时库目录进 PATH（等价 envsetup.bat）
foreach ($sub in @("runtime\lib\windows_x86_64_cjnative", "lib\windows_x86_64_cjnative",
        "bin", "tools\bin", "tools\lib")) {
    $p = Join-Path $cjroot $sub
    if (Test-Path $p) { $env:PATH = $p + ";" + $env:PATH }
}
# 测试用隔离配置目录：避免读到真实 ~/.cjh 的 history/draft/settings（同 test.sh）
if (-not $env:CJH_CONFIG_DIR) {
    $env:CJH_CONFIG_DIR = Join-Path $env:TEMP ("cjh_win_test_cfg_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $env:CJH_CONFIG_DIR | Out-Null
}

Say "== cjh Windows 测试门禁 ==" "Cyan"
Say ("  仓库        : " + $repo)
Say ("  CANGJIE_HOME: " + $cjroot)
$ver = Run-Native "cjc" @("--version") $repo
Say ("  " + (($ver.Out -split "`n" | Where-Object { $_.Trim() }) -join " | "))
Say ("  CJH_CONFIG_DIR: " + $env:CJH_CONFIG_DIR)

# ---------------------------------------------------------------- windows stdx 探测
$winStdx = ""
if ($env:CJH_WINDOWS_STDX -and (Test-Path $env:CJH_WINDOWS_STDX)) {
    $winStdx = $env:CJH_WINDOWS_STDX
} else {
    $stdxRoot = Join-Path $env:USERPROFILE ".cangjie\stdx"
    if (Test-Path $stdxRoot) {
        $hit = Get-ChildItem $stdxRoot -Directory -Filter "cangjie-stdx-windows-x64-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "windows_x86_64_cjnative\static\stdx" } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) { $winStdx = $hit }
    }
}
if ($winStdx) {
    Say ("  windows stdx: " + $winStdx) "Green"
} else {
    Say "  windows stdx: 未安装（依赖 stdx 的包将跳过）" "Yellow"
}

# ---------------------------------------------------------------- 配置派生 / 恢复
$tomlPath = Join-Path $repo "cjpm.toml"
$tomlBackup = Join-Path $env:TEMP "cjpm.toml.wintest.bak"
$derived = $false

function Restore-Config {
    if ($derived -and -not $NoRestore -and (Test-Path $tomlBackup)) {
        Copy-Item $tomlBackup $tomlPath -Force
        Say "  cjpm.toml 已恢复为静态基线" "DarkGray"
    }
}

function New-WindowsConfig([string]$stdxPath) {
    $text = [System.IO.File]::ReadAllText($tomlPath)
    if ($text -match '(?m)^\s*compile-option\s*=\s*""') {
        throw "cjpm.toml 当前是派生态（上次运行被强杀未恢复）。先恢复基线：git checkout -- cjpm.toml"
    }
    [System.IO.File]::WriteAllText($tomlBackup, $text, (New-Object System.Text.UTF8Encoding($false)))
    # 测试不静态链接：Windows 目标下 --static 会被工具链静默忽略（已知上游问题），
    # 且静态链接下测试框架有崩溃史（见 scripts/test.sh 头注释）。
    $text = [regex]::Replace($text, '(?m)^\s*compile-option\s*=.*$', '  compile-option = ""')
    # Linux rpath 换 mingw 系统库（crypt32: x509；ws2_32: 网络）
    $text = [regex]::Replace($text, '(?m)^\s*link-option\s*=.*$', '  link-option = "-lcrypt32 -lws2_32"')
    if ($text -notmatch 'x86_64-w64-mingw32\.bin-dependencies') {
        $text = $text + "`n[target.x86_64-w64-mingw32.bin-dependencies]`n    path-option = [`"$stdxPath`"]`n"
    }
    [System.IO.File]::WriteAllText($tomlPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 运行器
$results = New-Object System.Collections.ArrayList

function Add-Result([string]$name, [string]$status, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Name = $name; Status = $status; Detail = $detail })
}

function Get-TestSummary([string]$out) {
    # 只认 cjpm 的大写汇总行（-cmatch 区分大小写）：进度条里的小写
    # "passed: 40, failed: 0" 会被大小写不敏感的 ^PASSED: 正则命中，撑爆汇总列
    $seen = @{}
    $lines = @()
    foreach ($l in ($out -split "`n")) {
        $t = $l.Trim()
        if ($t -cmatch "^(Summary:|PASSED:|FAILED:|ERROR:)" -and -not $seen.ContainsKey($t)) {
            $seen[$t] = $true
            $lines += $t
        }
    }
    return ($lines -join " | ")
}

function Invoke-CjpmTest([string]$workdir, [string]$label) {
    $cmdArgs = @("test")
    if ($Filter) { $cmdArgs += @("--filter", $Filter) }
    $r = Run-Native "cjpm" $cmdArgs $workdir
    $summary = Get-TestSummary $r.Out
    if ($r.Code -eq 0) {
        Add-Result $label "PASS" $summary
        Say ("  [PASS] " + $label) "Green"
        Say ("         " + $summary) "DarkGray"
    } else {
        Add-Result $label "FAIL" $summary
        Say ("  [FAIL] " + $label) "Red"
        Say ("         " + $summary) "DarkGray"
        ($r.Out -split "`n" | Where-Object { $_ -match "REASON:|error:|FAILED\s" } |
            Select-Object -First 8) | ForEach-Object { Say ("         " + $_.Trim()) "DarkYellow" }
    }
    return $r.Code
}

# ---------------------------------------------------------------- 根包
$exitCode = 0

if (-not $Libs) {
    Say "`n-- 根包 cjh --" "Cyan"
    if (-not $winStdx) {
        Say "  [SKIP] 缺 windows stdx（根包 import stdx.encoding.json / stdx.net.* / stdx.crypto.*）" "Yellow"
        Say "         装好后自动启用：官方 downloader.ps1，或把 cangjie-stdx-windows-x64-*.zip" "DarkGray"
        Say "         解到 %USERPROFILE%\.cangjie\stdx\ 下（需存在 windows_x86_64_cjnative\static\stdx）" "DarkGray"
        Add-Result "cjh (root)" "SKIP" "缺 windows stdx"
    } else {
        try {
            New-WindowsConfig $winStdx
            $derived = $true
            Say "  已派生 Windows 配置（临时，结束恢复）" "DarkGray"
            $b = Run-Native "cjpm" @("build") $repo
            $warn = ([regex]::Matches($b.Out, "warning:")).Count
            if ($b.Code -eq 0) {
                Say ("  [PASS] build（warning: " + $warn + " 条）") "Green"
            } else {
                Say "  [FAIL] build" "Red"
                ($b.Out -split "`n" | Where-Object { $_ -match "error" } | Select-Object -First 8) |
                    ForEach-Object { Say ("         " + $_.Trim()) "DarkYellow" }
                $exitCode = 1
            }
            if ($b.Code -eq 0) {
                $rc = Invoke-CjpmTest $repo "cjh (root)"
                if ($rc -ne 0) { $exitCode = 1 }
            }
        } catch {
            Say ("  派生配置失败：" + $_.Exception.Message) "Red"
            $exitCode = 1
        } finally {
            Restore-Config
            $derived = $false
        }
    }
}

# ---------------------------------------------------------------- libs
if (-not $Root) {
    Say "`n-- libs/* --" "Cyan"
    $libDirs = Get-ChildItem (Join-Path $repo "libs") -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "cjpm.toml") } |
        Sort-Object Name
    foreach ($d in $libDirs) {
        if ($Only.Count -gt 0 -and ($Only -notcontains $d.Name)) { continue }
        $needsStdx = [bool](Get-ChildItem (Join-Path $d.FullName "src") -Filter *.cj -Recurse -ErrorAction SilentlyContinue |
            Select-String -Pattern "^import stdx" -List -ErrorAction SilentlyContinue)
        if ($needsStdx -and -not $winStdx) {
            Say ("  [SKIP] " + $d.Name + "：源码 import stdx，缺 windows stdx") "Yellow"
            Add-Result $d.Name "SKIP" "缺 windows stdx"
            continue
        }
        $rc = Invoke-CjpmTest $d.FullName $d.Name
        if ($rc -ne 0) { $exitCode = 1 }
    }
}

# ---------------------------------------------------------------- 汇总
Say "`n== 汇总 ==" "Cyan"
$results | Format-Table -AutoSize Name, Status, Detail | Out-String -Width 200 | Write-Host
$passN = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$failN = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
$skipN = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
if ($failN -gt 0) {
    Say ("  PASS=" + $passN + "  FAIL=" + $failN + "  SKIP=" + $skipN) "Red"
} else {
    Say ("  PASS=" + $passN + "  FAIL=" + $failN + "  SKIP=" + $skipN) "Green"
}

if ($skipN -gt 0) {
    Say "`n注意：以下项没有被验证过（不是通过）：" "Yellow"
    foreach ($r in $results) {
        if ($r.Status -eq "SKIP") { Say ("  - " + $r.Name + "：" + $r.Detail) "Yellow" }
    }
    if ($exitCode -eq 0) { $exitCode = 2 }
}
Say "`nWindows 原生门禁不覆盖（仍须 Linux）：scripts/tui_pty_test.py（pty/termios）、" "DarkGray"
Say "scripts/web_smoke_test.py（起服务）、cjh --mock 端到端、发布二进制体积/ldd 核对。" "DarkGray"

Pop-Location
if ($failN -gt 0) { exit 1 }
exit $exitCode
