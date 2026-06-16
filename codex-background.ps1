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

    # 仅验证参数和资源，不连接或启动 Codex。
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

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

        [int]$TimeoutSeconds = 2
    )

    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -Method Get -TimeoutSec $TimeoutSeconds
        return $true
    }
    catch {
        return $false
    }
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
        # 初始媒体 dataURL（CSP 允许 data:，图片直接用）。
        [Parameter(Mandatory)]
        [string]$InitialDataURL,

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

        // 视频需先转 blob URL（atob 解码，绕开 CSP）；图片直接用 dataURL（更快）。
        const useUrl = snapType === "video"
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
                return true;
            }
            existing.remove();
        }
        const el = createElement(snapType, useUrl);
        el.id = overlayId;
        root.appendChild(el);
        return true;
    }

    // 供 PowerShell 端通过 CDP Runtime.evaluate 调用，实现轮换。
    // 用法：window.__codexBgRotator.setMedia("data:...", "image"|"video")
    window.__codexBgRotator = {
        setMedia: (dataUrl, type) => {
            current.url = dataUrl;
            current.type = type;
            installOverlay();
        },
        version: "1.0"
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
    # 通过 CDP 向页面推送新媒体（轮换用）。调用 window.__codexBgRotator.setMedia。
    param(
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [string]$DataURL,

        [Parameter(Mandatory)]
        [ValidateSet("image", "video")]
        [string]$MediaType
    )

    # 把 dataURL 安全地嵌入 JS 表达式（JSON 编码处理引号/特殊字符）。
    $urlLit = ConvertTo-Json -InputObject $DataURL -Compress
    $typeLit = ConvertTo-Json -InputObject $MediaType -Compress
    $expr = "window.__codexBgRotator && window.__codexBgRotator.setMedia($urlLit, $typeLit); true"

    Invoke-CdpCommand `
        -WebSocketUrl $WebSocketUrl `
        -Method "Runtime.evaluate" `
        -Parameters @{
        expression    = $expr
        returnByValue = $true
        awaitPromise  = $true
    } `
        -CommandId 1 | Out-Null
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

    # 1. 解析 Codex++ launcher 路径。
    $resolvedLauncherPath = ""
    if (-not $NoLaunch) {
        if ([string]::IsNullOrWhiteSpace($CodexPlusLauncherPath)) {
            $resolvedLauncherPath = Find-CodexPlusLauncher
            if (-not $resolvedLauncherPath) {
                throw "未找到 Codex++ 主程序（codex-plus-plus.exe）。请用 -CodexPlusLauncherPath 手动指定，或先安装 Codex++。"
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $CodexPlusLauncherPath -PathType Leaf)) {
                throw "Codex++ 主程序不存在：$CodexPlusLauncherPath"
            }
            $resolvedLauncherPath = (Resolve-Path -LiteralPath $CodexPlusLauncherPath).Path
        }
    }

    # 2. 检测 CDP 端口。
    $cdpReady = Test-CdpAvailable -Port $DebugPort
    if (-not $cdpReady) {
        if ($NoLaunch) {
            throw "CDP 端口 $DebugPort 未在监听，且指定了 -NoLaunch 不启动 Codex。请先用 Codex++ 打开 Codex 后再运行。"
        }
        Start-CodexViaLauncher -LauncherPath $resolvedLauncherPath | Out-Null
    }
    else {
        Write-Host "检测到 Codex CDP 端口 $DebugPort 已在监听，直接注入（不重启 Codex）。"
    }

    # 3. 等待 CDP 主窗口 target。
    $targets = @(Wait-CdpTargets -Port $DebugPort)
    # 取第一个（主窗口）用于轮换推送。
    $mainTarget = $targets[0]
    $mainWsUrl = [string]$mainTarget.webSocketDebuggerUrl

    # 4. 把初始媒体转 dataURL。
    Write-Host "正在编码初始媒体：$resolvedMediaPath"
    $initial = ConvertTo-MediaDataURL -Path $resolvedMediaPath
    Write-Host ("已编码：{0} （{1}，{2} 字节 → dataURL {3} 字符）" -f $initial.FileName, $initial.Type, $initial.Bytes, $initial.DataUrl.Length)

    # 5. 构造并注入 overlay JS。
    $effectiveImageOpacity = if ($ImageOpacity -gt 0) { $ImageOpacity } else { $Opacity }
    $effectiveVideoOpacity = if ($VideoOpacity -gt 0) { $VideoOpacity } else { $Opacity }

    $javaScript = New-OverlayJavaScript `
        -InitialDataURL $initial.DataUrl `
        -MediaType $mediaType `
        -ImageOpacityValue $effectiveImageOpacity `
        -VideoOpacityValue $effectiveVideoOpacity `
        -SuppressCodexPlus:$SuppressCodexPlus

    $installedCount = Install-CodexBackground -Targets $targets -JavaScript $javaScript

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
        Start-Sleep -Seconds $checkInterval

        # 检测 Codex 是否退出（CDP 端口消失即视为退出）。
        $cdpOk = Test-CdpAvailable -Port $DebugPort -TimeoutSeconds 1
        Write-Host ("[rotate-loop] 醒来，cdpOk={0}，距上次轮换 {1:F0}s" -f $cdpOk, ([DateTime]::UtcNow - $lastRotate).TotalSeconds)
        if (-not $cdpOk) {
            Write-Host "Codex CDP 端口已不可用，退出。"
            break
        }

        # 轮换：到点则随机选新媒体推送。
        $elapsed = ([DateTime]::UtcNow - $lastRotate).TotalSeconds
        if ($effectiveRotate -gt 0 -and $elapsed -ge $effectiveRotate) {
            try {
                $nextPath = Pick-RandomMediaPath -Mode $BackgroundMode -MediaDirectory $mediaDirectory -FixedImagePath $ImagePath -FixedVideoPath $VideoPath
                Write-Host ("[rotate] 选到媒体：{0}" -f $nextPath)
                $next = ConvertTo-MediaDataURL -Path $nextPath
                Write-Host ("[rotate] 编码完成：{0} 字符" -f $next.DataUrl.Length)
                Send-MediaToPage -WebSocketUrl $mainWsUrl -DataURL $next.DataUrl -MediaType $next.Type
                Write-Host ("轮换：{0} （{1}）" -f $next.FileName, $next.Type)
            }
            catch {
                Write-Warning "轮换失败（已跳过，不影响现有背景）：$($_.Exception.Message)"
            }
            $lastRotate = [DateTime]::UtcNow
        }
    }

    Write-Host "Codex 已退出。"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
