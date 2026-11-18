# SensorGuard - bootstrap: fetch LibreHardwareMonitor payload and seed config
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Proxy http://127.0.0.1:7897
#
# Downloads the official LibreHardwareMonitor release (net472 build, which is the one
# Windows PowerShell 5.1 can load) into .\vendor and copies config.example.json.

[CmdletBinding()]
param(
    [string]$Proxy = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vendor = Join-Path $root 'vendor'
$dllTarget = Join-Path $vendor 'LibreHardwareMonitorLib.dll'

if ($Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
}

if ((Test-Path -LiteralPath $dllTarget) -and -not $Force) {
    Write-Host "vendor already populated: $dllTarget" -ForegroundColor Green
}
else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host 'querying latest LibreHardwareMonitor release...'
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' `
        -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'SensorGuard-setup' }

    $assets = @($rel.assets | Where-Object { $_.name -like '*.zip' })
    if ($assets.Count -eq 0) { throw 'no zip asset found in the latest release' }

    # Prefer the net472 build; fall back to the first zip that is not net10.
    $pick = $assets | Where-Object { $_.name -match 'net472' } | Select-Object -First 1
    if (-not $pick) {
        $pick = $assets | Where-Object { $_.name -notmatch 'net10' } | Select-Object -First 1
    }
    if (-not $pick) { $pick = $assets[0] }

    Write-Host "downloading $($pick.name) ..."
    $tmpZip = Join-Path $env:TEMP ("lhm-" + $pick.name)
    Invoke-WebRequest -Uri $pick.browser_download_url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 300

    if (Test-Path -LiteralPath $vendor) { Remove-Item -LiteralPath $vendor -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $vendor | Out-Null

    $tmpDir = Join-Path $env:TEMP 'lhm-extract'
    if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
    Copy-Item -Path (Join-Path $tmpDir '*') -Destination $vendor -Recurse -Force
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $dllTarget)) {
        throw "download finished but LibreHardwareMonitorLib.dll is missing under $vendor"
    }
    Write-Host "vendor ready: $vendor" -ForegroundColor Green
}

$cfg = Join-Path $root 'config.json'
if (-not (Test-Path -LiteralPath $cfg)) {
    Copy-Item -LiteralPath (Join-Path $root 'config.example.json') -Destination $cfg
    Write-Host "created config.json - edit feishu.webhook and feishu.secret" -ForegroundColor Yellow
}
else {
    Write-Host 'config.json already exists, left untouched'
}

Write-Host ''
Write-Host 'next steps:' -ForegroundColor Cyan
Write-Host '  1. edit config.json (feishu webhook + secret)'
Write-Host '  2. run elevated:  powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1'
Write-Host '  3. or run in foreground:  powershell -ExecutionPolicy Bypass -File .\src\SensorGuard.ps1'
