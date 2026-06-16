[CmdletBinding()]
param(
    # 中文文件名会被本机桌面策略删除，因此默认使用稳定的英文入口名。
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath("Desktop")) "Codex Background.lnk"),

    # 背景启动脚本默认与本安装脚本放在同一目录。
    [string]$LauncherPath = (Join-Path $PSScriptRoot "codex-background.ps1"),

    # 背景模式：image（固定单图）/ random（目录混合随机）/ video（目录随机视频）。
    [ValidateSet("image", "random", "video")]
    [string]$BackgroundMode = "random",

    # image 模式：固定图片路径；默认指向脚本同级 assets 示例图。
    [string]$ImagePath = (Join-Path $PSScriptRoot "assets\sample-background.jpg"),

    # random / video 模式：媒体目录（图片视频可混放）；默认指向脚本同级 assets。
    [string]$MediaDirectory = (Join-Path $PSScriptRoot "assets"),

    # 写入快捷方式的背景透明度（兜底默认值）；图片/视频可分别用下面两个参数覆盖。
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.15,

    # 图片背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$ImageOpacity = 0,

    # 视频背景透明度；未指定（<=0）时回退到 $Opacity。默认 0.2。
    [ValidateRange(0, 1.0)]
    [double]$VideoOpacity = 0.2,

    # 运行时轮换间隔（秒），默认 60 分钟；0 = 不轮换。
    [ValidateRange(0, 86400)]
    [int]$RotateInterval = 3600,

    # Codex++ 主程序路径；留空（默认）时自动探测。
    # 本工具走 Codex++ launcher 启动 Codex（方案 C），因此依赖 Codex++ 已安装。
    [string]$CodexPlusLauncherPath = "",

    # 无控制台启动器源码和编译产物默认与安装脚本放在同一目录。
    [string]$NativeLauncherSourcePath = (Join-Path $PSScriptRoot "codex-background-launcher.cs"),

    [string]$NativeLauncherPath = (Join-Path $PSScriptRoot "codex-background-launcher.exe"),

    # 可手动指定 PowerShell；留空时优先选择 PowerShell 7。
    [string]$PowerShellPath = "",

    # 可手动指定 C# compiler；留空时使用系统 .NET Framework 64 位版本。
    [string]$CSharpCompilerPath = "",

    # 是否在快捷方式里写入 -SuppressCodexPlus 开关（持续压制 Codex++ 静态背景图）。
    # Codex++ 背景图默认应在 Codex++ 设置里关闭；此开关作保险，默认关闭。
    [switch]$SuppressCodexPlus
)

$ErrorActionPreference = "Stop"

function Find-CodexPlusLauncher {
    # 自动探测本机 Codex++ 主程序（codex-plus-plus.exe）路径。
    # 探测顺序：常见安装目录 → 注册表卸载项 → 桌面/开始菜单快捷方式。

    # 1. 常见安装目录。
    $commonCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Codex++\codex-plus-plus.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Codex++\Codex++.exe")
    )
    foreach ($candidate in $commonCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    # 2. 注册表卸载项（DisplayName 含 "Codex++"，反推 InstallLocation）。
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        $entries = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.DisplayName -match "Codex\+\+" }
        foreach ($entry in $entries) {
            foreach ($propName in @("InstallLocation", "DisplayIcon", "UninstallString")) {
                $val = $entry.$propName
                if (-not $val) { continue }
                $cleaned = $val.Trim('"').Trim()
                $dir = if (Test-Path $cleaned -PathType Container) { $cleaned }
                       elseif (Test-Path $cleaned -PathType Leaf) { Split-Path -Parent $cleaned }
                       else {
                           $firstToken = ($cleaned -split '\s+')[0].Trim('"')
                           if (Test-Path $firstToken -PathType Leaf) { Split-Path -Parent $firstToken }
                       }
                if ($dir) {
                    $candidate = Join-Path $dir "codex-plus-plus.exe"
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        return $candidate
                    }
                }
            }
        }
    }

    # 3. 桌面 / 开始菜单快捷方式（Codex++.lnk 读 TargetPath）。
    $lnkDirs = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"),
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs")
    )
    foreach ($dir in $lnkDirs) {
        if (-not (Test-Path $dir)) { continue }
        $lnks = Get-ChildItem $dir -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "Codex\+\+" }
        foreach ($lnk in $lnks) {
            try {
                $sh = New-Object -ComObject WScript.Shell
                $target = $sh.CreateShortcut($lnk.FullName).TargetPath
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sh)
                if ($target -and $target -match "codex-plus-plus\.exe$" -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                    return $target
                }
            } catch {}
        }
    }

    return $null
}

function Find-CodexIcon {
    # 探测 Codex MSIX 安装目录下的 Codex.exe，用于快捷方式图标。
    try {
        $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction Stop | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $icon = Join-Path $pkg.InstallLocation "app\Codex.exe"
            if (Test-Path -LiteralPath $icon -PathType Leaf) {
                return $icon
            }
        }
    } catch {}

    # 兜底：常见 WindowsApps 路径（版本号会变，用通配扫描）。
    $wildcard = Join-Path $env:ProgramFiles "WindowsApps\OpenAI.Codex_*\app\Codex.exe"
    $found = Get-ChildItem -Path $wildcard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

try {
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "背景启动脚本不存在：$LauncherPath"
    }

    # 按模式校验资源：image 校验图片，random/video 校验媒体目录。
    $resolvedMediaPath = ""
    if ($BackgroundMode -eq "image") {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw "背景图片不存在：$ImagePath"
        }
        $resolvedMediaPath = (Resolve-Path -LiteralPath $ImagePath).Path
    }
    else {
        if ([string]::IsNullOrWhiteSpace($MediaDirectory)) {
            throw "$BackgroundMode 模式必须指定 -MediaDirectory 参数。"
        }
        if (-not (Test-Path -LiteralPath $MediaDirectory -PathType Container)) {
            throw "媒体目录不存在：$MediaDirectory"
        }
    }

    if (-not (Test-Path -LiteralPath $NativeLauncherSourcePath -PathType Leaf)) {
        throw "无控制台启动器源码不存在：$NativeLauncherSourcePath"
    }

    # Codex++ launcher 路径：未指定或不存在时自动探测。
    # 方案 C 依赖 Codex++ 启动 Codex，故 Codex++ 是前置依赖。
    if ([string]::IsNullOrWhiteSpace($CodexPlusLauncherPath) -or -not (Test-Path -LiteralPath $CodexPlusLauncherPath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($CodexPlusLauncherPath)) {
            Write-Warning "指定的 Codex++ 主程序不存在，尝试自动探测：$CodexPlusLauncherPath"
        }
        $detected = Find-CodexPlusLauncher
        if ($detected) {
            $CodexPlusLauncherPath = $detected
            Write-Host "已自动探测到 Codex++：$CodexPlusLauncherPath"
        } else {
            throw "未找到 Codex++ 主程序（codex-plus-plus.exe）。本工具走 Codex++ launcher 启动 Codex，请先安装 Codex++，或用 -CodexPlusLauncherPath 手动指定路径。"
        }
    }

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $powerShellCommand = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
        if (-not $powerShellCommand) {
            $powerShellCommand = Get-Command "powershell.exe" -ErrorAction Stop
        }
        $PowerShellPath = $powerShellCommand.Source
    }

    if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
        throw "PowerShell 主程序不存在：$PowerShellPath"
    }

    if ([string]::IsNullOrWhiteSpace($CSharpCompilerPath)) {
        $compilerCandidates = @(
            (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
            (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
        )
        $CSharpCompilerPath = $compilerCandidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }

    if (-not (Test-Path -LiteralPath $CSharpCompilerPath -PathType Leaf)) {
        throw "C# compiler 不存在：$CSharpCompilerPath"
    }

    $resolvedLauncherPath = (Resolve-Path -LiteralPath $LauncherPath).Path
    $resolvedMediaDirectory = if ($MediaDirectory) { (Resolve-Path -LiteralPath $MediaDirectory).Path } else { "" }
    $resolvedCodexPlusPath = (Resolve-Path -LiteralPath $CodexPlusLauncherPath).Path
    $resolvedNativeLauncherSourcePath = (Resolve-Path -LiteralPath $NativeLauncherSourcePath).Path
    $resolvedPowerShellPath = (Resolve-Path -LiteralPath $PowerShellPath).Path
    $resolvedCSharpCompilerPath = (Resolve-Path -LiteralPath $CSharpCompilerPath).Path
    $resolvedNativeLauncherPath = [IO.Path]::GetFullPath($NativeLauncherPath)
    $opacityLiteral = $Opacity.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    # 构造双透明度参数片段：仅当指定了 ImageOpacity/VideoOpacity（>0）时才加入，避免无谓传参。
    $opacityArgs = "-Opacity `"$opacityLiteral`""
    if ($ImageOpacity -gt 0) {
        $opacityArgs += " -ImageOpacity $ImageOpacity"
    }
    if ($VideoOpacity -gt 0) {
        $opacityArgs += " -VideoOpacity $VideoOpacity"
    }
    $nativeLauncherDirectory = Split-Path -Parent $resolvedNativeLauncherPath
    $shortcutDirectory = Split-Path -Parent $ShortcutPath

    if (-not (Test-Path -LiteralPath $nativeLauncherDirectory -PathType Container)) {
        # 用户可把编译产物放到自定义目录，安装时自动补齐目录。
        New-Item -ItemType Directory -Path $nativeLauncherDirectory -Force | Out-Null
    }

    $sourceWriteTime = (Get-Item -LiteralPath $resolvedNativeLauncherSourcePath).LastWriteTimeUtc
    $needsLauncherBuild = (
        -not (Test-Path -LiteralPath $resolvedNativeLauncherPath -PathType Leaf) -or
        (Get-Item -LiteralPath $resolvedNativeLauncherPath).LastWriteTimeUtc -lt $sourceWriteTime
    )

    if ($needsLauncherBuild) {
        # /target:winexe 让启动器自身没有控制台，再由它隐藏启动 PowerShell。
        Remove-Item -LiteralPath $resolvedNativeLauncherPath -Force -ErrorAction SilentlyContinue
        $compilerOutput = & $resolvedCSharpCompilerPath `
            "/nologo" `
            "/target:winexe" `
            "/optimize+" `
            "/out:$resolvedNativeLauncherPath" `
            $resolvedNativeLauncherSourcePath 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "无控制台启动器编译失败：$($compilerOutput -join [Environment]::NewLine)"
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedNativeLauncherPath -PathType Leaf)) {
        throw "无控制台启动器构建失败：$resolvedNativeLauncherPath"
    }

    if (-not (Test-Path -LiteralPath $shortcutDirectory -PathType Container)) {
        # 支持测试目录或用户指定目录尚未创建的情况。
        New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
    }

    # 按模式构造 Arguments：image 模式传 ImagePath，random/video 模式传 MediaDirectory。
    $modeArgs = switch ($BackgroundMode) {
        "image" {
            "-BackgroundMode image -ImagePath `"$resolvedMediaPath`""
        }
        default {
            "-BackgroundMode $BackgroundMode -MediaDirectory `"$resolvedMediaDirectory`""
        }
    }

    # 构造快捷方式完整参数：launcher.exe pwsh ps1 [模式/媒体] [透明度] [轮换] [端口] [Codex++路径] [压制开关]
    $fullArgs = (
        "`"$resolvedPowerShellPath`" " +
        "`"$resolvedLauncherPath`" " +
        "$modeArgs " +
        "$opacityArgs " +
        "-RotateInterval $RotateInterval " +
        "-CodexPlusLauncherPath `"$resolvedCodexPlusPath`""
    )
    if ($SuppressCodexPlus) {
        $fullArgs += " -SuppressCodexPlus"
    }

    # 探测 Codex 图标，取不到则用 launcher 自身图标。
    $codexIcon = Find-CodexIcon
    $iconLocation = if ($codexIcon) { "$codexIcon,0" } else { "$resolvedNativeLauncherPath,0" }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $resolvedNativeLauncherPath
    $shortcut.Arguments = $fullArgs
    $shortcut.WorkingDirectory = Split-Path -Parent $resolvedLauncherPath
    $shortcut.IconLocation = $iconLocation
    $shortcut.Description = "无控制台启动带可配置背景的 Codex（模式：$BackgroundMode）"
    # native launcher 是 Windows GUI 程序，普通窗口样式不会影响 Codex 窗口。
    $shortcut.WindowStyle = 1
    $shortcut.Save()

    # 主动释放 COM 对象，确保快捷方式在脚本退出前完成落盘。
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)

    Write-Host "已创建 Codex 背景版快捷方式：$ShortcutPath"
    Write-Host "Codex++ 主程序：$resolvedCodexPlusPath"
    Write-Host "背景模式：$BackgroundMode"
    if ($BackgroundMode -eq "image") {
        Write-Host "图片：$resolvedMediaPath"
    }
    else {
        Write-Host "媒体目录：$resolvedMediaDirectory"
    }
    # 计算实际生效的双透明度（与核心脚本一致：<=0 时回退到 $Opacity），用于日志显示。
    $effImg = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
    $effVid = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }
    if ([Math]::Abs($effImg - $effVid) -lt 0.001) {
        Write-Host "透明度：$effImg（图片视频统一）"
    } else {
        Write-Host "透明度：图片 $effImg / 视频 $effVid"
    }
    Write-Host "轮换间隔：$(if ($RotateInterval -gt 0) { "$RotateInterval 秒" } else { "关闭" })"
    if ($SuppressCodexPlus) {
        Write-Host "Codex++ 背景压制：开启"
    }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
