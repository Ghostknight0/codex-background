[CmdletBinding()]
param(
    # 背景模式：image（固定单图）/ random（目录混合随机）/ video（目录随机视频）。
    [ValidateSet("image", "random", "video")]
    [string]$BackgroundMode = "random",

    # 固定图片路径（image 模式用）；默认指向脚本同级的 assets 示例图。
    [string]$ImagePath = (Join-Path $PSScriptRoot "assets\sample-background.jpg"),

    # 媒体目录（random / video 模式用，图片视频可混放同一目录）；默认指向脚本同级 assets。
    [string]$MediaDirectory = (Join-Path $PSScriptRoot "assets"),

    # 固定视频路径（可选；image 模式下想直接放视频时用）。
    [string]$VideoPath,

    # 运行时轮换间隔（秒），默认 60 分钟；0 表示不轮换，仅在启动时随机一次。
    [ValidateRange(0, 86400)]
    [int]$RotateInterval = 3600,

    # 覆盖层透明度（兜底默认值）；图片/视频可分别用下面两个参数覆盖。
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.15,

    # 图片背景透明度；未指定（<=0）时回退到 $Opacity。
    [ValidateRange(0, 1.0)]
    [double]$ImageOpacity = 0,

    # 视频背景透明度；未指定（<=0）时回退到 $Opacity。
    # 默认 0.2（比图片 0.15 略高，视频动态内容需要更明显）。
    [ValidateRange(0, 1.0)]
    [double]$VideoOpacity = 0.2,

    # Codex 桌面应用的 CDP 调试端口（由 Codex++ launcher 在激活 Codex 时附加）。
    [ValidateRange(1, 65535)]
    [int]$DebugPort = 9229,

    # Codex++ 主程序（codex-plus-plus.exe）路径，用于方案 C 启动 Codex。
    # 留空时自动探测本机 Codex++ 安装位置。
    [string]$CodexPlusLauncherPath = "",

    # 是否压制 Codex++ 的静态背景图覆盖层（codex-plus-image-overlay）。
    # Codex++ 背景图默认应在 Codex++ 设置里关闭；本开关作保险，应对升级/配置重置导致诈尸。
    [switch]$SuppressCodexPlus,

    # 不启动 Codex++/Codex，只连接已在跑的 CDP 端口注入（适合 Codex 已开的情况）。
    [switch]$NoLaunch,

    # Codex MSIX 应用的 AUMID（无 Codex++ 时用于自激活 Codex）。留空则自动探测。
    [string]$CodexAumid = "",

    # 仅验证参数和资源，不连接或启动 Codex。
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

# ============================================================
# 读取 config.json：未显式传命令行参数时用 config 覆盖脚本默认值。
# 优先级：命令行参数 > config.json > 脚本默认值。
# 这样快捷方式无需携带参数（避免 .lnk 属性保存截断），配置由 config.json 提供。
# ============================================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        # 白名单：只认这些配置项，避免未知键污染变量。
        $configKeys = @("BackgroundMode", "ImagePath", "MediaDirectory", "VideoPath", "RotateInterval", "Opacity", "ImageOpacity", "VideoOpacity")
        foreach ($key in $configKeys) {
            # 只在 config 有该键、且命令行未显式传该参数时，才用 config 值覆盖默认。
            if ($config.ContainsKey($key) -and -not $PSBoundParameters.ContainsKey($key)) {
                Set-Variable -Name $key -Value $config[$key] -Scope Script
            }
        }
    }
    catch {
        Write-Warning "config.json 解析失败，已忽略（使用默认值）：$($_.Exception.Message)"
    }
}

# 支持的媒体扩展名分类。
$script:ImageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")
$script:VideoExtensions = @(".mp4", ".webm", ".mov", ".mkv", ".avi")

function Get-MediaMimeType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg"  { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png"  { return "image/png" }
        ".gif"  { return "image/gif" }
        ".webp" { return "image/webp" }
        ".bmp"  { return "image/bmp" }
        ".mp4"  { return "video/mp4" }
        ".webm" { return "video/webm" }
        ".mov"  { return "video/quicktime" }
        ".mkv"  { return "video/x-matroska" }
        ".avi"  { return "video/x-msvideo" }
        default { throw "不支持的媒体格式：$([IO.Path]::GetExtension($Path))" }
    }
}

function Get-MediaType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:ImageExtensions -contains $ext) { return "image" }
    if ($script:VideoExtensions -contains $ext) { return "video" }
    return $null
}

function Get-RandomMediaFromDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [ValidateSet("random", "video")]
        [string]$Mode
    )

    $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop)
    $imagePool = @()
    $videoPool = @()
    foreach ($f in $files) {
        $type = Get-MediaType -Path $f.FullName
        if (-not $type) { continue }
        $entry = [pscustomobject]@{
            Path     = $f.FullName
            Type     = $type
            FileName = $f.Name
        }
        if ($type -eq "video") { $videoPool += $entry }
        else { $imagePool += $entry }
    }

    if ($Mode -eq "video") {
        if ($videoPool.Count -eq 0) {
            throw "媒体目录中没有可用的视频文件：$Directory"
        }
        return ($videoPool | Get-Random)
    }

    # random 模式：图片视频 1:1 比例（先 50/50 选类型，再从对应池随机选一个）。
    if ($imagePool.Count -eq 0 -and $videoPool.Count -eq 0) {
        throw "媒体目录中没有可用的媒体文件：$Directory"
    }
    if ($imagePool.Count -eq 0) { return ($videoPool | Get-Random) }
    if ($videoPool.Count -eq 0) { return ($imagePool | Get-Random) }

    if ((Get-Random -Maximum 2) -eq 0) {
        return ($imagePool | Get-Random)
    }
    return ($videoPool | Get-Random)
}

function ConvertTo-MediaDataURL {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # 把媒体文件读成 base64 dataURL。
    # Codex 页面 CSP 禁止 http://127.0.0.1，但允许 data: 和 blob:，
    # 因此所有媒体必须以 dataURL（图片直接用）或经页面转 blob URL（视频）的方式注入。
    $mime = Get-MediaMimeType -Path $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    $base64 = [Convert]::ToBase64String($bytes)
    return @{
        DataUrl = "data:$mime;base64,$base64"
        Type    = Get-MediaType -Path $Path
        Bytes   = $bytes.Length
        Mime    = $mime
        FileName = [IO.Path]::GetFileName($Path)
    }
}

function Test-CdpAvailable {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutSeconds = 2,

        # 连续失败多少次才判定端口不可用（容忍短暂抖动/大文件传输期间的响应变慢）。
        [int]$RequiredFailures = 3
    )

    # 单次探测：不只是 HTTP 通就行，还要验证返回的确实是 CDP（有 webSocketDebuggerUrl 字段）。
    # 避免端口被别的程序占用时拿到非 CDP 响应却误判为可用。
    $tries = if ($RequiredFailures -gt 1) { $RequiredFailures } else { 1 }
    for ($i = 1; $i -le $tries; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -Method Get -TimeoutSec $TimeoutSeconds
            # CDP /json/version 必含 webSocketDebuggerUrl；非 CDP 服务不会返回这个字段。
            if ($resp -and $resp.webSocketDebuggerUrl) {
                return $true
            }
            # HTTP 通但不是 CDP（端口被其他程序占用）——视为不可用，不重试。
            return $false
        }
        catch {
            if ($i -lt $tries) { Start-Sleep -Milliseconds 500 }
        }
    }
    return $false
}

function Find-CodexCdpPort {
    # 从正在运行的 Codex.exe 进程命令行解析 --remote-debugging-port=NNNN。
    # 新版 Codex++ 不再固定用 9229，而是动态端口（如 10373），必须实时探测。
    # 返回端口数字；找不到返回 $null。
    try {
        $procs = Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Codex.exe' -and $_.CommandLine -match 'remote-debugging-port=(\d+)'
        }
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'remote-debugging-port=(\d+)') {
                $port = [int]$Matches[1]
                # 确认该端口确实在监听（避免解析到子进程的无效端口）。
                if (Test-CdpAvailable -Port $port -TimeoutSeconds 1 -RequiredFailures 1) {
                    return $port
                }
            }
        }
    } catch {}
    return $null
}

function Find-CodexPlusLauncher {
    # 自动探测本机 Codex++ 主程序（codex-plus-plus.exe）路径。
    $commonCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Codex++\codex-plus-plus.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Codex++\Codex++.exe")
    )
    foreach ($candidate in $commonCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

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

function Start-CodexViaLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$LauncherPath
    )

    Write-Host "正在通过 Codex++ 启动 Codex：$LauncherPath"
    return Start-Process -FilePath $LauncherPath
}

function Stop-CodexProcesses {
    # 优雅关闭当前所有 Codex 主进程（自激活前需重启 Codex 以附加 CDP 端口）。
    # 只杀名为 Codex 的进程，不动其他程序。
    $processes = @(Get-Process -Name "Codex" -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return }

    Write-Host "正在关闭 Codex（重启以开启调试端口）..."
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-Process -Name "Codex" -ErrorAction SilentlyContinue)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $remaining.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
}

function Get-CodexAumid {
    param(
        # 可选手动指定 AUMID，留空则自动探测。
        [string]$Aumid = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Aumid)) {
        return $Aumid
    }

    # 动态探测：Get-AppxPackage 取 PackageFamilyName，拼成 AUMID（PackageFamilyName!App）。
    $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg -or -not $pkg.PackageFamilyName) {
        throw "未找到 OpenAI.Codex MSIX 包。请从 Microsoft Store 安装 Codex 桌面版。"
    }
    return ($pkg.PackageFamilyName + "!App")
}

function Start-CodexViaMsix {
    # 无 Codex++ 时的回退启动：用 COM IApplicationActivationManager 激活 Codex MSIX，
    # 并附加 --remote-debugging-port 让 Codex 自己开启 CDP 端口（不依赖 Codex++）。
    # CDP 端口只在进程启动时生效，故必须先关闭已运行的 Codex 再重新激活（会中断当前会话）。
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [string]$Aumid = ""
    )

    $resolvedAumid = Get-CodexAumid -Aumid $Aumid

    # 先关闭已运行的 Codex（CDP 参数只在启动时生效）。
    Stop-CodexProcesses
    Start-Sleep -Milliseconds 500

    # COM 激活的 C# 代码（GUID/CLSID 来自 IApplicationActivationManager 标准定义）。
    $activationCode = @'
using System;
using System.Runtime.InteropServices;

[Flags]
public enum ActivateOptions {
    None = 0x00000000,
    DesignMode = 0x00000001,
    NoErrorUI = 0x00000002,
    NoSplashScreen = 0x00000004
}

[ComImport]
[Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IApplicationActivationManager {
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        ActivateOptions options,
        out UInt32 processId);
}

[ComImport]
[Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class ApplicationActivationManager {}

public static class CodexMsixActivator {
    public static UInt32 Activate(string aumid, string arguments) {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        UInt32 pid;
        int hr = manager.ActivateApplication(aumid, arguments, ActivateOptions.None, out pid);
        Marshal.ThrowExceptionForHR(hr);
        return pid;
    }
}
'@

    # 避免重复 Add-Type（同一 AppDomain 内只能定义一次）。
    if (-not ("CodexMsixActivator" -as [type])) {
        Add-Type -TypeDefinition $activationCode -Language CSharp
    }

    # 激活参数：开启 CDP 端口 + 允许回环 origin（Chromium 安全校验）。
    $arguments = "--remote-debugging-port=$Port --remote-allow-origins=*"

    Write-Host "正在直接激活 Codex（MSIX）：$resolvedAumid"
    $codexPid = [CodexMsixActivator]::Activate($resolvedAumid, $arguments)
    Write-Host "Codex 已激活（PID：$codexPid），等待 CDP 端口 $Port ..."
}

function Wait-CdpTargets {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutSeconds = 90
    )

    $endpoint = "http://127.0.0.1:$Port/json/list"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        try {
            $rawTargets = Invoke-RestMethod -Uri $endpoint -Method Get -TimeoutSec 2
            if ($rawTargets -isnot [System.Array]) {
                $rawTargets = @($rawTargets)
            }
            else {
                $rawTargets = @($rawTargets)
            }

            # Codex 上有两个 page：主窗口 index.html 与头像浮窗 avatar-overlay。
            # 只注入主窗口，浮窗排除。用 List 显式收集，避免 @(...|Where) 单元素时枚举属性的陷阱。
            $injectableTargets = [Collections.Generic.List[object]]::new()
            foreach ($t in $rawTargets) {
                if ($t.webSocketDebuggerUrl -and
                    $t.type -eq "page" -and
                    $t.url -notmatch "avatar-overlay" -and
                    $t.title -notmatch "DevTools") {
                    $injectableTargets.Add($t)
                }
            }

            if ($injectableTargets.Count -gt 0) {
                return ,$injectableTargets
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)

    $detail = if ($lastError) { "；最后错误：$lastError" } else { "" }
    throw "等待 Codex CDP 页面超时：$endpoint$detail"
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [string]$Method,

        $Parameters = @{},

        [int]$CommandId = 1
    )

    # Chromium 对同一 CDP target 的 WebSocket 快速重连偶发拒绝（HTTP 500 而非 101）。
    # 这里对连接阶段做有限重试，发命令/收响应阶段不重试（避免重复执行）。
    $maxAttempts = 3
    $socket = $null
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))

    try {
        $connected = $false
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $socket = [Net.WebSockets.ClientWebSocket]::new()
            try {
                $socket.ConnectAsync([Uri]$WebSocketUrl, $cancellation.Token).GetAwaiter().GetResult()
                $connected = $true
                break
            }
            catch {
                if ($socket) { try { $socket.Dispose() } catch {} }
                $socket = $null
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Milliseconds (300 * $attempt)
                }
                else {
                    throw
                }
            }
        }
        if (-not $connected) {
            throw "无法建立到 $WebSocketUrl 的 CDP WebSocket 连接（重试 $maxAttempts 次均失败）。"
        }

        $payload = [ordered]@{
            id     = $CommandId
            method = $Method
            params = $Parameters
        } | ConvertTo-Json -Compress -Depth 20

        $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $payloadSegment = [ArraySegment[byte]]::new($payloadBytes)
        $socket.SendAsync(
            $payloadSegment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cancellation.Token
        ).GetAwaiter().GetResult()

        do {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $buffer = [byte[]]::new(65536)
                    $bufferSegment = [ArraySegment[byte]]::new($buffer)
                    $receiveResult = $socket.ReceiveAsync(
                        $bufferSegment,
                        $cancellation.Token
                    ).GetAwaiter().GetResult()

                    if ($receiveResult.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw "CDP WebSocket 在返回命令结果前关闭。"
                    }

                    $stream.Write($buffer, 0, $receiveResult.Count)
                } while (-not $receiveResult.EndOfMessage)

                $responseText = [Text.Encoding]::UTF8.GetString($stream.ToArray())
                $response = $responseText | ConvertFrom-Json
            }
            finally {
                $stream.Dispose()
            }
        } while ($response.id -ne $CommandId)

        if ($response.error) {
            throw "CDP 命令失败 [$Method]：$($response.error.message)"
        }

        return $response.result
    }
    finally {
        if ($socket) {
            if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
                try {
                    $socket.CloseAsync(
                        [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                        "done",
                        [Threading.CancellationToken]::None
                    ).GetAwaiter().GetResult()
                }
                catch {}
            }
            try { $socket.Dispose() } catch {}
        }

        $cancellation.Dispose()
    }
}

function New-OverlayJavaScript {
    param(
        # 初始媒体 dataURL。分块架构下可为空（注入空壳，随后由 Send-MediaToPage 推送）。
        [string]$InitialDataURL = "",

        [Parameter(Mandatory)]
        [ValidateSet("image", "video")]
        [string]$MediaType,

        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$ImageOpacityValue,

        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$VideoOpacityValue,

        [switch]$SuppressCodexPlus
    )

    $sourceLiteral = ConvertTo-Json -InputObject $InitialDataURL -Compress
    $imageOpacityLiteral = $ImageOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $videoOpacityLiteral = $VideoOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $typeLiteral = ConvertTo-Json -InputObject $MediaType -Compress

    # 压制 Codex++ 静态背景图（保险开关）。
    $suppressBlock = if ($SuppressCodexPlus) {
        @'
    const CODEX_PLUS_OVERLAY_ID = "codex-plus-image-overlay";
    function suppressCodexPlusOverlay() {
        const el = document.getElementById(CODEX_PLUS_OVERLAY_ID);
        if (el) el.remove();
    }
    suppressCodexPlusOverlay();
    try {
        new MutationObserver(suppressCodexPlusOverlay)
            .observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) { /* observer 失败不影响主背景 */ }
'@
    }
    else {
        ""
    }

    # 架构说明（绕开 Codex CSP）：
    #   Codex 页面 CSP 禁止 http://127.0.0.1，但允许 data: 和 blob:。
    #   - 图片：直接用 dataURL 作为 src。
    #   - 视频：dataURL 过大且 <video> 对 dataURL 支持不佳，先 fetch(dataURL)→blob→createObjectURL。
    #   轮换由 PowerShell 端定时通过 CDP 调用 window.__codexBgRotator.setMedia(dataURL, type) 实现。
    return @"
(() => {
    const overlayId = "codex-bg-rotator-overlay";
    let current = { url: $sourceLiteral, type: $typeLiteral };
    const opacityByType = { image: "$imageOpacityLiteral", video: "$videoOpacityLiteral" };
    // 视频用的 blob URL，换源时需 revoke 旧的，避免内存泄漏。
    let currentBlobUrl = "";
    // installToken：单调递增，保证只有最新的 installOverlay 调用能落盘 DOM。
    let installToken = 0;

    function opacityFor(type) {
        return opacityByType[type] || opacityByType.image;
    }

    // 把 dataURL 转成 blob URL（视频必需；图片直接用 dataURL 更快）。
    // 注意：不能用 fetch(dataURL)——会被 Codex CSP 的 connect-src 拦截。
    // 改用 atob 在 JS 层解码 base64，再构造 Blob，完全绕开网络层 CSP。
    async function toObjectUrl(dataUrl) {
        try {
            const b64 = dataUrl.split(',')[1];
            const bin = atob(b64);
            const len = bin.length;
            const u8 = new Uint8Array(len);
            for (let i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
            const mime = dataUrl.substring(5, dataUrl.indexOf(';'));
            const blob = new Blob([u8], { type: mime });
            return URL.createObjectURL(blob);
        } catch (e) {
            return "";
        }
    }

    function createElement(type, url) {
        let el;
        if (type === "video") {
            el = document.createElement("video");
            el.loop = true;
            el.muted = true;
            el.defaultMuted = true;
            el.autoplay = true;
            el.setAttribute("playsinline", "");
            el.setAttribute("webkit-playsinline", "");
            el.setAttribute("aria-hidden", "true");
        } else {
            el = document.createElement("img");
            el.alt = "";
            el.setAttribute("aria-hidden", "true");
        }
        const commonStyle = {
            position: "fixed",
            inset: "0",
            width: "100vw",
            height: "100vh",
            objectFit: "cover",
            objectPosition: "center center",
            opacity: opacityFor(type),
            pointerEvents: "none",
            zIndex: "2147483646",
            userSelect: "none"
        };
        for (const k in commonStyle) {
            el.style[k] = commonStyle[k];
        }
        el.src = url;
        return el;
    }

    async function installOverlay() {
        const root = document.documentElement;
        if (!root) return false;

        // 快照本次要安装的媒体，防止 await 期间 current 被 setMedia 改动导致串台。
        const snapType = current.type;
        const snapUrl = current.url;
        // 单调递增的 install token：只有最新的 installOverlay 调用才能最终落盘 DOM，
        // 避免 await blob 转换期间旧调用把元素改回旧媒体。
        const myToken = ++installToken;

        // 视频：dataURL 需先 atob→blob 绕开 CSP；但若已是 blob: URL（分块 finalize 产物）则直接用。
        const isBlob = snapUrl.startsWith("blob:");
        const useUrl = (snapType === "video" && !isBlob)
            ? await toObjectUrl(snapUrl)
            : snapUrl;
        if (!useUrl) return false;

        // await 期间若有更新的 setMedia 抢占，则放弃本次安装。
        if (myToken !== installToken) return false;

        let existing = document.getElementById(overlayId);
        if (existing) {
            const sameType = (existing.tagName.toLowerCase() === snapType);
            if (sameType) {
                existing.src = useUrl;
                existing.style.opacity = opacityFor(snapType);
                if (snapType === "video") ensurePlaying(existing);
                return true;
            }
            existing.remove();
        }
        const el = createElement(snapType, useUrl);
        el.id = overlayId;
        root.appendChild(el);
        if (snapType === "video") ensurePlaying(el);
        return true;
    }

    // video 动态设置 src 后 autoplay 不一定触发，显式 play() 并监听 canplay/loadeddata。
    // 必须（重）设 muted=true：某些情况下换 src 会重置 muted，导致 autoplay 策略拒绝播放。
    function ensurePlaying(videoEl) {
        try { videoEl.muted = true; videoEl.defaultMuted = true; } catch (e) {}
        const tryPlay = () => {
            try { videoEl.muted = true; } catch (e) {}
            const p = videoEl.play();
            if (p && p.catch) p.catch(() => {});
        };
        videoEl.addEventListener("loadeddata", tryPlay, { once: true });
        videoEl.addEventListener("canplay", tryPlay, { once: true });
        tryPlay();
    }

    // 供 PowerShell 端通过 CDP Runtime.evaluate 调用，实现轮换。
    // 用法：window.__codexBgRotator.setMedia("data:...", "image"|"video")
    window.__codexBgRotator = {
        setMedia: (dataUrl, type) => {
            current.url = dataUrl;
            current.type = type;
            installOverlay();
        },
        version: "1.1"
    };

    // ============================================================
    // 分块传输支持：大文件拆成多块 base64 经多次 CDP 推送，避免单次 payload 过大卡死。
    // 流程：beginChunkedMedia(id,mime,type) → appendChunk(id,b64)* → finalizeChunkedMedia(id)
    // finalize 时拼接所有块 → atob 解码 → Blob → setMedia。
    // ============================================================
    const chunkBuffers = {};  // id → { mime, type, parts: [b64...] }

    window.__codexBgRotator.beginChunkedMedia = function(id, mime, type) {
        chunkBuffers[id] = { mime: mime, type: type, parts: [] };
    };
    window.__codexBgRotator.appendChunk = function(id, b64Chunk) {
        const buf = chunkBuffers[id];
        if (buf) buf.parts.push(b64Chunk);
    };
    window.__codexBgRotator.finalizeChunkedMedia = function(id) {
        return new Promise((resolve) => {
            const buf = chunkBuffers[id];
            if (!buf) { resolve(false); return; }
            delete chunkBuffers[id];
            try {
                const fullB64 = buf.parts.join('');
                const bin = atob(fullB64);
                const len = bin.length;
                const u8 = new Uint8Array(len);
                for (let i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
                const blobUrl = URL.createObjectURL(new Blob([u8], { type: buf.mime }));
                // 直接走 setMedia 用 blob URL（图片视频通用，跳过 toObjectUrl 重复转换）。
                current.url = blobUrl;
                current.type = buf.type;
                installOverlay();
                resolve(true);
            } catch (e) {
                resolve(false);
            }
        });
    };

    $suppressBlock

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", installOverlay, { once: true });
    }
    installOverlay();
    // 延迟保险注入只在启动阶段做，且要尊重 installToken（避免和轮换打架）。
    setTimeout(() => { if (installToken <= 1) installOverlay(); }, 500);
    setTimeout(() => { if (installToken <= 1) installOverlay(); }, 2000);

    return true;
})();
"@
}

function Install-CodexBackground {
    param(
        [Parameter(Mandatory)]
        $Targets,

        [Parameter(Mandatory)]
        [string]$JavaScript
    )

    if ($Targets -is [array]) {
        $targetList = @($Targets)
    }
    else {
        $targetList = @($Targets)
    }

    $successCount = 0
    $failureMessages = [Collections.Generic.List[string]]::new()

    foreach ($target in $targetList) {
        $wsUrl = [string]$target.webSocketDebuggerUrl
        $targetTitle = [string]$target.title
        $targetUrl = [string]$target.url
        if ([string]::IsNullOrWhiteSpace($wsUrl)) {
            $failureMessages.Add("$targetTitle：webSocketDebuggerUrl 为空")
            continue
        }
        try {
            # 新文档注册保证页面刷新或导航后仍会重新创建背景层。
            Invoke-CdpCommand `
                -WebSocketUrl $wsUrl `
                -Method "Page.addScriptToEvaluateOnNewDocument" `
                -Parameters @{ source = $JavaScript } `
                -CommandId 1 | Out-Null

            # 当前文档不会触发上面的注册脚本，因此需要立即执行一次。
            Invoke-CdpCommand `
                -WebSocketUrl $wsUrl `
                -Method "Runtime.evaluate" `
                -Parameters @{
                expression    = $JavaScript
                returnByValue = $true
                awaitPromise  = $true
            } `
                -CommandId 2 | Out-Null

            $successCount++
            Write-Host "已注入页面：$targetTitle （$targetUrl）"
        }
        catch {
            $failureMessages.Add("$targetTitle：$($_.Exception.Message)")
        }
    }

    if ($successCount -eq 0) {
        throw "未能向任何 Codex 页面注入背景。$($failureMessages -join '；')"
    }

    if ($failureMessages.Count -gt 0) {
        Write-Warning "部分页面注入失败：$($failureMessages -join '；')"
    }

    return $successCount
}

function Send-MediaToPage {
    # 通过 CDP 向页面推送新媒体（分块传输，支持大文件）。
    # 小文件（< 阈值）走一次性 setMedia；大文件走分块 begin/append*/finalize。
    param(
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("image", "video")]
        [string]$MediaType,

        # 分块阈值（字节）。文件小于此值走一次性传输；大于则分块。
        [long]$ChunkThreshold = 3MB,

        # 每块 base64 字符数（原始字节约 75%）。512K 字符 ≈ 384KB 原始，CDP 安全。
        [int]$ChunkSize = 524288
    )

    $mime = Get-MediaMimeType -Path $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    $base64 = [Convert]::ToBase64String($bytes)
    $rotator = "window.__codexBgRotator"

    if ($bytes.Length -lt $ChunkThreshold) {
        # 小文件：一次性 setMedia（dataURL）。
        $dataUrl = "data:$mime;base64,$base64"
        $urlLit = ConvertTo-Json -InputObject $dataUrl -Compress
        $typeLit = ConvertTo-Json -InputObject $MediaType -Compress
        $expr = "$rotator && $rotator.setMedia($urlLit, $typeLit); true"
        Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
            -Parameters @{ expression = $expr; returnByValue = $true } -CommandId 1 | Out-Null
        return
    }

    # 大文件：分块传输。
    $mediaId = "m" + (Get-Date -Format "HHmmssfff") + (Get-Random -Maximum 10000)
    $mimeLit = ConvertTo-Json -InputObject $mime -Compress
    $typeLit = ConvertTo-Json -InputObject $MediaType -Compress
    $idLit = ConvertTo-Json -InputObject $mediaId -Compress

    # begin
    Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
        -Parameters @{ expression = "$rotator && $rotator.beginChunkedMedia($idLit, $mimeLit, $typeLit); true"; returnByValue = $true } `
        -CommandId 1 | Out-Null

    # append 逐块
    $totalChunks = [Math]::Ceiling($base64.Length / [double]$ChunkSize)
    $cmdId = 2
    for ($off = 0; $off -lt $base64.Length; $off += $ChunkSize) {
        $end = [Math]::Min($off + $ChunkSize, $base64.Length)
        $chunk = $base64.Substring($off, $end - $off)
        $chunkLit = ConvertTo-Json -InputObject $chunk -Compress
        Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
            -Parameters @{ expression = "$rotator && $rotator.appendChunk($idLit, $chunkLit); true"; returnByValue = $true } `
            -CommandId $cmdId | Out-Null
        $cmdId++
    }

    # finalize（awaitPromise 等 atob 完成）
    Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
        -Parameters @{ expression = "$rotator && $rotator.finalizeChunkedMedia($idLit)"; returnByValue = $true; awaitPromise = $true } `
        -CommandId $cmdId | Out-Null
}

function Resolve-MediaForCurrentRun {
    param(
        [string]$Mode,
        [string]$ImagePath,
        [string]$VideoPath,
        [string]$MediaDirectory
    )

    if ($Mode -eq "image") {
        if ($VideoPath) {
            $resolved = (Resolve-Path -LiteralPath $VideoPath).Path
            return @{
                Path      = $resolved
                Type      = "video"
                Directory = (Split-Path -Parent $resolved)
            }
        }
        $resolved = (Resolve-Path -LiteralPath $ImagePath).Path
        return @{
            Path      = $resolved
            Type      = (Get-MediaType -Path $resolved)
            Directory = (Split-Path -Parent $resolved)
        }
    }

    if (-not $MediaDirectory) {
        throw "$Mode 模式必须指定 -MediaDirectory 参数。"
    }
    if (-not (Test-Path -LiteralPath $MediaDirectory -PathType Container)) {
        throw "媒体目录不存在：$MediaDirectory"
    }
    $resolvedDir = (Resolve-Path -LiteralPath $MediaDirectory).Path

    $picked = Get-RandomMediaFromDirectory -Directory $resolvedDir -Mode $Mode
    return @{
        Path      = $picked.Path
        Type      = $picked.Type
        Directory = $resolvedDir
    }
}

function Pick-RandomMediaPath {
    # 轮换时随机选一个媒体文件路径（供 Send-MediaToPage 用）。
    param(
        [string]$Mode,
        [string]$MediaDirectory,
        [string]$FixedImagePath,
        [string]$FixedVideoPath
    )

    if ($Mode -eq "image") {
        if ($FixedVideoPath -and (Test-Path -LiteralPath $FixedVideoPath)) { return $FixedVideoPath }
        return $FixedImagePath
    }
    $picked = Get-RandomMediaFromDirectory -Directory $MediaDirectory -Mode $Mode
    return $picked.Path
}

# ============================================================
# main
# ============================================================
try {
    # 单实例保护：杀掉其他正在跑的 codex-background.ps1 进程，避免新旧实例抢注入。
    # 快捷方式重复双击时，确保只有最新这一个实例在工作。
    $myPid = $PID
    Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -match 'codex-background\.ps1' -and $_.ProcessId -ne $myPid
    } | ForEach-Object {
        Write-Host ("关闭旧实例 PID $($_.ProcessId)...")
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500

    # 解析本次运行的媒体。
    $media = Resolve-MediaForCurrentRun `
        -Mode $BackgroundMode `
        -ImagePath $ImagePath `
        -VideoPath $VideoPath `
        -MediaDirectory $MediaDirectory

    $resolvedMediaPath = $media.Path
    $mediaType = $media.Type
    $mediaDirectory = $media.Directory

    if (-not $mediaType) {
        throw "无法识别媒体类型（扩展名不支持）：$resolvedMediaPath"
    }

    if ($ValidateOnly) {
        $rotateMode = if ($RotateInterval -gt 0) { "enabled ($($RotateInterval)s)" } else { "disabled" }
        $effImg = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
        $effVid = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }
        [ordered]@{
            BackgroundMode     = $BackgroundMode
            MediaPath          = $resolvedMediaPath
            MediaType          = $mediaType
            MediaDirectory     = $mediaDirectory
            Opacity            = $Opacity
            ImageOpacity       = $effImg
            VideoOpacity       = $effVid
            RotateInterval     = if ($RotateInterval -gt 0) { "$RotateInterval 秒" } else { "关闭" }
            RotateMode         = $rotateMode
            DebugPort          = $DebugPort
            SuppressCodexPlus  = [bool]$SuppressCodexPlus
            NoLaunch           = [bool]$NoLaunch
            MediaBytes         = (Get-Item -LiteralPath $resolvedMediaPath).Length
        } | ConvertTo-Json
        exit 0
    }

    # 1. 探测 Codex++ launcher（可选，找不到不报错，回退到 MSIX 自激活）。
    $resolvedLauncherPath = ""
    $hasCodexPlus = $false
    if (-not $NoLaunch) {
        if ([string]::IsNullOrWhiteSpace($CodexPlusLauncherPath)) {
            $resolvedLauncherPath = Find-CodexPlusLauncher
        }
        elseif (Test-Path -LiteralPath $CodexPlusLauncherPath -PathType Leaf) {
            $resolvedLauncherPath = (Resolve-Path -LiteralPath $CodexPlusLauncherPath).Path
        }
        else {
            Write-Warning "指定的 Codex++ 主程序不存在，将回退到 MSIX 自激活：$CodexPlusLauncherPath"
        }
        $hasCodexPlus = [bool]$resolvedLauncherPath
    }

    # 2. 动态探测 CDP 端口 + 启动（三分支）。
    # 新版 Codex++ 不再固定 9229，而是动态端口（如 10373）。用户未显式指定 DebugPort 时，
    # 优先从运行中的 Codex.exe 进程命令行解析实际端口。
    if (-not $PSBoundParameters.ContainsKey('DebugPort')) {
        $detectedPort = Find-CodexCdpPort
        if ($detectedPort -and $detectedPort -ne $DebugPort) {
            Write-Host "探测到 Codex 实际 CDP 端口：$detectedPort（非默认 $($DebugPort)）"
            $DebugPort = $detectedPort
        }
    }

    $cdpReady = Test-CdpAvailable -Port $DebugPort
    if ($cdpReady) {
        Write-Host "检测到 Codex CDP 端口 $DebugPort 已在监听，直接注入（不重启 Codex）。"
    }
    elseif ($NoLaunch) {
        throw "CDP 端口 $DebugPort 未在监听，且指定了 -NoLaunch 不启动 Codex。请先打开 Codex 后再运行。"
    }
    elseif ($hasCodexPlus) {
        # 有 Codex++：走 Codex++ launcher（获得增强功能）。Codex++ 会自己选端口，
        # 启动后重新探测实际端口。
        Start-CodexViaLauncher -LauncherPath $resolvedLauncherPath | Out-Null
        Start-Sleep -Seconds 3
        $detectedPort = Find-CodexCdpPort
        if ($detectedPort) { $DebugPort = $detectedPort }
    }
    else {
        # 无 Codex++：直接激活 Codex MSIX 并附加 CDP 端口（重启 Codex，无增强功能）。
        Write-Host "未检测到 Codex++，将直接激活 Codex（仅背景功能，无增强）。如需增强功能请安装 Codex++。"
        Write-Host "⚠️ 这会重启 Codex，当前会话将中断。"
        Start-CodexViaMsix -Port $DebugPort -Aumid $CodexAumid
    }

    # 3. 等待 CDP 主窗口 target。
    $targets = @(Wait-CdpTargets -Port $DebugPort)
    # 取第一个（主窗口）用于轮换推送。
    $mainTarget = $targets[0]
    $mainWsUrl = [string]$mainTarget.webSocketDebuggerUrl

    # 4. 构造并注入 overlay JS（空壳，不含媒体数据，避免大文件嵌入 JS 卡死）。
    $effectiveImageOpacity = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
    $effectiveVideoOpacity = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }

    $javaScript = New-OverlayJavaScript `
        -InitialDataURL "" `
        -MediaType $mediaType `
        -ImageOpacityValue $effectiveImageOpacity `
        -VideoOpacityValue $effectiveVideoOpacity `
        -SuppressCodexPlus:$SuppressCodexPlus

    $installedCount = Install-CodexBackground -Targets $targets -JavaScript $javaScript

    # 5. 注入完成后，用分块传输推送初始媒体（大文件自动分块，小文件走一次性 setMedia）。
    Write-Host "正在推送初始媒体：$resolvedMediaPath"
    Send-MediaToPage -WebSocketUrl $mainWsUrl -Path $resolvedMediaPath -MediaType $mediaType

    # 仅 random/video 模式 + RotateInterval>0 才真正轮换。
    $effectiveRotate = if ($BackgroundMode -in @("random", "video") -and $RotateInterval -gt 0) { $RotateInterval } else { 0 }

    Write-Host ""
    Write-Host "Codex 背景已启用：成功注入 $installedCount 个页面。"
    Write-Host "模式：$BackgroundMode"
    Write-Host "媒体：$resolvedMediaPath （$mediaType）"
    if ([Math]::Abs($effectiveImageOpacity - $effectiveVideoOpacity) -lt 0.001) {
        Write-Host "透明度：$effectiveImageOpacity（图片视频统一）"
    } else {
        Write-Host "透明度：图片 $effectiveImageOpacity / 视频 $effectiveVideoOpacity"
    }
    if ($effectiveRotate -gt 0) {
        Write-Host "轮换：每 $effectiveRotate 秒换一个（来源：$mediaDirectory）"
    }
    else {
        Write-Host "轮换：关闭"
    }
    if ($SuppressCodexPlus) {
        Write-Host "Codex++ 背景压制：开启"
    }
    Write-Host "注入方式：dataURL/blob（绕开 Codex CSP，不依赖本地 HTTP 服务）"

    # 6. 【生命周期绑定】阻塞主线程，期间做轮换推送，直到 Codex 退出。
    Write-Host ""
    Write-Host "后台运行中。关闭 Codex 以结束。"

    # 轮换循环 + Codex 退出检测合并：每隔 min(rotate, 5) 秒检查一次。
    # 这样既能及时轮换，又能较快感知 Codex 退出。
    $checkInterval = if ($effectiveRotate -gt 0) { [Math]::Min($effectiveRotate, 5) } else { 5 }
    $lastRotate = [DateTime]::UtcNow

    while ($true) {
        # 整个循环体包一层 try/catch：任何意外异常（stdin 中断、CDP 抖动、媒体读取失败等）
        # 都只记日志继续循环，绝不让进程退出。只有 CDP 连续探测失败才 break。
        try {
            # Start-Sleep 包 try/catch：非 -NonInteractive 启动时 stdin 异常可能中断 sleep。
            try { Start-Sleep -Seconds $checkInterval } catch { Start-Sleep -Milliseconds 500 }

            # 检测 Codex 是否退出：连续 3 次探测失败才算退出（容忍大文件传输期间 9229 响应变慢）。
            if (-not (Test-CdpAvailable -Port $DebugPort -TimeoutSeconds 2 -RequiredFailures 3)) {
                Write-Host "Codex CDP 端口已不可用（连续探测失败），退出。"
                break
            }

            # 轮换：到点则随机选新媒体推送（分块传输，支持大文件）。
            $elapsed = ([DateTime]::UtcNow - $lastRotate).TotalSeconds
            if ($effectiveRotate -gt 0 -and $elapsed -ge $effectiveRotate) {
                $nextPath = Pick-RandomMediaPath -Mode $BackgroundMode -MediaDirectory $mediaDirectory -FixedImagePath $ImagePath -FixedVideoPath $VideoPath
                $nextType = Get-MediaType -Path $nextPath
                Send-MediaToPage -WebSocketUrl $mainWsUrl -Path $nextPath -MediaType $nextType
                Write-Host ("轮换：{0} （{1}）" -f [IO.Path]::GetFileName($nextPath), $nextType)
                $lastRotate = [DateTime]::UtcNow
            }
        }
        catch {
            # 任何意外异常都只记日志，不退出进程（保证背景服务常驻）。
            Write-Warning "轮换循环异常（已忽略，继续运行）：$($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    Write-Host "Codex 已退出。"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
