param([int]$AppProcess, [string]$ControlId, [string]$Label, [string]$Action)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$byId = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $ControlId)
$byName = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Label)
$match = [System.Windows.Automation.OrCondition]::new($byId, $byName)
$deadline = [DateTime]::UtcNow.AddSeconds(40)
do {
    $handle = (Get-Process -Id $AppProcess).MainWindowHandle
    if ($handle -ne 0) {
        $window = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $control = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $match)
        if ($control -and $control.Current.IsEnabled) {
            if ($Action -eq 'click') {
                if ($ControlId.StartsWith('side')) {
                    $control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
                } else {
                    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                }
                return
            }
            $state = $control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
            if ($state.ToString() -eq $Action) { return }
        }
    }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)
if ($window) {
    $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Select-Object -First 35 | ForEach-Object { Write-Output "$($_.Current.AutomationId) $($_.Current.Name)" }
}
throw "Desktop control $ControlId did not reach $Action"
