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
    # 从正在运行的 Codex/ChatGPT 进程命令行解析 --remote-debugging-port=NNNN。
    # CDP host 进程名随版本变化：旧版是 Codex.exe，新版 26.707+ 改名 ChatGPT.exe。
    # 新版 Codex++ 不再固定用 9229，而是动态端口（如 10373），必须实时探测。
    # 返回端口数字；找不到返回 $null。
    # ⚠️ 绝对不能返回 9230——那是 ZCode 的 CDP 端口，连上会把背景注入到 ZCode！
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -in @('Codex.exe', 'ChatGPT.exe') -and $_.CommandLine -match 'remote-debugging-port=(\d+)'
        }
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'remote-debugging-port=(\d+)') {
                $port = [int]$Matches[1]
                if ($port -eq 9230) { continue }  # 排除 ZCode 端口
                # 确认该端口确实在监听（避免解析到子进程的无效端口）。
                if (Test-CdpAvailable -Port $port -TimeoutSeconds 1 -RequiredFailures 1) {
                    return $port
                }
            }
        }
    } catch {
        # Get-CimInstance 失败（如系统页面文件不足）→ 兜底：扫描常见 CDP 端口。
        # 注意：不包含 9230（ZCode 专用，连上会误注入 ZCode 页面）。
        Write-Warning "进程命令行查询失败，尝试扫描常见 CDP 端口..."
        foreach ($candidatePort in @(9229, 3713, 2604, 6363, 10373)) {
            if (Test-CdpAvailable -Port $candidatePort -TimeoutSeconds 1 -RequiredFailures 1) {
                return $candidatePort
            }
        }
    }
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
        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$ImageOpacityValue,

        [Parameter(Mandatory)]
        [ValidateRange(0.01, 1.0)]
        [double]$VideoOpacityValue,

        [switch]$SuppressCodexPlus
    )

    $imageOpacityLiteral = $ImageOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )
    $videoOpacityLiteral = $VideoOpacityValue.ToString(
        "0.################",
        [Globalization.CultureInfo]::InvariantCulture
    )

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

    # Codex 仅允许 blob: 作为此注入场景的可靠媒体源。
    # 所有媒体都由页面端分块解码后创建 Blob，避免 dataURL 的整文件字符串副本。
    return @"
(() => {
    const overlayId = "cz-bg-rotator-overlay";
    const opacityByType = { image: "$imageOpacityLiteral", video: "$videoOpacityLiteral" };

    // 新脚本覆盖旧注入时，优先让旧 rotator 回收自己的候选层和 Blob。
    const previousRotator = window.__czBgRotator;
    if (previousRotator && typeof previousRotator.dispose === "function") {
        try { previousRotator.dispose(); } catch (error) {}
    }

    // 清理改名前（codex-bg-rotator-overlay）的残留元素，避免多层背景叠加。
    const legacyOldName = document.getElementById("codex-bg-rotator-overlay");
    if (legacyOldName) {
        try { legacyOldName.remove(); } catch (error) {}
    }

    // 兼容旧版本没有 dispose 的场景，避免遗留背景层继续引用旧 Blob。
    const legacyOverlay = document.getElementById(overlayId);
    if (legacyOverlay) {
        const legacyUrl = legacyOverlay.src || "";
        removeMediaElement(legacyOverlay);
        if (legacyUrl.startsWith("blob:")) {
            try { URL.revokeObjectURL(legacyUrl); } catch (error) {}
        }
    }

    // activeBlobUrl 只指向已经展示的背景；候选资源单独跟踪，避免抢占时误释放当前背景。
    let activeBlobUrl = "";
    let activeElement = null;
    let candidateBlobUrl = "";
    let candidateElement = null;
    let installToken = 0;
    const chunkBuffers = Object.create(null);

    function opacityFor(type) {
        return opacityByType[type] || opacityByType.image;
    }

    // 仅回收本 rotator 创建的 Blob URL，重复调用也不会影响页面其他资源。
    function revokeBlobUrl(url) {
        if (typeof url === "string" && url.startsWith("blob:")) {
            try { URL.revokeObjectURL(url); } catch (error) {}
        }
    }

    function createElement(type) {
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
        return el;
    }

    // 停止并移除媒体元素，使浏览器可以立刻释放其对应的解码与网络资源。
    function removeMediaElement(el) {
        if (!el) return;
        try {
            const tagName = el.tagName.toLowerCase();
            if (tagName === "video") {
                el.pause();
            }
            // 图片和视频都先解除 src，再移除节点，避免旧资源继续被元素引用。
            el.removeAttribute("src");
            if (tagName === "video") {
                el.load();
            }
            el.remove();
        } catch (error) {}
    }

    // 隐藏窗口被 Chromium 暂停后，重新可见或获得焦点时恢复当前活动视频。
    function resumeActiveVideo() {
        const video = activeElement || document.getElementById(overlayId);
        if (!video || video.tagName.toLowerCase() !== "video") return;
        try {
            video.muted = true;
            video.defaultMuted = true;
            const playback = video.play();
            if (playback && typeof playback.catch === "function") {
                playback.catch(() => {});
            }
        } catch (error) {}
    }

    function onVisibilityChange() {
        if (!document.hidden) {
            resumeActiveVideo();
        }
    }

    document.addEventListener("visibilitychange", onVisibilityChange);
    window.addEventListener("focus", resumeActiveVideo);

    // 候选背景尚未展示时可直接销毁，当前活动背景始终保持不动。
    function discardCandidate() {
        const element = candidateElement;
        const url = candidateBlobUrl;
        candidateElement = null;
        candidateBlobUrl = "";
        removeMediaElement(element);
        revokeBlobUrl(url);
    }

    // CDP 传入的是单块 Base64；在本次调用内立即转换为二进制，避免字符串长期驻留。
    function decodeBase64Chunk(base64Chunk) {
        const binary = atob(base64Chunk);
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index++) {
            bytes[index] = binary.charCodeAt(index);
        }
        return bytes;
    }

    // 图片等待 load，视频等待获得可播放帧并且静音播放成功；超时或失败时保留旧背景。
    function waitForCandidate(element, type, blobUrl) {
        return new Promise((resolve) => {
            let settled = false;
            const finish = (success) => {
                if (settled) return;
                settled = true;
                clearTimeout(timeoutId);
                element.removeEventListener("load", onImageLoad);
                element.removeEventListener("loadeddata", onVideoData);
                element.removeEventListener("error", onError);
                resolve(success);
            };
            const onImageLoad = () => finish(true);
            const onVideoData = () => {
                try {
                    element.muted = true;
                    element.defaultMuted = true;
                    const playback = element.play();
                    if (playback && typeof playback.then === "function") {
                        playback.then(() => finish(true)).catch(() => finish(false));
                    } else {
                        finish(true);
                    }
                } catch (error) {
                    finish(false);
                }
            };
            const onError = () => finish(false);
            const timeoutId = setTimeout(() => finish(false), 15000);

            element.addEventListener("error", onError, { once: true });
            if (type === "video") {
                element.addEventListener("loadeddata", onVideoData, { once: true });
            } else {
                element.addEventListener("load", onImageLoad, { once: true });
            }
            element.src = blobUrl;
        });
    }

    // 只有候选层准备就绪后才替换活动背景，避免轮换期间出现空白。
    async function stageBlob(blobUrl, type) {
        const root = document.documentElement;
        if (!root) {
            revokeBlobUrl(blobUrl);
            return false;
        }

        const token = ++installToken;
        discardCandidate();
        const candidate = createElement(type);
        candidate.style.opacity = "0";
        candidateElement = candidate;
        candidateBlobUrl = blobUrl;
        root.appendChild(candidate);

        const ready = await waitForCandidate(candidate, type, blobUrl);
        if (token !== installToken || !ready) {
            if (candidateElement === candidate) {
                discardCandidate();
            } else {
                removeMediaElement(candidate);
                revokeBlobUrl(blobUrl);
            }
            return false;
        }

        const oldElement = activeElement;
        const oldBlobUrl = activeBlobUrl;
        candidate.style.opacity = opacityFor(type);
        removeMediaElement(oldElement);
        candidate.id = overlayId;
        activeElement = candidate;
        activeBlobUrl = blobUrl;
        candidateElement = null;
        candidateBlobUrl = "";
        revokeBlobUrl(oldBlobUrl);
        resumeActiveVideo();
        return true;
    }

    const rotator = {
        // 创建一条媒体传输的二进制块缓冲；同 id 重入时先释放旧缓冲。
        beginChunkedMedia(id, mime, type) {
            if (!id || !mime || (type !== "image" && type !== "video")) return false;
            rotator.abortChunkedMedia(id);
            chunkBuffers[id] = { mime: mime, type: type, parts: [] };
            return true;
        },

        // 每块在本调用内解码，chunkBuffers 只持有原始字节而不持有完整 Base64 文本。
        appendChunk(id, base64Chunk) {
            const buffer = chunkBuffers[id];
            if (!buffer) return false;
            try {
                buffer.parts.push(decodeBase64Chunk(base64Chunk));
                return true;
            } catch (error) {
                rotator.abortChunkedMedia(id);
                return false;
            }
        },

        // Blob 构造完成后立即清空分块数组，后续由候选层负责接管或回收 Blob URL。
        async finalizeChunkedMedia(id) {
            const buffer = chunkBuffers[id];
            if (!buffer) return false;
            delete chunkBuffers[id];
            let blobUrl = "";
            try {
                const blob = new Blob(buffer.parts, { type: buffer.mime });
                buffer.parts.length = 0;
                blobUrl = URL.createObjectURL(blob);
                return await stageBlob(blobUrl, buffer.type);
            } catch (error) {
                buffer.parts.length = 0;
                revokeBlobUrl(blobUrl);
                return false;
            }
        },

        // PowerShell 传输中断时显式释放尚未 finalize 的原始字节块。
        abortChunkedMedia(id) {
            const buffer = chunkBuffers[id];
            if (!buffer) return false;
            buffer.parts.length = 0;
            delete chunkBuffers[id];
            return true;
        },

        // 重复注入或页面卸载前统一回收候选、活动背景和所有未完成传输。
        dispose() {
            installToken++;
            document.removeEventListener("visibilitychange", onVisibilityChange);
            window.removeEventListener("focus", resumeActiveVideo);
            Object.keys(chunkBuffers).forEach((id) => rotator.abortChunkedMedia(id));
            discardCandidate();
            const element = activeElement || document.getElementById(overlayId);
            const url = activeBlobUrl || (element && element.src) || "";
            activeElement = null;
            activeBlobUrl = "";
            removeMediaElement(element);
            revokeBlobUrl(url);
        },

        version: "2.0"
    };

    window.__czBgRotator = rotator;
    $suppressBlock

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
    # 通过 CDP 向页面流式推送新媒体；PowerShell 端始终只保留一个原始字节块。
    param(
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("image", "video")]
        [string]$MediaType,

        # 原始字节块为 384 KiB；可整除 3，常规块编码后恰好为 512 KiB Base64 文本。
        [ValidateRange(3, 8388608)]
        [int]$RawChunkSize = 393216
    )

    if (($RawChunkSize % 3) -ne 0) {
        throw "RawChunkSize 必须是 3 的倍数，以避免中间 Base64 块产生填充字符。"
    }

    $mime = Get-MediaMimeType -Path $Path
    $rotator = "window.__czBgRotator"
    $mediaId = "m" + (Get-Date -Format "HHmmssfff") + (Get-Random -Maximum 10000)
    $mimeLit = ConvertTo-Json -InputObject $mime -Compress
    $typeLit = ConvertTo-Json -InputObject $MediaType -Compress
    $idLit = ConvertTo-Json -InputObject $mediaId -Compress

    # 失败后必须通知页面释放已解码的分块，不能等到下一次轮换覆盖。
    $transferStarted = $false
    $transferFinished = $false
    $stream = $null
    try {
        $beginResult = Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
            -Parameters @{ expression = "$rotator && $rotator.beginChunkedMedia($idLit, $mimeLit, $typeLit) === true"; returnByValue = $true } `
            -CommandId 1
        if (-not $beginResult.result.value) {
            throw "页面未接受媒体传输初始化。"
        }
        $transferStarted = $true

        $stream = [IO.File]::OpenRead($Path)
        if ($stream.Length -eq 0) {
            throw "媒体文件为空：$Path"
        }

        $buffer = [byte[]]::new($RawChunkSize)
        $commandId = 2
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            # 当前块完成 CDP 调用后即被下一轮覆盖，不会在 PowerShell 中累积为整文件字符串。
            $base64Chunk = [Convert]::ToBase64String($buffer, 0, $readCount)
            $chunkLit = ConvertTo-Json -InputObject $base64Chunk -Compress
            $appendResult = Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
                -Parameters @{ expression = "$rotator && $rotator.appendChunk($idLit, $chunkLit) === true"; returnByValue = $true } `
                -CommandId $commandId
            if (-not $appendResult.result.value) {
                throw "页面拒绝媒体分块 #$commandId。"
            }
            $commandId++
        }

        # awaitPromise 让 PowerShell 等到 Blob 创建与候选背景切换完成，失败才进入 abort 分支。
        $finalizeResult = Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
            -Parameters @{ expression = "$rotator && $rotator.finalizeChunkedMedia($idLit)"; returnByValue = $true; awaitPromise = $true } `
            -CommandId $commandId
        if (-not $finalizeResult.result.value) {
            throw "页面未能完成媒体 Blob 构造或背景切换。"
        }
        $transferFinished = $true
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($transferStarted -and -not $transferFinished) {
            try {
                Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method "Runtime.evaluate" `
                    -Parameters @{ expression = "$rotator && $rotator.abortChunkedMedia($idLit) === true"; returnByValue = $true } `
                    -CommandId 999999 | Out-Null
            }
            catch {
                Write-Warning "媒体传输清理失败：$($_.Exception.Message)"
            }
        }
    }
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
    # ValidateOnly 只做参数和资源检查，绝不能干扰正在运行的背景实例。
    if (-not $ValidateOnly) {
        # 单实例保护：杀掉其他正在跑的 codex-background.ps1 进程，避免新旧实例抢注入。
        # 快捷方式重复双击时，确保只有最新这一个实例在工作。
        # 注意：Get-CimInstance 在系统页面文件不足时会失败，这里容错（失败只跳过，不崩溃）。
        $myPid = $PID
        try {
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.CommandLine -match 'codex-background\.ps1' -and $_.ProcessId -ne $myPid
            } | ForEach-Object {
                Write-Host ("关闭旧实例 PID $($_.ProcessId)...")
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "单实例保护跳过（Get-CimInstance 失败：$($_.Exception.Message)）"
        }
        Start-Sleep -Milliseconds 500
    }

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
        # 有 Codex++：走 Codex++ launcher（获得增强功能）。Codex++ 会自己选端口。
        Start-CodexViaLauncher -LauncherPath $resolvedLauncherPath | Out-Null
        # Codex++ 启动 Codex 需要时间（尤其重启后要恢复会话），轮询等待 CDP 端口出现。
        Write-Host "等待 Codex 启动并开启 CDP 端口..."
        $waitDeadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $waitDeadline) {
            Start-Sleep -Seconds 2
            $detectedPort = Find-CodexCdpPort
            if ($detectedPort) {
                $DebugPort = $detectedPort
                Write-Host "Codex CDP 端口已就绪：$DebugPort"
                break
            }
        }
        if (-not $detectedPort) {
            Write-Warning "等待 Codex CDP 端口超时（60秒），尝试用默认端口 $DebugPort 继续。"
        }
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

    # 4. 构造并注入仅包含流式 rotator 的空壳，媒体字节随后按块传输。
    $effectiveImageOpacity = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
    $effectiveVideoOpacity = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }

    $javaScript = New-OverlayJavaScript `
        -ImageOpacityValue $effectiveImageOpacity `
        -VideoOpacityValue $effectiveVideoOpacity `
        -SuppressCodexPlus:$SuppressCodexPlus

    $installedCount = Install-CodexBackground -Targets $targets -JavaScript $javaScript

    # 5. 注入完成后，以统一流式分块路径推送初始媒体。
    # 用 try/catch 包裹：初始推送失败不退出进程（轮换循环会继续尝试推送新媒体）。
    Write-Host "正在推送初始媒体：$resolvedMediaPath"
    try {
        Send-MediaToPage -WebSocketUrl $mainWsUrl -Path $resolvedMediaPath -MediaType $mediaType
    }
    catch {
        Write-Warning "初始媒体推送失败（不影响后续轮换，循环会重试）：$($_.Exception.Message)"
    }

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
    Write-Host "注入方式：流式 Base64/blob（绕开 Codex CSP，不依赖本地 HTTP 服务）"

    # 6. 【生命周期绑定】阻塞主线程，期间做轮换推送，直到 Codex 退出。
    Write-Host ""
    Write-Host "后台运行中。关闭 Codex 以结束。"

    # 轮换循环 + Codex 退出检测合并：每隔 min(rotate, 5) 秒检查一次。
    # 这样既能及时轮换，又能较快感知 Codex 退出。
    $checkInterval = if ($effectiveRotate -gt 0) { [Math]::Min($effectiveRotate, 5) } else { 5 }
    $lastRotate = [DateTime]::UtcNow

    while ($true) {
        # 整个循环体包一层 try/catch：任何意外异常（stdin 中断、CDP 抖动、媒体读取失败等）
        # 都只记日志继续循环，绝不因异常退出。CDP 断开时进入限时重连（不是立即退出）。
        try {
            # Start-Sleep 包 try/catch：非 -NonInteractive 启动时 stdin 异常可能中断 sleep。
            try { Start-Sleep -Seconds $checkInterval } catch { Start-Sleep -Milliseconds 500 }

            # 检测 Codex 是否退出：连续 3 次探测失败才算断开（容忍大文件传输期间响应变慢）。
            if (-not (Test-CdpAvailable -Port $DebugPort -TimeoutSeconds 2 -RequiredFailures 3)) {
                # CDP 断开 → 进入限时重连（Codex 可能在更新/重启，等它恢复）。
                Write-Host "Codex CDP 端口断开，等待 Codex 恢复（最多 10 分钟）..."
                $reconnectDeadline = [DateTime]::UtcNow.AddMinutes(10)
                $reconnected = $false
                while ([DateTime]::UtcNow -lt $reconnectDeadline) {
                    Start-Sleep -Seconds 30
                    try {
                        # 重新探测端口（Codex 重开后端口可能变了）。
                        $newPort = Find-CodexCdpPort
                        if ($newPort) {
                            $DebugPort = $newPort
                            Write-Host "探测到 Codex 恢复，端口 $DebugPort，重新注入..."
                            # 重新等 page target（Codex 页面是全新的，旧注入全没了）。
                            $targets = @(Wait-CdpTargets -Port $DebugPort -TimeoutSeconds 60)
                            $mainTarget = $targets[0]
                            $mainWsUrl = [string]$mainTarget.webSocketDebuggerUrl
                            # 重新注入 overlay JS。
                            $null = Install-CodexBackground -Targets $targets -JavaScript $javaScript
                            # 推送初始媒体。
                            try { Send-MediaToPage -WebSocketUrl $mainWsUrl -Path $resolvedMediaPath -MediaType $mediaType } catch {}
                            $reconnected = $true
                            $lastRotate = [DateTime]::UtcNow
                            Write-Host "Codex 已恢复，背景重新注入完成。"
                            break
                        }
                    }
                    catch {
                        # 重连过程中出错（target 还没就绪等），继续等下一轮探测。
                        Write-Warning "重连尝试失败（继续等待）：$($_.Exception.Message)"
                    }
                }
                if (-not $reconnected) {
                    Write-Host "等待 Codex 恢复超时（10 分钟），退出。"
                    break
                }
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
