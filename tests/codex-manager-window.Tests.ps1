# 使用真实 Windows 窗口验证管理器复用，覆盖原先模拟测试漏掉的隐藏窗口问题。
param([string]$ManagerSource = '')
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($ManagerSource) { . ([scriptblock]::Create($ManagerSource)) }
else { . (Join-Path $projectRoot 'codex-plus-manager.ps1') }
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Describe '真实管理器窗口的启动操作' {
    BeforeEach {
        $script:fixtureExe = Join-Path $TestDrive 'codex-manager-window-fixture.exe'
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $compiler /nologo /target:winexe /codepage:65001 "/out:$script:fixtureExe" (Join-Path $PSScriptRoot 'fixtures\codex-manager-window.cs')
        if ($LASTEXITCODE -ne 0) { throw '测试窗口编译失败' }
        $script:fixture = Start-Process -FilePath $script:fixtureExe -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        # 测试窗口用“已启动”标记模拟桌面进程出现，不启动真正的聊天应用。
        Mock Test-CodexDesktopRunning {
            $root = Get-CodexPlusManagerWindow -ManagerId $script:fixture.Id
            if (-not $root) { return $false }
            $condition = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::NameProperty, '已启动')
            return $null -ne $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        }
    }
    AfterEach {
        # 只结束本用例创建的测试进程，不操作真实管理器或聊天应用。
        Stop-Process -Id $script:fixture.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $script:fixture.Id -Timeout 5 -ErrorAction SilentlyContinue
    }

    It '启动按钮被实际调用后，管理器仍然显示且进程未重启' {
        # 同一个测试也能运行旧实现，证明旧代码确实会在操作完成后隐藏窗口。
        $arguments = @{ ManagerId = $script:fixture.Id }
        if ((Get-Command Start-CodexViaRunningManager).Parameters.ContainsKey('LauncherPath')) {
            $arguments.LauncherPath = $script:fixtureExe
        }
        Start-CodexViaRunningManager @arguments
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ProcessIdProperty, $script:fixture.Id)
        $root = [Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [Windows.Automation.TreeScope]::Children, $condition)
        ($null -ne $root) | Should Be $true
        $button = Find-CodexPlusButton -Root $root -Names @('已启动')
        ($null -ne $button) | Should Be $true
        (Get-Process -Id $script:fixture.Id).Id | Should Be $script:fixture.Id
    }

    if (-not $ManagerSource) {
        It '启动请求没有生效时，继续等待并报告失败，不重复点击' {
            Stop-Process -Id $script:fixture.Id -Force
            Wait-Process -Id $script:fixture.Id -Timeout 5 -ErrorAction SilentlyContinue
            $script:fixture = Start-Process -FilePath $script:fixtureExe -ArgumentList 'request-pending' -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500
            Mock Test-CodexDesktopRunning { $false }
            $failure = $null
            try { Start-CodexViaRunningManager -ManagerId $script:fixture.Id -LauncherPath $script:fixtureExe -TimeoutSeconds 2 }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match '仍未检测到桌面进程'
            $root = Get-CodexPlusManagerWindow -ManagerId $script:fixture.Id
            ($null -ne $root) | Should Be $true
            $condition = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::NameProperty, '请求次数：1')
            ($null -ne $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)) | Should Be $true
        }

        It '从其他页面通过 TogglePattern 导航后，一次操作就能启动' {
            Stop-Process -Id $script:fixture.Id -Force
            Wait-Process -Id $script:fixture.Id -Timeout 5 -ErrorAction SilentlyContinue
            $script:fixture = Start-Process -FilePath $script:fixtureExe -ArgumentList 'navigation' -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500
            # 原生测试控件的类型是 CheckBox，但模式与实际 WebView 导航按钮相同。
            # 只调整元素查找，导航和启动均走真实窗口操作。
            $script:realFindButton = ${function:Find-CodexPlusButton}
            Mock Find-CodexPlusButton {
                param($Root, $Names, $NamePattern)
                if ($NamePattern) {
                    $condition = [Windows.Automation.PropertyCondition]::new(
                        [Windows.Automation.AutomationElement]::NameProperty, 'Codex · 未运行')
                    return $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
                }
                & $script:realFindButton -Root $Root -Names $Names
            }
            Start-CodexViaRunningManager -ManagerId $script:fixture.Id -LauncherPath $script:fixtureExe -TimeoutSeconds 3
            $root = Get-CodexPlusManagerWindow -ManagerId $script:fixture.Id
            $button = & $script:realFindButton -Root $root -Names @('已启动')
            ($null -ne $button) | Should Be $true
        }

        It '没有启动按钮时报告失败，管理器界面仍可操作' {
            Stop-Process -Id $script:fixture.Id -Force
            Wait-Process -Id $script:fixture.Id -Timeout 5 -ErrorAction SilentlyContinue
            $script:fixture = Start-Process -FilePath $script:fixtureExe -ArgumentList 'no-start' -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500
            $failure = $null
            try { Start-CodexViaRunningManager -ManagerId $script:fixture.Id -LauncherPath $script:fixtureExe -TimeoutSeconds 2 }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match '未找到可用的'
            $root = Get-CodexPlusManagerWindow -ManagerId $script:fixture.Id
            ($null -ne $root) | Should Be $true
            $button = Find-CodexPlusButton -Root $root -Names @('重启 Codex')
            # 确保没有把“重启 Codex”误当成“启动 Codex”调用。
            ($null -ne $button) | Should Be $true
        }

        It '桌面程序已经运行时，不显示或隐藏管理器' {
            Mock Test-CodexDesktopRunning { $true }
            Mock Start-Process {}
            Start-CodexViaRunningManager -ManagerId $script:fixture.Id -LauncherPath $script:fixtureExe
            Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
            $root = Get-CodexPlusManagerWindow -ManagerId $script:fixture.Id
            ($null -eq $root) | Should Be $true
        }
    }
}
