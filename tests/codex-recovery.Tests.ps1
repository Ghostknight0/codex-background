# 模拟 Codex++ 刷新页面后的背景丢失，验证只在需要时重新推送媒体。
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'codex-recovery.ps1')
# 仅提供测试替身入口，真实的恢复函数通过与主脚本相同的接口调用。
function Invoke-CdpCommand { param($WebSocketUrl, $Method, $Parameters) }
function Send-MediaToPage { param($WebSocketUrl, $Path, $MediaType) }

Describe '页面刷新后的背景恢复' {
    BeforeEach {
        Mock Invoke-CdpCommand { @{ result = @{ value = @{ ready = $true; installed = $true; hasMedia = $false } } } }
        Mock Send-MediaToPage {}
        $arguments = @{ WebSocketUrl = 'ws://127.0.0.1/mock'; JavaScript = 'install-background'; MediaPath = 'D:\wallpaper\current.mp4'; MediaType = 'video' }
    }

    It '刷新后控制脚本还在但媒体丢失时补回当前视频' {
        Restore-CodexBackground @arguments | Should Be $true
        Assert-MockCalled Send-MediaToPage -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -eq 'D:\wallpaper\current.mp4' -and $MediaType -eq 'video'
        }
        Assert-MockCalled Invoke-CdpCommand -Times 1 -Exactly -Scope It
    }

    It '新页面没有控制脚本时先安装再恢复媒体' {
        Mock Invoke-CdpCommand { @{ result = @{ value = @{ ready = $true; installed = $false; hasMedia = $false } } } }
        Restore-CodexBackground @arguments | Should Be $true
        Assert-MockCalled Invoke-CdpCommand -Times 1 -Exactly -Scope It -ParameterFilter {
            $Parameters.expression -eq 'install-background'
        }
        Assert-MockCalled Send-MediaToPage -Times 1 -Exactly -Scope It
    }

    It '背景正常时不重复传输视频' {
        Mock Invoke-CdpCommand { @{ result = @{ value = @{ ready = $true; installed = $true; hasMedia = $true } } } }
        Restore-CodexBackground @arguments | Should Be $false
        Assert-MockCalled Send-MediaToPage -Times 0 -Exactly -Scope It
    }

    It '文档还在加载时不注入' {
        Mock Invoke-CdpCommand { @{ result = @{ value = @{ ready = $false; installed = $false; hasMedia = $false } } } }
        Restore-CodexBackground @arguments | Should Be $false
        Assert-MockCalled Send-MediaToPage -Times 0 -Exactly -Scope It
    }
}
