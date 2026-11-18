# SensorGuard - process attribution for alerts (PowerShell 5.1 compatible)
#
# When CPU or GPU is pinned for a long time the operator wants to know WHO did it
# before remote-desktoping in. Attribution is computed from two consecutive samples
# of Get-Process CPU time so the number is a real percentage, not lifetime seconds.

$script:ProcPrev = @{}
$script:ProcPrevAt = $null

function Get-TopProcesses {
    param(
        [int]$Count = 3,
        [string]$Metric = 'cpu'
    )
    $cores = [Environment]::ProcessorCount
    $now = Get-Date

    if ($null -eq $script:ProcPrevAt) {
        # First call has no delta to compute: seed the baseline and fall back to
        # lifetime CPU time so a very first alert still carries some attribution.
        $seed = New-Object System.Collections.ArrayList
        $script:ProcPrev = @{}
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($null -ne $p.CPU) {
                $script:ProcPrev[$p.Id] = [pscustomobject]@{ Cpu = [double]$p.CPU; Name = $p.ProcessName }
                [void]$seed.Add([pscustomobject]@{
                        Name         = $p.ProcessName
                        Id           = $p.Id
                        CpuSeconds   = [double]$p.CPU
                        WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
                    })
            }
        }
        $script:ProcPrevAt = $now
        if ($seed.Count -eq 0) { return @() }

        if ($Metric -eq 'memory') {
            $top = $seed | Sort-Object -Property WorkingSetMB -Descending | Select-Object -First $Count
            return @($top | ForEach-Object {
                    '{0} (pid {1}) {2} MB' -f $_.Name, $_.Id, $_.WorkingSetMB
                })
        }
        $top = $seed | Sort-Object -Property CpuSeconds -Descending | Select-Object -First $Count
        return @($top | ForEach-Object {
                '{0} (pid {1}) {2}s cpu-time (lifetime)' -f $_.Name, $_.Id, [math]::Round($_.CpuSeconds, 0)
            })
    }

    $elapsed = ($now - $script:ProcPrevAt).TotalSeconds
    if ($elapsed -le 0) { $elapsed = 1 }

    $rows = New-Object System.Collections.ArrayList
    $present = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $present[$p.Id] = $true
        $cpu = $null
        try { $cpu = $p.CPU } catch { }
        if ($null -eq $cpu) { continue }

        $prev = $script:ProcPrev[$p.Id]
        if ($null -ne $prev) {
            $delta = [double]$cpu - $prev.Cpu
            if ($delta -ge 0) {
                $pct = ($delta / $elapsed / $cores) * 100
                if ($pct -gt 0.5) {
                    [void]$rows.Add([pscustomobject]@{
                            Name     = $p.ProcessName
                            Id       = $p.Id
                            Percent  = [math]::Round($pct, 1)
                            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
                            CpuSeconds   = [math]::Round([double]$cpu, 0)
                        })
                }
            }
        }
        $script:ProcPrev[$p.Id] = [pscustomobject]@{ Cpu = [double]$cpu; Name = $p.ProcessName }
    }

    # drop PID entries that no longer exist
    foreach ($k in @($script:ProcPrev.Keys)) {
        if (-not $present.ContainsKey($k)) { $script:ProcPrev.Remove($k) }
    }
    $script:ProcPrevAt = $now

    if ($rows.Count -eq 0) { return @() }

    if ($Metric -eq 'memory') {
        $sorted = $rows | Sort-Object -Property WorkingSetMB -Descending | Select-Object -First $Count
        return @($sorted | ForEach-Object {
                '{0} (pid {1}) {2} MB, cpu-time {3}s' -f $_.Name, $_.Id, $_.WorkingSetMB, $_.CpuSeconds
            })
    }

    $sorted = $rows | Sort-Object -Property Percent -Descending | Select-Object -First $Count
    return @($sorted | ForEach-Object {
            '{0} (pid {1}) {2}% cpu' -f $_.Name, $_.Id, $_.Percent
        })
}

function Reset-ProcessBaseline {
    $script:ProcPrev = @{}
    $script:ProcPrevAt = $null
}
