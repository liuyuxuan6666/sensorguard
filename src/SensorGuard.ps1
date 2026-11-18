# SensorGuard - main entry point (PowerShell 5.1 compatible)
#
#   .\src\SensorGuard.ps1                     # run the watchdog loop
#   .\src\SensorGuard.ps1 -DumpSensors        # print every readable sensor and exit
#   .\src\SensorGuard.ps1 -Once -DryRun       # one evaluation pass, print instead of send
#   .\src\SensorGuard.ps1 -TestNotify         # send a test card to the configured webhook
#
# Requires an elevated PowerShell for CPU package / motherboard / NVMe temperatures.

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$DryRun,
    [switch]$DumpSensors,
    [switch]$TestNotify
)

$ErrorActionPreference = 'Stop'

$srcRoot = $PSScriptRoot
$projectRoot = Split-Path $srcRoot -Parent

. (Join-Path $srcRoot 'lib\Logging.ps1')
. (Join-Path $srcRoot 'lib\Collector.ps1')
. (Join-Path $srcRoot 'lib\Rules.ps1')
. (Join-Path $srcRoot 'lib\Notify.ps1')
. (Join-Path $srcRoot 'lib\Procs.ps1')

function Get-Config {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $projectRoot 'config.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "config not found: $Path (copy config.example.json to config.json)"
    }
    $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Resolve-LhmDll {
    param($Config)
    $candidates = @()
    if ($Config.lhm -and $Config.lhm.dllPath) { $candidates += $Config.lhm.dllPath }
    $candidates += (Join-Path $projectRoot 'vendor\LibreHardwareMonitorLib.dll')
    if ($env:TEMP) { $candidates += (Join-Path $env:TEMP 'lhm\LibreHardwareMonitorLib.dll') }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "LibreHardwareMonitorLib.dll not found. Run scripts\setup.ps1 or set lhm.dllPath in config.json."
}

function Show-Banner {
    param($Health, $SensorCount, [string]$DllPath)
    Write-Host ''
    Write-Host '  SensorGuard' -ForegroundColor Cyan
    Write-Host "  host      : $env:COMPUTERNAME"
    Write-Host "  library   : $DllPath"
    Write-Host "  sensors   : $SensorCount readable"
    Write-Host "  elevated  : $($Health.Elevated)" -ForegroundColor $(if ($Health.Elevated) { 'Green' } else { 'Yellow' })
    Write-Host "  cpu temp  : $($Health.CpuTempSensors) sensor(s)"
    Write-Host "  gpu temp  : $($Health.GpuTempSensors) sensor(s)"
    Write-Host "  disk temp : $($Health.StorageTempSensors) sensor(s)"
    if ($Health.Missing.Count -gt 0) {
        Write-Host "  missing   : $($Health.Missing -join ', ')" -ForegroundColor Yellow
        if (-not $Health.Elevated) {
            Write-Host '  hint      : run as Administrator to read CPU / motherboard / NVMe sensors' -ForegroundColor Yellow
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- startup

$config = Get-Config -Path $ConfigPath
$rules = @($config.rules | Where-Object { $_ })
$interval = if ($config.intervalSeconds) { [int]$config.intervalSeconds } else { 15 }
if ($interval -lt 5) { $interval = 5 }

$logRoot = if ($config.logging.dir) {
    if ([System.IO.Path]::IsPathRooted($config.logging.dir)) { $config.logging.dir }
    else { Join-Path $projectRoot $config.logging.dir }
}
else { Join-Path $projectRoot 'logs' }
if (-not (Test-Path -LiteralPath $logRoot)) { New-Item -ItemType Directory -Force -Path $logRoot | Out-Null }

$keepDays = if ($null -ne $config.logging.keepDays) { [int]$config.logging.keepDays } else { 14 }
$sampleEvery = if ($config.logging.sampleIntervalSeconds) { [int]$config.logging.sampleIntervalSeconds } else { 60 }
$repeatSec = if ($config.feishu.minRepeatSeconds) { [int]$config.feishu.minRepeatSeconds } else { 180 }
$topN = if ($config.attribution -and $config.attribution.topN) { [int]$config.attribution.topN } else { 3 }
$attributionOn = -not ($config.attribution -and $config.attribution.enabled -eq $false)

$dllPath = Resolve-LhmDll -Config $config
Write-ConsoleLine "loading $dllPath"
$computer = Initialize-Lhm -DllPath $dllPath

try {
    $sensors = Get-HardwareInventory -Computer $computer
    $health = Get-SensorHealth -Sensors $sensors
    Show-Banner -Health $health -SensorCount $sensors.Count -DllPath $dllPath

    if ($DumpSensors) {
        $sensors | Sort-Object HardwareType, Hardware, SensorType, Sensor |
            Format-Table HardwareType, Hardware, SensorType, Sensor, Value, Unit -AutoSize |
            Out-String -Width 200 | Write-Host
        return
    }

    if ($TestNotify) {
        $fake = @([pscustomobject]@{
                Kind        = 'firing'
                IsNew       = $true
                RuleId      = 'test'
                Severity    = 'critical'
                Hardware    = 'SensorGuard'
                HardwareType = 'Cpu'
                Sensor      = 'test card'
                SensorType  = 'Temperature'
                Value       = 99.9
                Unit        = 'C'
                Op          = '>'
                Threshold   = 90
                HeldSeconds = 0
                At          = Get-Date
            })
        $r = Send-AlertCard -Config $config -Items $fake -Kind 'firing' -DryRun:$DryRun
        if ($r.Ok) { Write-ConsoleLine 'test card handled' 'OK' }
        else { Write-ConsoleLine "test card failed: $($r.Error)" 'ERROR' }
        return
    }

    if ($config.feishu.enabled -eq $true) {
        $wh = if ($config.feishu.webhook) { $config.feishu.webhook } else { '' }
        if ($wh -like '*REPLACE_ME*' -or [string]::IsNullOrEmpty($wh)) {
            Write-ConsoleLine 'feishu.webhook is not configured; alerts will only be logged' 'WARN'
        }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\SensorGuard')
    if (-not $mutex.WaitOne(0)) {
        Write-ConsoleLine 'another SensorGuard instance is already running' 'WARN'
        return
    }

    $states = @{}
    $lastSampleLog = [datetime]::MinValue
    $lastCleanup = Get-Date
    $startedAt = Get-Date
    $round = 0

    Write-ConsoleLine "watchdog started (interval ${interval}s, repeat ${repeatSec}s, ${topN} proc attribution)" 'OK'
    Write-ConsoleLine 'press Ctrl+C to stop'

    while ($true) {
        $round++
        $now = Get-Date
        try {
            $sensors = Get-HardwareInventory -Computer $computer
            $eval = Invoke-RuleEvaluation -Rules $rules -Sensors $sensors -States $states `
                -Now $now -DefaultRepeatSeconds $repeatSec

            $top = @()
            if ($eval.Firings.Count -gt 0 -and $attributionOn) {
                $top = @(Get-TopProcesses -Count $topN -Metric 'cpu')
            }

            $paths = Get-LogPaths -Root $logRoot -Time $now

            if ($eval.Firings.Count -gt 0) {
                # One card per round: a burst of simultaneously failing rules becomes a
                # single webhook call instead of N calls, which keeps us far from the
                # bot rate limit and reads better in the chat.
                $result = Send-AlertCard -Config $config -Items $eval.Firings -Kind 'firing' `
                    -TopProcesses $top -DryRun:$DryRun
                foreach ($f in $eval.Firings) {
                    Write-JsonLine -Path $paths.Event -Object ([ordered]@{
                            ts           = $now.ToString('o')
                            type         = if ($f.IsNew) { 'firing-new' } else { 'firing-repeat' }
                            ruleId       = $f.RuleId
                            severity     = $f.Severity
                            hardware     = $f.Hardware
                            sensor       = $f.Sensor
                            value        = [math]::Round($f.Value, 2)
                            unit         = $f.Unit
                            op           = $f.Op
                            threshold    = $f.Threshold
                            heldSeconds  = $f.HeldSeconds
                            dryRun       = [bool]$DryRun
                            notified     = [bool]$result.Ok
                            attempts     = $result.Attempts
                            error        = $result.Error
                        })
                    if ($result.Ok) {
                        Write-ConsoleLine ("ALERT {0}/{1} {2} = {3}{4} (>={5}s)" -f $f.Severity, $f.RuleId,
                            $f.Hardware, ([math]::Round($f.Value, 1)), $f.Unit, [int]$f.HeldSeconds) 'ERROR'
                    }
                    else {
                        Write-ConsoleLine ("notify failed for {0}: {1}" -f $f.RuleId, $result.Error) 'ERROR'
                    }
                }
            }

            if ($eval.Recoveries.Count -gt 0) {
                $result = Send-AlertCard -Config $config -Items $eval.Recoveries -Kind 'recovery' -DryRun:$DryRun
                foreach ($r in $eval.Recoveries) {
                    Write-JsonLine -Path $paths.Event -Object ([ordered]@{
                            ts        = $now.ToString('o')
                            type      = 'recovery'
                            ruleId    = $r.RuleId
                            severity  = $r.Severity
                            hardware  = $r.Hardware
                            sensor    = $r.Sensor
                            value     = if ($null -ne $r.Value) { [math]::Round($r.Value, 2) } else { $null }
                            unit      = $r.Unit
                            reason    = $r.Reason
                            dryRun    = [bool]$DryRun
                            notified  = [bool]$result.Ok
                            attempts  = $result.Attempts
                            error     = $result.Error
                        })
                    Write-ConsoleLine ("RECOVERED {0} / {1}" -f $r.RuleId, $r.Hardware) 'OK'
                }
            }

            if (($now - $lastSampleLog).TotalSeconds -ge $sampleEvery) {
                $lastSampleLog = $now
                $slim = @($sensors | Where-Object {
                        ($_.SensorType -eq 'Temperature' -and $_.Sensor -notmatch '(?i)(warning|critical|limit|distance)') -or
                        ($_.SensorType -eq 'Load' -and $_.HardwareType -like 'Gpu*')
                    } | ForEach-Object {
                        [ordered]@{
                            hw    = $_.Hardware
                            hwType = $_.HardwareType
                            sensor = $_.Sensor
                            type  = $_.SensorType
                            value = [math]::Round($_.Value, 1)
                        }
                    })
                Write-JsonLine -Path $paths.Sample -Object ([ordered]@{
                        ts     = $now.ToString('o')
                        round  = $round
                        uptimeS = [int]($now - $startedAt).TotalSeconds
                        firing = $eval.Active.Count
                        sensors = $slim
                    })
            }

            if (($now - $lastCleanup).TotalHours -ge 6) {
                $lastCleanup = $now
                Remove-ExpiredLogs -Root $logRoot -KeepDays $keepDays
            }

            if ($Once) {
                Write-ConsoleLine ("single pass done: {0} firing, {1} recovery, {2} sensors" -f `
                        $eval.Firings.Count, $eval.Recoveries.Count, $sensors.Count) 'OK'
                break
            }
        }
        catch {
            Write-ConsoleLine "round failed: $($_.Exception.Message)" 'ERROR'
        }

        if ($Once) { break }
        Start-Sleep -Seconds $interval
    }
}
finally {
    try { $computer.Close() } catch { }
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
    Write-ConsoleLine 'stopped' 'OK'
}
