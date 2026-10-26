# 通过 Codex++ 原生自动启动设置兼容统一管理器，保留旧版静默启动方式。
function Start-CodexViaLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$LauncherPath
    )

    $versionText = (Get-Item -LiteralPath $LauncherPath).VersionInfo.ProductVersion
    $version = $null
    if (-not [Version]::TryParse(($versionText -split '[+-]')[0], [ref]$version)) {
        throw "无法识别 Codex++ 版本：$versionText，请检查安装路径。"
    }

    # 1.8 起统一为管理器界面；旧版可直接作为静默启动器运行。
    if ($version -ge [Version]'1.8.0') {
        $stateDirectory = if ($env:CODEX_PLUS_STATE_DIR) { $env:CODEX_PLUS_STATE_DIR }
            else { Join-Path $env:USERPROFILE '.codex-session-delete' }
        Enable-CodexPlusStartOnOpen -StateDirectory $stateDirectory
        $managers = @(Get-Process -Name 'codex-plus-plus' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $LauncherPath })
        if ($managers.Count -gt 0) {
            $statusPath = Join-Path $stateDirectory 'latest-status.json'
            $status = if (Test-Path -LiteralPath $statusPath) {
                Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } else { $null }
            if ($status.status -in @('starting', 'running', 'running_degraded') -or
                ($status.phase -and $status.progress -lt 100 -and $status.status -ne 'failed')) {
                Write-Host 'Codex++ 已有启动或运行任务，保留管理器并等待调试端口。'
                return
            }
            if ($status.status -notin @('stopped', 'failed')) {
                throw 'Codex++ 已运行但未确认空闲，请在管理器中点击启动，或正常退出管理器后重新运行快捷方式。'
            }
            # 状态文件可能刚过期；端口仍可用时不关闭管理器，交给主脚本复用连接。
            if ($status.debug_port -and (Test-CdpAvailable -Port $status.debug_port -RequiredFailures 1)) {
                Write-Host 'Codex++ 调试端口仍可用，保留现有管理器。'
                return
            }
            # 开关仅在进程初始化时读取；只有明确停止的同路径管理器才重新打开。
            Write-Host 'Codex++ 当前会话已停止，重新打开空闲管理器以触发原生自动启动。'
            foreach ($manager in $managers) {
                Stop-Process -Id $manager.Id -Force -ErrorAction Stop
                Wait-Process -Id $manager.Id -Timeout 10 -ErrorAction SilentlyContinue
            }
        }
    }

    # 调试端口只在新进程启动时生效。旧的普通桌面实例会让新进程直接退出，
    # 因此在确认需要新启动、且管理器没有运行任务后，按安装路径关闭旧桌面实例。
    Stop-CodexProcesses
    Write-Host "正在通过 Codex++ $version 启动 Codex：$LauncherPath"
    # 用户点击的启动入口需要显示管理器；后台轮换进程仍由无控制台启动器运行。
    Start-Process -FilePath $LauncherPath -WorkingDirectory (Split-Path -Parent $LauncherPath) -WindowStyle Normal -ErrorAction Stop | Out-Null
}

function Enable-CodexPlusStartOnOpen {
    param([Parameter(Mandatory)][string]$StateDirectory)

    # 这是 Codex++ 自身设置开关的存储文件，不修改供应商、凭据或开机启动配置。
    $flagPath = Join-Path $StateDirectory 'watcher.start-codex-on-open'
    if (-not (Test-Path -LiteralPath $flagPath -PathType Leaf)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
        [IO.File]::WriteAllText($flagPath, 'enabled', [Text.UTF8Encoding]::new($false))
        Write-Host '已开启 Codex++ 的“打开时自动启动 Codex”。'
    }
}
