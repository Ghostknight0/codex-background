# 页面刷新不会断开调试端口；单独检查背景是否还在，并在丢失时恢复当前媒体。
function Restore-CodexBackground {
    param(
        [Parameter(Mandatory)][string]$WebSocketUrl,
        [Parameter(Mandatory)][string]$JavaScript,
        [Parameter(Mandatory)][string]$MediaPath,
        [Parameter(Mandatory)][string]$MediaType
    )

    # 每次只取三个布尔值，背景正常时不读取或传输媒体文件。
    $probe = @'
({
    ready: document.readyState !== "loading",
    installed: !!window.__czBgRotator,
    hasMedia: !!document.getElementById("cz-bg-rotator-overlay")
})
'@
    $response = Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method 'Runtime.evaluate' `
        -Parameters @{ expression = $probe; returnByValue = $true }
    if ($response.exceptionDetails -or -not $response.result.value) {
        throw '无法读取页面背景状态，等待下一次检查。'
    }
    $state = $response.result.value
    if (-not $state.ready -or ($state.installed -and $state.hasMedia)) { return $false }

    if (-not $state.installed) {
        # 只恢复当前文档，避免每次修复都重复注册“新文档加载”脚本。
        $null = Invoke-CdpCommand -WebSocketUrl $WebSocketUrl -Method 'Runtime.evaluate' `
            -Parameters @{ expression = $JavaScript; returnByValue = $true; awaitPromise = $true }
    }
    Send-MediaToPage -WebSocketUrl $WebSocketUrl -Path $MediaPath -MediaType $MediaType
    Write-Host '检测到页面刷新或背景丢失，已恢复当前媒体。'
    return $true
}
