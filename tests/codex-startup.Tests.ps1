# 模拟应用已启动但窗口仍隐藏，验证快捷方式会补发窗口激活请求。
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'codex-background.ps1')
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
foreach ($name in @('Test-CdpAvailable', 'Start-CodexViaMsix', 'Start-CodexViaLauncher', 'Wait-CdpTargets', 'Get-CodexAumid')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

. (Join-Path $projectRoot 'codex-window.ps1')

Describe '通过 Windows 应用入口显示窗口' {
    BeforeEach {
        Mock Get-CodexAumid { 'OpenAI.Codex_test!App' }
        Mock Start-Process {}
        Mock Write-Warning {}
    }

    It '以正常窗口方式激活应用，不关闭现有进程' {
        Show-CodexWindow -Aumid 'OpenAI.Codex_test!App'
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It -ParameterFilter {
            $FilePath -eq (Join-Path $env:WINDIR 'explorer.exe') -and
            $ArgumentList -eq '"shell:AppsFolder\OpenAI.Codex_test!App"' -and
            $WindowStyle -eq 'Normal'
        }
        Assert-MockCalled Get-CodexAumid -Times 1 -Exactly -Scope It -ParameterFilter {
            $Aumid -eq 'OpenAI.Codex_test!App'
        }
    }

    It '窗口激活失败时告知用户并允许继续注入背景' {
        Mock Start-Process { throw '模拟 Windows 应用入口不可用' }
        { Show-CodexWindow } | Should Not Throw
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It
    }
}
# 提取真实启动分支，避免执行进程清理和背景轮换常驻循环。
$startupStart = $source.IndexOf('    $cdpReady = Test-CdpAvailable')
$startupEnd = $source.IndexOf('    # 4. 构造并注入', $startupStart)
$startup = [scriptblock]::Create($source.Substring($startupStart, $startupEnd - $startupStart))

Describe '启动后显示 Codex 窗口' {
    BeforeEach {
        $DebugPort = 9229
        $CodexAumid = ''
        $NoLaunch = $false
        $hasCodexPlus = $false
        $script:windowVisible = $false
        Mock Test-CdpAvailable { $true }
        Mock Start-CodexViaMsix {}
        Mock Wait-CdpTargets { ,@([pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9229/mock' }) }
        Mock Show-CodexWindow { $script:windowVisible = $true }
    }

    It '直接启动后显示窗口，无需用户再手动打开应用' {
        Mock Test-CdpAvailable { $false }
        . $startup
        $script:windowVisible | Should Be $true
        Assert-MockCalled Start-CodexViaMsix -Times 1 -Exactly -Scope It
    }

    It '复用后台应用时也显示窗口，不重启现有应用' {
        . $startup
        $script:windowVisible | Should Be $true
        Assert-MockCalled Start-CodexViaMsix -Times 0 -Exactly -Scope It
    }

    It 'NoLaunch 只注入背景，不唤起窗口' {
        $NoLaunch = $true
        . $startup
        Assert-MockCalled Show-CodexWindow -Times 0 -Exactly -Scope It
    }
}
