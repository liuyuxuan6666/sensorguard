# SensorGuard - remove the scheduled task
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-task.ps1

[CmdletBinding()]
param(
    [string]$TaskName = 'SensorGuard'
)

$ErrorActionPreference = 'Stop'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "task '$TaskName' is not registered" -ForegroundColor Yellow
    return
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

Write-Host "task '$TaskName' removed" -ForegroundColor Green
Write-Host 'logs were left in place under .\logs' -ForegroundColor Cyan
