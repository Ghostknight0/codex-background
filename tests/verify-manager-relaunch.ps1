# 在独立进程中验证“Codex++ 保持运行，退出 Codex 后通过快捷方式重新启动”的完整流程。
# 此脚本会退出当前 Codex，只能在用户同意进行实机重启验证后运行。
param([string]$TaskName = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $projectRoot 'codex-relaunch-check.log'
. (Join-Path $projectRoot 'codex-process.ps1')
. (Join-Path $projectRoot 'codex-plus-manager.ps1')
$result = [ordered]@{ started = [DateTime]::Now.ToString('o'); passed = $false }
try {
    $launcherPath = Join-Path $env:LOCALAPPDATA 'Programs\Codex++\codex-plus-plus.exe'
    $manager = Get-Process -Name codex-plus-plus -ErrorAction Stop |
        Where-Object { $_.Path -eq $launcherPath } | Select-Object -First 1
    if (-not $manager) { throw '测试前 Codex++ 管理器必须已经运行。' }
    $result.managerBefore = $manager.Id
    # 给调用方留出时间结束工具调用，再退出聊天应用。
    Start-Sleep -Seconds 3
    Stop-CodexProcesses
    if (Test-CodexDesktopRunning) { throw 'Codex 未完全退出，未满足测试前提。' }
    $result.codexWasStopped = $true
    $launchTime = [DateTime]::Now
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Background.lnk'
    Start-Process -FilePath $shortcutPath
    $deadline = [DateTime]::UtcNow.AddSeconds(135)
    $logPath = Join-Path $projectRoot 'codex-background.log'
    do {
        Start-Sleep -Seconds 2
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).LastWriteTime -ge $launchTime) {
            $log = Get-Content -LiteralPath $logPath -Raw
            if ($log -match 'Codex 背景已启用') { break }
            if ($log -match 'transcript end') { throw "启动脚本提前退出，请查看 $logPath" }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Test-CodexDesktopRunning) -or $log -notmatch 'Codex 背景已启用') {
        throw '实际启动未完成，或背景注入没有成功。'
    }
    $currentManager = Get-Process -Id $manager.Id -ErrorAction Stop
    if ($currentManager.Path -ne $launcherPath) { throw '原管理器已退出或进程发生变化。' }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $window = Get-CodexPlusManagerWindow -ManagerId $manager.Id
    if (-not $window -or $window.Current.IsOffscreen) { throw 'Codex 已启动，但管理器界面不可见。' }
    $result.managerAfter = $currentManager.Id
    $result.managerVisible = $true
    $result.passed = $true
}
catch {
    $result.error = $_.Exception.Message
    # 启动测试失败也尝试恢复聊天应用，避免用户停留在应用关闭的状态。
    try {
        if (-not (Test-CodexDesktopRunning)) {
            $package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
            $aumid = $package.PackageFamilyName + '!App'
            Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') `
                -ArgumentList ('"shell:AppsFolder\{0}"' -f $aumid) -WindowStyle Normal
            $result.recoveryRequested = $true
        }
    } catch { $result.recoveryError = $_.Exception.Message }
}
finally {
    $result.finished = [DateTime]::Now.ToString('o')
    $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
    # 临时任务只用于让检查进程独立于 Codex 生存，结束后自动移除。
    if ($TaskName) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
}
