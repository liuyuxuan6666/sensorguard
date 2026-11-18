# SensorGuard - register a scheduled task that starts the watchdog at boot
#
# MUST be run from an elevated PowerShell (RunLevel Highest is required to read
# CPU package / motherboard / NVMe sensors).
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1 -S4U
#
# Default logon type is Interactive: the task starts at boot but needs the user to be
# logged in (typical for a 24/7 desktop that auto-logs-in). Use -S4U to run without an
# interactive session; outbound webhook calls still work, but the process loses access
# to per-user mapped resources.

[CmdletBinding()]
param(
    [string]$TaskName = 'SensorGuard',
    [switch]$S4U,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'this script must be run as Administrator (sensor access + RunLevel Highest)'
}

$root = Split-Path $PSScriptRoot -Parent
$entry = Join-Path $root 'src\SensorGuard.ps1'
$config = Join-Path $root 'config.json'

if (-not (Test-Path -LiteralPath $entry)) { throw "entry script not found: $entry" }
if (-not (Test-Path -LiteralPath $config)) {
    throw "config.json not found - copy config.example.json and fill in the Feishu webhook first"
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$entry`""

$action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments -WorkingDirectory $root

# At boot + every 5 minutes as a safety net: if the process dies the task restarts it.
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup)
)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

$logonType = if ($S4U) { 'S4U' } else { 'Interactive' }
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType $logonType -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "task '$TaskName' registered (logon=$logonType, RunLevel=Highest)" -ForegroundColor Green

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
    Write-Host "logs: $root\logs" -ForegroundColor Cyan
}
else {
    Write-Host "start it now with:  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
}
