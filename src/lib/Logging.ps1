# SensorGuard - logging helpers (PowerShell 5.1 compatible)

function Get-LogPaths {
    param(
        [Parameter(Mandatory)][string]$Root,
        [datetime]$Time = (Get-Date)
    )
    $day = $Time.ToString('yyyy-MM-dd')
    $dir = Join-Path $Root $day
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [pscustomobject]@{
        Dir    = $dir
        Sample = Join-Path $dir 'sample.jsonl'
        Event  = Join-Path $dir 'event.jsonl'
    }
}

function Write-JsonLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $json + "`r`n", $enc)
}

function Remove-ExpiredLogs {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$KeepDays = 14
    )
    if ($KeepDays -le 0) { return }
    if (-not (Test-Path $Root)) { return }
    $cut = (Get-Date).Date.AddDays(-$KeepDays)
    Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        ForEach-Object {
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($_.Name, 'yyyy-MM-dd', $null, 0, [ref]$d)) {
                if ($d -lt $cut) {
                    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
}

function Write-ConsoleLine {
    param([string]$Text, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Text"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}
