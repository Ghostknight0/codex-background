# 背景脚本采用单文件实现，这些静态契约用于防止整文件媒体复制问题回归。
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot "codex-background.ps1"
$source = Get-Content -Raw -LiteralPath $scriptPath

# 提取精确函数范围，避免其他辅助函数或注释意外满足断言。
function Get-FunctionSource {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$FollowingFunction
    )

    $pattern = '(?s)function {0} \{{.*?(?=function {1} \{{)' -f [regex]::Escape($Name), [regex]::Escape($FollowingFunction)
    $match = [regex]::Match($source, $pattern)
    if (-not $match.Success) {
        throw "Unable to extract function: $Name"
    }
    return $match.Value
}

Describe "Background media streaming contracts" {
    $sendMediaSource = Get-FunctionSource -Name "Send-MediaToPage" -FollowingFunction "Resolve-MediaForCurrentRun"
    $overlaySource = Get-FunctionSource -Name "New-OverlayJavaScript" -FollowingFunction "Install-CodexBackground"

    It "reads media with FileStream chunks instead of one full-file allocation" {
        $sendMediaSource | Should Match '\[IO\.File\]::OpenRead'
        $sendMediaSource | Should Not Match '\[IO\.File\]::ReadAllBytes'
        $sendMediaSource | Should Match '393216'
    }

    It "does not construct one full Base64 string in PowerShell" {
        $sendMediaSource | Should Not Match '\$base64\s*='
        $sendMediaSource | Should Not Match '\.Substring\(\$off'
    }

    It "decodes page chunks incrementally without joining all Base64 text" {
        $overlaySource | Should Match 'function decodeBase64Chunk'
        $overlaySource | Should Match 'Uint8Array'
        $overlaySource | Should Not Match 'parts\.join\(''''\)'
    }

    It "exposes transfer abort and background resource cleanup" {
        $overlaySource | Should Match 'abortChunkedMedia'
        $overlaySource | Should Match 'dispose'
        $overlaySource | Should Match 'URL\.revokeObjectURL\('
    }

    It "does not terminate an active background process during ValidateOnly" {
        $source | Should Match '(?s)if \(-not \$ValidateOnly\) \{.*?Get-CimInstance Win32_Process.*?Start-Sleep -Milliseconds 500.*?\}'
    }

    It "clears src before removing both image and video backgrounds" {
        $overlaySource | Should Match '(?s)function removeMediaElement\(el\) \{.*?const tagName = el\.tagName\.toLowerCase\(\);.*?el\.removeAttribute\("src"\);.*?if \(tagName === "video"\) \{.*?el\.load\(\);'
    }
}
