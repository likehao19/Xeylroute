# Exercise the real notification area and menu on the disposable Windows desktop.
param([string]$Tooltip, [string]$QuitLabel)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class TrayMouse {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, System.UIntPtr extra);
}
'@
function Find-ShellControl($Classes, $Property, $Value) {
    $propertyMatch = [System.Windows.Automation.PropertyCondition]::new($Property, $Value)
    foreach ($class in $Classes) {
        $classMatch = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, $class)
        $surface = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $classMatch)
        if ($surface) {
            $control = $surface.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $propertyMatch)
            if ($control -and !$control.Current.IsOffscreen) { return $control }
        }
    }
}
$surfaces = @('Shell_TrayWnd', 'TopLevelWindowForOverflowXamlIsland', 'NotifyIconOverflowWindow')
$name = [System.Windows.Automation.AutomationElement]::NameProperty
$icon = Find-ShellControl $surfaces $name $Tooltip
if (!$icon) {
    $chevron = Find-ShellControl @('Shell_TrayWnd') $name 'Show hidden icons'
    if (!$chevron) {
        $chevron = Find-ShellControl @('Shell_TrayWnd') ([System.Windows.Automation.AutomationElement]::AutomationIdProperty) 'SystemTray.Chevron'
    }
    if (!$chevron) {
        Write-Output 'No accessible notification icon or overflow control in this Windows shell.'
        exit 77
    }
    $chevron.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
$deadline = [DateTime]::UtcNow.AddSeconds(8)
while (!$icon -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $icon = Find-ShellControl $surfaces $name $Tooltip
}
if (!$icon) { throw "Notification icon not found: $Tooltip" }
$point = $icon.GetClickablePoint()
if (![TrayMouse]::SetCursorPos([int]$point.X, [int]$point.Y)) { throw 'Cannot move the test pointer' }
[TrayMouse]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
[TrayMouse]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
$deadline = [DateTime]::UtcNow.AddSeconds(8)
do {
    $quit = Find-ShellControl @('#32768') $name $QuitLabel
    if ($quit) {
        $quit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        return
    }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)
throw 'Quit item was not exposed in the notification menu'
