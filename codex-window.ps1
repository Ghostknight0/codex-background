# 通过 Windows 应用入口显示已启动的 Codex 窗口，不重启或关闭现有会话。
function Show-CodexWindow {
    param(
        # 留空时沿用主脚本的安装包探测，手动指定时使用同一应用标识。
        [string]$Aumid = ''
    )

    try {
        $resolvedAumid = Get-CodexAumid -Aumid $Aumid
        # 与从开始菜单打开应用相同，由 Windows 通知现有实例显示主窗口。
        # 这里需要显示应用，因此使用 Normal；后台 PowerShell 仍保持无控制台。
        $explorerPath = Join-Path $env:WINDIR 'explorer.exe'
        Start-Process -FilePath $explorerPath `
            -ArgumentList ('"shell:AppsFolder\{0}"' -f $resolvedAumid) `
            -WindowStyle Normal -ErrorAction Stop | Out-Null
        Write-Host '已请求显示 Codex 主窗口。'
    }
    catch {
        # 显示窗口失败不能中断已经可用的背景注入与轮换。
        Write-Warning "无法自动显示 Codex 窗口，可从开始菜单打开：$($_.Exception.Message)"
    }
}
