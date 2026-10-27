# 验证真实页面发现函数逐个返回目标，避免多个页面的连接地址被拼成一个字符串。
$projectRoot = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $projectRoot 'codex-background.ps1'), [ref]$null, [ref]$null)
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-CdpTargets'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))

Describe 'CDP 页面返回格式' {
    BeforeEach {
        # 模拟新版应用同时存在主窗口和快捷浮窗，保留调用方实际使用的数组收集方式。
        Mock Invoke-RestMethod { @(
            [pscustomobject]@{ type = 'page'; title = 'Codex'; url = 'app://-/index.html';
                webSocketDebuggerUrl = 'ws://127.0.0.1:9229/devtools/page/main' },
            [pscustomobject]@{ type = 'page'; title = 'ChatGPT'; url = 'app://-/index.html?initialRoute=spotlight';
                webSocketDebuggerUrl = 'ws://127.0.0.1:9229/devtools/page/spotlight' }
        ) }
    }

    It '两个页面各自保留独立的连接地址' {
        $targets = @(Wait-CdpTargets -Port 9229)
        $targets.Count | Should Be 2
        ([string]$targets[0].webSocketDebuggerUrl) | Should Be 'ws://127.0.0.1:9229/devtools/page/main'
        ([string]$targets[1].webSocketDebuggerUrl) | Should Be 'ws://127.0.0.1:9229/devtools/page/spotlight'
    }

    It '单个页面仍能按相同方式读取' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ type = 'page'; title = 'Codex'; url = 'app://-/index.html';
                webSocketDebuggerUrl = 'ws://127.0.0.1:9229/devtools/page/main' }
        }
        $targets = @(Wait-CdpTargets -Port 9229)
        $targets.Count | Should Be 1
        ($targets[0] -is [Collections.Generic.List[object]]) | Should Be $false
        ([string]$targets[0].webSocketDebuggerUrl) | Should Be 'ws://127.0.0.1:9229/devtools/page/main'
    }
}
