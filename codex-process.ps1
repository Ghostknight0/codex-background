# 按 MSIX 安装清单识别 Codex 桌面进程，避免误关 CLI 或其他同名应用。
function Stop-CodexProcesses {
    # 从安装清单获取真实可执行文件路径，兼容 Codex.exe 和 ChatGPT.exe。
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
    if (-not $package) { throw '未找到 Codex 安装包，无法安全识别桌面进程。' }
    $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
    $application = $manifest.Package.Applications.Application |
        Where-Object { $_.Id -eq 'App' } | Select-Object -First 1
    if (-not $application.Executable) { throw 'Codex 安装清单缺少桌面程序路径。' }
    $executablePath = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation $application.Executable))
    $processName = [IO.Path]::GetFileNameWithoutExtension($executablePath)
    $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $executablePath })
    if ($processes.Count -eq 0) { return }

    # 先请求正常关闭窗口，留出时间让应用保存状态。
    Write-Host '正在关闭 Codex（重启以开启调试端口）...'
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        # 只检查最初确认的进程，并再次核对路径，避免处理其他应用。
        $remaining = @(Get-Process -Id $processes.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $executablePath })
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $remaining.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
}
