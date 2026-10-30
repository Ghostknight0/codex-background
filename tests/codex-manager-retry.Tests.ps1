# 模拟旧启动任务正在退出时接走新请求，验证后台管理器能够重新启动桌面程序。
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'codex-plus-manager.ps1')

Describe '管理器旧任务结束后的启动重试' {
    BeforeEach {
        $script:savedStateDirectory = $env:CODEX_PLUS_STATE_DIR
        $env:CODEX_PLUS_STATE_DIR = $TestDrive
        $script:statusPath = Join-Path $TestDrive 'latest-status.json'
        '{"status":"running","started_at_ms":1}' | Set-Content -LiteralPath $script:statusPath
        # 旧状态早于本次操作，不能仅因它写着 stopped 就重复发送请求。
        (Get-Item -LiteralPath $script:statusPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        $script:requestCount = 0
        $script:desktopReady = $false
        Mock Test-CodexDesktopRunning { $script:desktopReady }
        Mock Start-Process {}
        Mock Get-CodexPlusManagerWindow { [pscustomobject]@{ Name = '模拟管理器' } }
        Mock Find-CodexPlusButton { [pscustomobject]@{ Name = '启动 Codex' } }
        Mock Invoke-CodexPlusControl {
            $script:requestCount++
            if ($script:requestCount -eq 1) {
                # 上游旧任务接到请求后继续退出，桌面程序没有出现，状态改回 stopped。
                '{"status":"stopped","started_at_ms":1}' | Set-Content -LiteralPath $script:statusPath
            } else { $script:desktopReady = $true }
        }
    }
    AfterEach { $env:CODEX_PLUS_STATE_DIR = $script:savedStateDirectory }

    It '请求后旧任务回到 stopped 时，重新请求一次并确认桌面进程出现' {
        Start-CodexViaRunningManager -ManagerId 101 -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' -TimeoutSeconds 2
        $script:requestCount | Should Be 2
        $script:desktopReady | Should Be $true
    }

    It '请求前就已 stopped 的旧文件不会触发重复请求' {
        '{"status":"stopped","started_at_ms":1}' | Set-Content -LiteralPath $script:statusPath
        (Get-Item -LiteralPath $script:statusPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        Mock Invoke-CodexPlusControl { $script:requestCount++ }
        $failure = $null
        try { Start-CodexViaRunningManager -ManagerId 101 -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' -TimeoutSeconds 1 }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match '仍未检测到桌面进程'
        $script:requestCount | Should Be 1
    }

    It '连续回到 stopped 时最多请求两次，不会一直重复启动' {
        Mock Invoke-CodexPlusControl {
            $script:requestCount++
            '{"status":"stopped","started_at_ms":1}' | Set-Content -LiteralPath $script:statusPath
        }
        $failure = $null
        try { Start-CodexViaRunningManager -ManagerId 101 -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' -TimeoutSeconds 2 }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match '仍未检测到桌面进程'
        $script:requestCount | Should Be 2
    }

    It '状态正在 starting 时继续等待，不补发启动请求' {
        Mock Invoke-CodexPlusControl {
            $script:requestCount++
            '{"status":"starting","started_at_ms":2}' | Set-Content -LiteralPath $script:statusPath
        }
        $failure = $null
        try { Start-CodexViaRunningManager -ManagerId 101 -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' -TimeoutSeconds 1 }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match '仍未检测到桌面进程'
        $script:requestCount | Should Be 1
    }

    It '管理器明确报告失败时保留原因，不再次请求' {
        Mock Invoke-CodexPlusControl {
            $script:requestCount++
            '{"status":"failed","message":"模拟启动器失败"}' | Set-Content -LiteralPath $script:statusPath
        }
        $failure = $null
        try { Start-CodexViaRunningManager -ManagerId 101 -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' -TimeoutSeconds 2 }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match '模拟启动器失败'
        $script:requestCount | Should Be 1
    }
}
