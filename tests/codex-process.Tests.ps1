# 验证重启只关闭桌面应用，保留 CLI 和同名的其他应用；全程使用模拟进程。
$projectRoot = Split-Path -Parent $PSScriptRoot
$processScript = Join-Path $projectRoot 'codex-process.ps1'
if (Test-Path $processScript) {
    . $processScript
} else {
    # 修复前从主脚本提取函数，避免执行实际启动和关闭操作。
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot 'codex-background.ps1'), [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Stop-CodexProcesses'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Codex 桌面进程关闭范围' {
    It '关闭新版桌面窗口，保留 CLI 和其他 ChatGPT 应用' {
        $script:closedIds = @()
        $script:queries = 0
        # 安装清单决定桌面程序路径，不依赖固定的进程名称。
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = 'C:\Apps\Codex' } }
        Mock Get-AppxPackageManifest {
            [pscustomobject]@{ Package = @{ Applications = @{ Application = @(
                [pscustomobject]@{ Id = 'App'; Executable = 'app/ChatGPT.exe' }
            ) } } }
        }
        $script:fakeProcesses = @(
            [pscustomobject]@{ Id = 41; ProcessName = 'Codex'; Path = 'C:\CLI\codex.exe'; MainWindowHandle = 1 },
            [pscustomobject]@{ Id = 42; ProcessName = 'ChatGPT'; Path = 'C:\Apps\Codex\app\ChatGPT.exe'; MainWindowHandle = 1 },
            [pscustomobject]@{ Id = 43; ProcessName = 'ChatGPT'; Path = 'C:\Apps\Other\ChatGPT.exe'; MainWindowHandle = 1 }
        )
        foreach ($process in $script:fakeProcesses) {
            $process | Add-Member ScriptMethod CloseMainWindow { $script:closedIds += $this.Id; return $true }
        }
        Mock Get-Process {
            param($Name, $Id)
            $script:queries++
            if ($script:queries -eq 1) {
                $script:fakeProcesses | Where-Object { -not $Name -or $_.ProcessName -in $Name }
            }
        }
        Mock Start-Sleep {}
        Mock Stop-Process { throw '测试禁止真实终止进程' }
        Stop-CodexProcesses
        ($script:closedIds -join ',') | Should Be '42'
    }
}
