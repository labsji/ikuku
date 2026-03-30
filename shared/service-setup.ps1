# shared/service-setup.ps1 — Register scheduled task for any Frappe app
param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$ServiceScript
)

$action = New-ScheduledTaskAction -Execute "powershell" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ServiceScript`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType S4U
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force
Start-ScheduledTask -TaskName $TaskName
