# SensorGuard - one-shot elevated bootstrap (run via UAC)
#
# Does three things in one elevated session and records everything to a log file so
# an unattended parent process can read the outcome:
#   1. dump every readable sensor (confirms CPU package / NVMe temps are available)
#   2. register the scheduled task (RunLevel Highest) and start it
#   3. report the task state
#
# Invoked as:  powershell -Verb RunAs -File scripts\elevate.ps1

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root '_elevated-result.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

Start-Transcript -Path $out -Force | Out-Null
try {
    Write-Output "=== 0. identity ==="
    whoami
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Output "elevated: $isAdmin"
    Write-Output ''

    Write-Output '=== 1. sensor dump (elevated) ==='
    & (Join-Path $root 'src\SensorGuard.ps1') -DumpSensors
    Write-Output ''

    Write-Output '=== 2. register + start scheduled task ==='
    & (Join-Path $root 'scripts\install-task.ps1') -StartNow
    Write-Output ''

    Write-Output '=== 3. task state ==='
    Get-ScheduledTask -TaskName 'SensorGuard' -ErrorAction SilentlyContinue |
        Select-Object TaskName, State |
        Format-Table -AutoSize | Out-String | Write-Output
    Write-Output '=== DONE ==='
}
catch {
    Write-Output ("ERROR: " + $_.Exception.Message)
}
finally {
    Stop-Transcript | Out-Null
}
