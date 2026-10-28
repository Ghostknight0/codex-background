# 通过现有 Codex++ 管理器启动 Codex，避免关闭管理器或丢失增强功能。
function Test-CodexDesktopRunning {
    # 使用安装清单和完整路径区分 Codex 桌面程序与其他 ChatGPT 进程。
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
    if (-not $package) { throw '未找到 Codex 安装包，无法确认桌面程序状态。' }
    $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
    $application = $manifest.Package.Applications.Application |
        Where-Object { $_.Id -eq 'App' } | Select-Object -First 1
    if (-not $application.Executable) { throw 'Codex 安装清单缺少桌面程序路径。' }
    $path = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation $application.Executable))
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $path }).Count -gt 0
}

function Find-CodexPlusButton {
    param($Root, [string[]]$Names, [string]$NamePattern = '')
    # 匹配界面上实际可用的按钮，不调用“重启 Codex”。
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Button)
    foreach ($button in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
        $name = $button.Current.Name
        if (($name -in $Names -or ($NamePattern -and $name -match $NamePattern)) -and $button.Current.IsEnabled) { return $button }
    }
    return $null
}

function Start-CodexViaRunningManager {
    param([Parameter(Mandatory)][int]$ManagerId)
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('CodexBackgroundManagerWindow' -as [type])) {
        # MainWindowHandle 可能指向隐藏的事件窗口，按进程和窗口类定位真正的管理器。
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
// 查找 Codex++ 管理器窗口并保留其原有显示状态。
public static class CodexBackgroundManagerWindow {
    private delegate bool EnumCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    public static IntPtr Find(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, data) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (owner == (uint)processId && name.ToString() == "Tauri Window") { found = window; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
    }
    $handle = [CodexBackgroundManagerWindow]::Find($ManagerId)
    if ($handle -eq [IntPtr]::Zero) { throw '未找到 Codex++ 管理器窗口，请在管理器中手动启动 Codex。' }
    $wasVisible = [CodexBackgroundManagerWindow]::IsWindowVisible($handle)
    try {
        # 隐藏的 WebView 不提供界面元素，临时显示但不抢焦点。
        if (-not $wasVisible) { [void][CodexBackgroundManagerWindow]::ShowWindow($handle, 4) }
        $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
        if (-not $root) { throw '无法读取 Codex++ 窗口。' }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $navigationDone = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-CodexDesktopRunning) { return }
            $button = Find-CodexPlusButton -Root $root -Names @('启动 Codex', 'Start Codex')
            if ($button) {
                # 再次核对进程，避免启动期间重复触发。
                if (Test-CodexDesktopRunning) { return }
                $pattern = $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
                $pattern.Invoke()
                Write-Host '已通过正在运行的 Codex++ 管理器请求启动 Codex。'
                return
            }
            if (-not $navigationDone) {
                # 其他页面没有启动按钮时，进入 Codex 概览；不修改配置。
                $nav = Find-CodexPlusButton -Root $root -Names @('Codex') -NamePattern '^Codex\s*[·•]'
                if ($nav) {
                    $nav.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $navigationDone = $true
                }
            }
            Start-Sleep -Milliseconds 500
        }
        throw '未找到可用的“启动 Codex”按钮，请在 Codex++ 管理器中手动启动。'
    }
    finally {
        if (-not $wasVisible) { [void][CodexBackgroundManagerWindow]::ShowWindow($handle, 0) }
    }
}
