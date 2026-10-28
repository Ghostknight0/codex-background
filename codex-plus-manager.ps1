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

function Start-CodexViaRunningManager {
    param(
        [Parameter(Mandatory)][int]$ManagerId,
        [Parameter(Mandatory)][string]$LauncherPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
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
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-CodexDesktopRunning) { return }
        $root = Get-CodexPlusManagerWindow -ManagerId $ManagerId
        if ($root) {
            if (Test-CodexDesktopRunning) { return }
            $button = Find-CodexPlusButton -Root $root -Names @('启动 Codex', 'Start Codex')
            if ($button) {
                # 再次核对进程，避免启动期间重复触发。
                if (Test-CodexDesktopRunning) { return }
                $pattern = $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                $pattern.Invoke()
                Write-Host '已通过正在运行的 Codex++ 管理器请求启动 Codex。'
                return
            }
            if (-not $navigationDone) {
                # 其他页面没有启动按钮时，进入 Codex 概览；不修改配置。
                $nav = Find-CodexPlusButton -Root $root -Names @('Codex') -NamePattern '^Codex\s*[·•]'
                if ($nav) {
                    $nav.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $navigationDone = $true
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    # 失败时保留已经显示的管理器，方便查看状态并手动操作。
    throw '未找到可用的“启动 Codex”按钮，已保留 Codex++ 界面，请在管理器中手动启动。'
}
