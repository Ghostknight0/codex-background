# 验证新版 Codex++ 的自动启动开关和空闲管理器处理，全程模拟启动与关闭进程。
$projectRoot = Split-Path -Parent $PSScriptRoot
$adapter = Join-Path $projectRoot 'codex-plus-launch.ps1'
if (Test-Path $adapter) { . $adapter }
else {
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot 'codex-background.ps1'), [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-CodexViaLauncher'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Test-CdpAvailable { param([int]$Port, [int]$RequiredFailures) return $false }
. (Join-Path $projectRoot 'codex-process.ps1')

Describe 'Codex++ 新版启动适配' {
    BeforeEach {
        $script:stateRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:stateRoot | Out-Null
        $script:savedStateDir = $env:CODEX_PLUS_STATE_DIR
        $env:CODEX_PLUS_STATE_DIR = $script:stateRoot
        Mock Get-Item { [pscustomobject]@{ VersionInfo = @{ ProductVersion = '1.12.1' } } }
        Mock Get-Process { @() }
        Mock Start-Process {}
        Mock Stop-Process {}
        Mock Wait-Process {}
        Mock Test-CdpAvailable { $false }
        Mock Stop-CodexProcesses {}
    }
    AfterEach { $env:CODEX_PLUS_STATE_DIR = $script:savedStateDir }

    It '新版首次启动前开启原生自动启动，不依赖模拟点击' {
        Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe'
        Test-Path (Join-Path $script:stateRoot 'watcher.start-codex-on-open') | Should Be $true
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        Assert-MockCalled Stop-CodexProcesses -Times 1 -Exactly -Scope It
    }

    It '只重启状态明确为 stopped 的同路径空闲管理器' {
        '{"status":"stopped"}' | Set-Content (Join-Path $script:stateRoot 'latest-status.json')
        Mock Get-Process { @(
            [pscustomobject]@{ Id = 101; Path = 'C:\Apps\Codex++\codex-plus-plus.exe' },
            [pscustomobject]@{ Id = 102; Path = 'C:\Other\codex-plus-plus.exe' }
        ) }
        Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe'
        Assert-MockCalled Stop-Process -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq 101 }
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
    }

    It '管理器正在启动时保留现有进程，不重复启动' {
        '{"status":"starting"}' | Set-Content (Join-Path $script:stateRoot 'latest-status.json')
        Mock Get-Process { [pscustomobject]@{ Id = 101; Path = 'C:\Apps\Codex++\codex-plus-plus.exe' } }
        Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe'
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It '未知状态不强制关闭管理器' {
        Mock Get-Process { [pscustomobject]@{ Id = 101; Path = 'C:\Apps\Codex++\codex-plus-plus.exe' } }
        $caught = $false
        try { Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe' }
        catch { $caught = $true }
        $caught | Should Be $true
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }

    It '旧版仍直接启动，不写新版开关' {
        Mock Get-Item { [pscustomobject]@{ VersionInfo = @{ ProductVersion = '1.7.7' } } }
        Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe'
        Test-Path (Join-Path $script:stateRoot 'watcher.start-codex-on-open') | Should Be $false
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }

    It '状态文件过期但调试端口仍可用时不重启管理器' {
        '{"status":"stopped","debug_port":9229}' | Set-Content (Join-Path $script:stateRoot 'latest-status.json')
        Mock Get-Process { [pscustomobject]@{ Id = 101; Path = 'C:\Apps\Codex++\codex-plus-plus.exe' } }
        Mock Test-CdpAvailable { $true }
        Start-CodexViaLauncher -LauncherPath 'C:\Apps\Codex++\codex-plus-plus.exe'
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}
