# 通过现有 Codex++ 管理器启动 Codex，避免关闭管理器或丢失增强功能。
function Test-CodexDesktopRunning {
    # 使用安装清单和完整路径区分 Codex 桌面程序与其他 ChatGPT 进程。
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
    if (-not $package) { throw '未找到 Codex 安装包，无法确认桌面程序状态。' }
    $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
    $application = $manifest.Package.Applications.Application |
        Where-Object { $_.Id -eq 'App' } | Select-Object -First 1
    if (-not $application.Executable) { throw 'Codex 安装清单缺少桌面程序路径。' }
    $path = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation $application.Executable))
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $path }).Count -gt 0
}

function Find-CodexPlusButton {
    param($Root, [string[]]$Names, [string]$NamePattern = '')
    # 匹配界面上实际可用的按钮，不调用“重启 Codex”。
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Button)
    foreach ($button in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
        $name = $button.Current.Name
        if (($name -in $Names -or ($NamePattern -and $name -match $NamePattern)) -and
            $button.Current.IsEnabled -and -not $button.Current.IsOffscreen) { return $button }
    }
    return $null
}

function Get-CodexPlusManagerWindow {
    param([Parameter(Mandatory)][int]$ManagerId)
    # 由管理器自己显示窗口后，再读取它的界面；不直接更改 Windows 窗口显示状态。
    $conditions = [Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $ManagerId),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'Codex++')
    )
    $condition = [Windows.Automation.AndCondition]::new($conditions)
    return [Windows.Automation.AutomationElement]::RootElement.FindFirst(
        [Windows.Automation.TreeScope]::Children, $condition)
}

function Invoke-CodexPlusControl {
    param([Parameter(Mandatory)]$Element, [switch]$AllowToggle)
    # 普通操作按钮提供 InvokePattern，Codex 模块入口则提供 TogglePattern。
    $pattern = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    if ($AllowToggle -and $Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
        # 已选中的模块无需再次切换，否则会折叠左侧导航。
        if ($pattern.Current.ToggleState -ne [Windows.Automation.ToggleState]::On) { $pattern.Toggle() }
        return
    }
    throw "Codex++ 控件不支持所需操作：$($Element.Current.Name)"
}

function Show-CodexPlusOverview {
    param([Parameter(Mandatory)]$Root)
    # 先选择 Codex 模块，再进入概览；原先保留的供应商等子页面没有启动按钮。
    $navigation = Find-CodexPlusButton -Root $Root -Names @('Codex') -NamePattern '^Codex\s*[·•]'
    if ($navigation) { Invoke-CodexPlusControl -Element $navigation -AllowToggle }
    $overview = Find-CodexPlusButton -Root $Root -Names @('概览', 'Overview')
    if (-not $overview) { return $false }
    Invoke-CodexPlusControl -Element $overview
    return $true
}

function Get-CodexPlusLaunchState {
    # 只读取启动状态及写入时间，区分本次请求的结果与上次残留的 stopped 状态。
    $directory = if ($env:CODEX_PLUS_STATE_DIR) { $env:CODEX_PLUS_STATE_DIR }
        else { Join-Path $env:USERPROFILE '.codex-session-delete' }
    $path = Join-Path $directory 'latest-status.json'
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $writeTime = [IO.File]::GetLastWriteTimeUtc($path)
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # 管理器正在写文件时等待下一轮，避免把新时间和旧内容组合成错误结果。
        if ([IO.File]::GetLastWriteTimeUtc($path) -ne $writeTime) { return $null }
        return [pscustomobject]@{ Status = $state.status; Message = $state.message; WriteTimeUtc = $writeTime }
    }
    catch { return $null }
}

function Start-CodexViaRunningManager {
    param(
        [Parameter(Mandatory)][int]$ManagerId,
        [Parameter(Mandatory)][string]$LauncherPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 60
    )
    # 已有桌面进程时立即退出，避免改变用户刚刚打开的管理器窗口。
    if (Test-CodexDesktopRunning) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    # 再次运行原程序只会唤起现有单实例，由 Tauri 同时恢复主窗口和 WebView。
    Start-Process -FilePath $LauncherPath -WorkingDirectory (Split-Path -Parent $LauncherPath) `
        -WindowStyle Normal -ErrorAction Stop | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $navigationDone = $false
    $requestSent = $false
    $requestCount = 0
    $requestStateTime = [DateTime]::MinValue
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-CodexDesktopRunning) {
            Write-Host '已确认 Codex 桌面进程启动，继续等待调试端口。'
            return
        }
        $state = Get-CodexPlusLaunchState
        if ($requestSent -and $state -and $state.WriteTimeUtc -gt $requestStateTime) {
            if ($state.Status -eq 'failed') { throw "Codex++ 启动失败：$($state.Message)" }
            if ($state.Status -eq 'stopped' -and $requestCount -lt 2) {
                # 旧任务收尾时可能接走启动请求；它明确停止后才允许补发一次。
                $requestSent = $false
                $navigationDone = $false
                Write-Host 'Codex++ 的旧任务已结束，重新请求启动 Codex。'
            }
        }
        # 请求已经发出时只查进程和状态文件，避免反复扫描整个管理器界面。
        $root = if (-not $requestSent) { Get-CodexPlusManagerWindow -ManagerId $ManagerId }
        if ($root) {
            $button = Find-CodexPlusButton -Root $root -Names @('启动 Codex', 'Start Codex')
            if ($button) {
                # 再次核对进程，避免启动期间重复触发。
                if (Test-CodexDesktopRunning) { return }
                # 记住点击前的文件时间；旧的 stopped 文件不能触发重试。
                $beforeRequest = Get-CodexPlusLaunchState
                $requestStateTime = if ($beforeRequest) { $beforeRequest.WriteTimeUtc } else { [DateTime]::MinValue }
                $requestSent = $true
                $requestCount++
                Invoke-CodexPlusControl -Element $button
                Write-Host '已通过正在运行的 Codex++ 管理器请求启动 Codex。'
            }
            elseif (-not $navigationDone) {
                $navigationDone = Show-CodexPlusOverview -Root $root
            }
        }
        Start-Sleep -Milliseconds 500
    }
    # 失败时保留已经显示的管理器，方便查看状态并手动操作。
    if ($requestSent) { throw '已请求启动 Codex，但等待后仍未检测到桌面进程，请查看 Codex++ 的启动错误。' }
    throw '未找到可用的“启动 Codex”按钮，已保留 Codex++ 界面，请在管理器中手动启动。'
}
