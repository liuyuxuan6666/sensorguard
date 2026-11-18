# SensorGuard - install the PawnIO low-level driver (elevated, one shot)
#
# LibreHardwareMonitor 0.9.5+ replaced WinRing0 with PawnIO. Without PawnIO the library
# can only read values that come from vendor APIs (GPU via NVML/DXGI, NVMe via SMART);
# CPU MSR access and board SuperIO sensors stay empty.
#
# Invoked as:  powershell -Verb RunAs -File scripts\install-pawnio.ps1

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root '_pawnio-result.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

Start-Transcript -Path $out -Force | Out-Null
try {
    Write-Output '=== 0. identity ==='
    Write-Output ("elevated: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

    Write-Output ''
    Write-Output '=== 1. winget install PawnIO ==='
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Output 'winget not available in this elevated session'
    }
    else {
        & winget install --id namazso.PawnIO --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-String | Write-Output
        Write-Output "winget exit code: $LASTEXITCODE"
    }

    Write-Output ''
    Write-Output '=== 2. driver service state ==='
    Get-Service -Name 'PawnIO' -ErrorAction SilentlyContinue |
        Select-Object Name, Status |
        Format-Table -AutoSize | Out-String | Write-Output

    Get-CimInstance Win32_SystemDriver -Filter "Name='PawnIO'" -ErrorAction SilentlyContinue |
        Select-Object Name, State, StartMode, PathName |
        Format-List | Out-String | Write-Output

    Write-Output ''
    Write-Output '=== 3. sensor dump after PawnIO ==='
    & (Join-Path $root 'src\SensorGuard.ps1') -DumpSensors

    Write-Output '=== DONE ==='
}
catch {
    Write-Output ("ERROR: " + $_.Exception.Message)
}
finally {
    Stop-Transcript | Out-Null
}
