<#
.SYNOPSIS
    Windows 原生测试门禁（尽力而为 + 明确报告缺件，绝不假装绿）。

.DESCRIPTION
    对齐 Linux 侧 scripts/test.sh + scripts/test_libs.sh 的三件事：

      1) 根包 cjh：从 cjpm.toml 静态基线**临时派生** Windows 可用配置
         （清 --static、link-option 换系统库、补 [target.x86_64-w64-mingw32] 的 stdx 路径），
         跑 cjpm build + cjpm test。
      2) libs/*：逐包 cjpm test（等同 test_libs.sh）；源码 import stdx 的包也临时补
         Windows 目标段的 stdx 路径——cjpm 的 bin-dependencies 不向依赖包传播，
         只在根包写会报 "root package 'cjllm' imports package 'stdx.crypto.x509'..."。
      3) 结束时（含异常/中断）把动过的 cjpm.toml **全部恢复**成静态基线。

    退出码：0=全绿；1=有用例失败；2=有项没被验证（缺 windows stdx / 工具链版本不匹配）。

    为什么 Windows 上要单独一份：test.sh/test_libs.sh 是 bash + /tmp + Linux 路径；
    根 cjpm.toml 是 Linux 静态链接基线；仓颉 stdx 按平台独立发布。

    Windows stdx 探测顺序：-Stdx 参数 → CJH_WINDOWS_STDX → CJH_STDX_ROOT →
    %USERPROFILE%\.cangjie\stdx\cangjie-stdx-windows-x64-*\ → 各盘根下的
    <盘>:\cangjie-stdx\windows_x86_64_cjnative\static\stdx。需要存在 static\stdx 目录。

    版本注意：本脚本只解决"环境/配置"，不解决源码与 stdx 的 API 兼容。
    项目 cjpm.toml 声明 cjc-version，若本机工具链更新（如 1.0.5 → 1.2.0），
    stdx 公共 API 已变（实测：DerBlob 从 x509 移到 crypto.common、TlsClientConfig.domain
    改名 serverName、CertificateVerifyMode 移到 net.tls.common），编译会停在依赖层。
    此情形脚本报 [ENV] 而不是 [FAIL]，并提示换用与项目声明一致的 SDK。

    本文件必须保存为 UTF-8 with BOM：Windows PowerShell 5.1 读无 BOM 的 UTF-8 脚本
    会按 ANSI 解码，中文注释会把语法分析带崩（实测）。

.PARAMETER Libs
    只跑 libs/*，跳过根包。

.PARAMETER Root
    只跑根包，跳过 libs。

.PARAMETER Only
    只跑指定 lib（名字，不含路径），如 `-Only cjterm,cjlog`。

.PARAMETER Filter
    透传给 cjpm test 的用例过滤，如 `-Filter "*AgentsPanel*"`。

.PARAMETER Stdx
    显式指定 windows stdx 目录（应含 stdx 静态库，如 D:\cangjie-stdx\windows_x86_64_cjnative\static\stdx）。

.PARAMETER NoRestore
    调试用：不恢复派生过的 cjpm.toml（默认一定会恢复）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_win.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_win.ps1 -Only cjterm -Filter "*AgentsPanel*"
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_win.ps1 -Stdx D:\cangjie-stdx\windows_x86_64_cjnative\static\stdx
#>
[CmdletBinding()]
param(
    [switch]$Libs,
    [switch]$Root,
    [string[]]$Only = @(),
    [string]$Filter = "",
    [string]$Stdx = "",
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)

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
# cjpm/cjc 会往 stderr 写 warning，Stop 模式下原生 stderr 会被当终止错误。
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

# ---------------------------------------------------------------- 工具链
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
foreach ($sub in @("runtime\lib\windows_x86_64_cjnative", "lib\windows_x86_64_cjnative",
        "bin", "tools\bin", "tools\lib")) {
    $p = Join-Path $cjroot $sub
    if (Test-Path $p) { $env:PATH = $p + ";" + $env:PATH }
}
if (-not $env:CJH_CONFIG_DIR) {
    $env:CJH_CONFIG_DIR = Join-Path $env:TEMP ("cjh_win_test_cfg_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $env:CJH_CONFIG_DIR | Out-Null
}

Say "== cjh Windows 测试门禁 ==" "Cyan"
Say ("  仓库        : " + $repo)
Say ("  CANGJIE_HOME: " + $cjroot)
$ver = Run-Native "cjc" @("--version") $repo
$verText = (($ver.Out -split "`n" | Where-Object { $_.Trim() }) -join " | ")
Say ("  " + $verText)
Say ("  CJH_CONFIG_DIR: " + $env:CJH_CONFIG_DIR)

# 工具链版本 vs 项目声明（cjpm.toml cjc-version）
$toolchainVer = ""
$mv = [regex]::Match($verText, "Compiler:\s*([0-9]+\.[0-9]+\.[0-9]+)")
if ($mv.Success) { $toolchainVer = $mv.Groups[1].Value }
$declaredVer = ""
$mc = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $repo "cjpm.toml")),
    '(?m)^\s*cjc-version\s*=\s*"([^"]+)"')
if ($mc.Success) { $declaredVer = $mc.Groups[1].Value }
$verMismatch = ($declaredVer -ne "" -and $toolchainVer -ne "" -and $toolchainVer -ne $declaredVer)
if ($verMismatch) {
    Say ("  ! 工具链 " + $toolchainVer + " ≠ 项目声明 cjc-version " + $declaredVer +
        "：stdx 公共 API 已变化，依赖 stdx 的包预期编不过（详见文件头说明）") "Yellow"
} else {
    Say ("  工具链版本与项目声明一致（" + $toolchainVer + "）") "DarkGray"
}

# ---------------------------------------------------------------- windows stdx 探测
function Find-WindowsStdx {
    if ($Stdx -and (Test-Path $Stdx)) { return (Resolve-Path $Stdx).Path }
    if ($env:CJH_WINDOWS_STDX -and (Test-Path $env:CJH_WINDOWS_STDX)) { return $env:CJH_WINDOWS_STDX }
    $cands = @()
    if ($env:CJH_STDX_ROOT) {
        $cands += (Join-Path $env:CJH_STDX_ROOT "windows_x86_64_cjnative\static\stdx")
        $cands += (Join-Path $env:CJH_STDX_ROOT "static\stdx")
    }
    $userRoot = Join-Path $env:USERPROFILE ".cangjie\stdx"
    if (Test-Path $userRoot) {
        $cands += Get-ChildItem $userRoot -Directory -Filter "cangjie-stdx-windows-x64-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "windows_x86_64_cjnative\static\stdx" }
    }
    # 常见手工解压位置：各盘根 \cangjie-stdx\windows_x86_64_cjnative\static\stdx
    foreach ($drv in @("C", "D", "E", "F", "G", "H")) {
        $cands += ("{0}:\cangjie-stdx\windows_x86_64_cjnative\static\stdx" -f $drv)
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return ""
}

$winStdx = Find-WindowsStdx
if ($winStdx) {
    Say ("  windows stdx: " + $winStdx) "Green"
} else {
    Say "  windows stdx: 未找到（-Stdx / CJH_WINDOWS_STDX / CJH_STDX_ROOT / ~\.cangjie\stdx / <盘>:\cangjie-stdx）" "Yellow"
}

# ---------------------------------------------------------------- 配置派生 / 恢复
$script:derivedFiles = @()

function Restore-AllConfigs {
    if ($NoRestore) { return }
    $n = 0
    foreach ($d in $script:derivedFiles) {
        if (Test-Path $d.Bak) {
            Copy-Item $d.Bak $d.File -Force
            $n += 1
        }
    }
    if ($n -gt 0) { Say ("  已恢复 " + $n + " 个 cjpm.toml（静态基线）") "DarkGray" }
}

function New-PackageConfig([string]$relPath, [string]$stdxPath, [bool]$isRoot) {
    $full = Join-Path $repo $relPath
    if (-not (Test-Path $full)) { return }
    $text = [System.IO.File]::ReadAllText($full)
    if ($isRoot -and $text -match '(?m)^\s*compile-option\s*=\s*""') {
        throw "cjpm.toml 当前是派生态（上次运行被强杀未恢复）。先恢复基线：git checkout -- cjpm.toml"
    }
    $bak = Join-Path $env:TEMP ("wintest_" + ($relPath -replace '[\\/:]', '_') + ".bak")
    [System.IO.File]::WriteAllText($bak, $text, $utf8)
    if ($isRoot) {
        # 测试不静态链接：Windows 下 --static 会被工具链静默忽略（已知上游问题），
        # 且静态链接下测试框架有崩溃史（见 scripts/test.sh 头注释）。
        $text = [regex]::Replace($text, '(?m)^\s*compile-option\s*=.*$', '  compile-option = ""')
        # Linux rpath 换 mingw 系统库（crypt32: x509；ws2_32: 网络）
        $text = [regex]::Replace($text, '(?m)^\s*link-option\s*=.*$', '  link-option = "-lcrypt32 -lws2_32"')
    }
    if ($text -notmatch 'x86_64-w64-mingw32\.bin-dependencies') {
        # 路径必须用正斜杠写进 TOML：双引号内的 \c \w 是非法转义，cjpm 会直接
        # 报 "parse the '.\cjpm.toml' file failed"（实测踩过）
        $stdxFwd = $stdxPath.Replace('\', '/')
        $text = $text + "`n[target.x86_64-w64-mingw32.bin-dependencies]`n    path-option = [`"$stdxFwd`"]`n"
    }
    [System.IO.File]::WriteAllText($full, $text, $utf8)
    $script:derivedFiles += [pscustomobject]@{ File = $full; Bak = $bak }
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

function Get-FirstErrors([string]$out, [int]$n = 6) {
    return @(($out -split "`n") | Where-Object { $_ -match "error[: ]|REASON:" } | Select-Object -First $n |
        ForEach-Object { $_.Trim() })
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
        return 0
    }
    # 版本不匹配导致的编译失败归 ENV（不是用例红），避免误导成"测试挂了"
    $isCompileErr = ($r.Out -match "failed to compile package|cjpm build failed")
    if ($isCompileErr -and $verMismatch) {
        Add-Result $label "ENV" ("工具链 " + $toolchainVer + " ≠ 声明 " + $declaredVer)
        Say ("  [ENV]  " + $label + "：工具链版本不匹配，依赖 stdx 的源码编不过") "Yellow"
        Get-FirstErrors $r.Out | ForEach-Object { Say ("         " + $_) "DarkYellow" }
        return 2
    }
    Add-Result $label "FAIL" $summary
    Say ("  [FAIL] " + $label) "Red"
    Say ("         " + $summary) "DarkGray"
    Get-FirstErrors $r.Out | ForEach-Object { Say ("         " + $_) "DarkYellow" }
    return 1
}

$exitCode = 0
try {
    # ---------------------------------------------------------- 先给"依赖 stdx 的包"派生配置
    # 必须在根包构建**之前**做完：cjpm 的 bin-dependencies 不向依赖包传播，而根包构建会
    # 顺手编译 cjllm/cjutil 等依赖包；那时它们自己的 cjpm.toml 也得有 windows 目标段，
    # 否则报 "root package 'cjllm' imports package 'stdx.crypto.x509' ... not added as a dependency"。
    $libDirs = @(Get-ChildItem (Join-Path $repo "libs") -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "cjpm.toml") } |
        Sort-Object Name)
    $stdxLibs = @($libDirs | Where-Object {
            [bool](Get-ChildItem (Join-Path $_.FullName "src") -Filter *.cj -Recurse -ErrorAction SilentlyContinue |
                Select-String -Pattern "^import stdx" -List -ErrorAction SilentlyContinue)
        })
    if ($winStdx) {
        foreach ($d in $stdxLibs) {
            New-PackageConfig ("libs/" + $d.Name + "/cjpm.toml") $winStdx $false
        }
    }

    # ------------------------------------------------------------ 根包
    if (-not $Libs) {
        Say "`n-- 根包 cjh --" "Cyan"
        if (-not $winStdx) {
            Say "  [SKIP] 缺 windows stdx（根包 import stdx.encoding.json / stdx.net.* / stdx.crypto.*）" "Yellow"
            Say "         用 -Stdx <目录> 或 CJH_WINDOWS_STDX 指定；需含 static\stdx" "DarkGray"
            Add-Result "cjh (root)" "SKIP" "缺 windows stdx"
            $exitCode = 2
        } else {
            New-PackageConfig "cjpm.toml" $winStdx $true
            $b = Run-Native "cjpm" @("build") $repo
            $warn = ([regex]::Matches($b.Out, "warning:")).Count
            if ($b.Code -eq 0) {
                Say ("  [PASS] build（warning: " + $warn + " 条）") "Green"
                $rc = Invoke-CjpmTest $repo "cjh (root)"
                if ($rc -eq 1) { $exitCode = 1 } elseif ($rc -eq 2) { $exitCode = 2 }
            } else {
                $isCompileErr = ($b.Out -match "failed to compile package")
                if ($isCompileErr -and $verMismatch) {
                    Add-Result "cjh (root)" "ENV" ("工具链 " + $toolchainVer + " ≠ 声明 " + $declaredVer)
                    Say "  [ENV]  build：工具链版本不匹配，依赖 stdx 的源码编不过" "Yellow"
                    $exitCode = 2
                } else {
                    Add-Result "cjh (root)" "FAIL" "build 失败"
                    Say "  [FAIL] build" "Red"
                    $exitCode = 1
                }
                Get-FirstErrors $b.Out | ForEach-Object { Say ("         " + $_) "DarkYellow" }
            }
        }
    }

    # ------------------------------------------------------------ libs
    if (-not $Root) {
        Say "`n-- libs/* --" "Cyan"
        foreach ($d in $libDirs) {
            if ($Only.Count -gt 0 -and ($Only -notcontains $d.Name)) { continue }
            $needsStdx = ($stdxLibs -contains $d)
            if ($needsStdx -and -not $winStdx) {
                Say ("  [SKIP] " + $d.Name + "：源码 import stdx，缺 windows stdx") "Yellow"
                Add-Result $d.Name "SKIP" "缺 windows stdx"
                $exitCode = 2
                continue
            }
            $rc = Invoke-CjpmTest $d.FullName $d.Name
            if ($rc -eq 1) { $exitCode = 1 } elseif ($rc -eq 2 -and $exitCode -eq 0) { $exitCode = 2 }
        }
    }
} finally {
    Restore-AllConfigs
}

# ---------------------------------------------------------------- 汇总
Say "`n== 汇总 ==" "Cyan"
$results | Format-Table -AutoSize Name, Status, Detail | Out-String -Width 200 | Write-Host
$passN = @($results | Where-Object { $_.Status -eq "PASS" }).Count
$failN = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$unkN = @($results | Where-Object { $_.Status -eq "SKIP" -or $_.Status -eq "ENV" }).Count
if ($failN -gt 0) {
    Say ("  PASS=" + $passN + "  FAIL=" + $failN + "  未验证(SKIP/ENV)=" + $unkN) "Red"
} else {
    Say ("  PASS=" + $passN + "  FAIL=" + $failN + "  未验证(SKIP/ENV)=" + $unkN) "Green"
}
if ($unkN -gt 0) {
    Say "`n注意：以下项没有被验证过（不是通过）：" "Yellow"
    foreach ($r in $results) {
        if ($r.Status -eq "SKIP" -or $r.Status -eq "ENV") {
            Say ("  - " + $r.Name + " [" + $r.Status + "]：" + $r.Detail) "Yellow"
        }
    }
}
Say "`nWindows 原生门禁不覆盖（仍须 Linux）：scripts/tui_pty_test.py（pty/termios）、" "DarkGray"
Say "scripts/web_smoke_test.py（起服务）、cjh --mock 端到端、发布二进制体积/ldd 核对。" "DarkGray"

Pop-Location
if ($failN -gt 0) { exit 1 }
exit $exitCode
