# SensorGuard - rule evaluation state machine (PowerShell 5.1 compatible)
#
# One rule can match several physical sensors (e.g. "GPU Core" on both GPUs), so every
# matched (rule, hardware, sensor) triple owns an independent state entry.
#
# Lifecycle: OK -> PENDING (condition true, waiting out forSeconds) -> FIRING -> OK
# A FIRING entry re-notifies at most once per repeatSeconds; it never auto-remediates.

function Test-NameMatch {
    param([string]$Name, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Pattern) -or $Pattern -eq '*') { return $true }
    return ($Name -like $Pattern)
}

function Get-RuleInstances {
    <#
        Resolves a rule against a sensor snapshot.
        Returns @{ Instances = @(...); Missing = @(...) }
        An instance carries the resolved numeric Value and the unit it is expressed in.
    #>
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sensors
    )
    $instances = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList

    $hwPattern = if ($Rule.hardwareType) { $Rule.hardwareType } else { '*' }
    $typePattern = if ($Rule.sensorType) { $Rule.sensorType } else { '*' }
    $sensorPattern = if ($Rule.sensor) { $Rule.sensor } else { '*' }
    $hwNamePattern = if ($Rule.hardware) { $Rule.hardware } else { '*' }

    $candidates = $Sensors | Where-Object {
        (Test-NameMatch $_.HardwareType $hwPattern) -and
        (Test-NameMatch $_.SensorType $typePattern) -and
        (Test-NameMatch $_.Hardware $hwNamePattern)
    }

    # Wildcard sensor selectors must not pick up the constant threshold sensors LHM
    # exposes next to real readings ("Warning Temperature", "Critical Temperature",
    # "Distance to TjMax"). An explicit sensor name still matches them if asked for.
    if ($sensorPattern -eq '*') {
        $candidates = $candidates | Where-Object {
            $_.Sensor -notmatch '(?i)(warning|critical|limit|distance)'
        }
    }

    if ($Rule.derive) {
        # Derived metric: difference between two sensors of the same hardware
        # (e.g. GPU Hot Spot minus GPU Core, the early thermal-contact signal).
        $leftName = $Rule.derive.left
        $rightName = $Rule.derive.right
        $grouped = $candidates | Group-Object -Property Hardware
        foreach ($g in $grouped) {
            $left = $g.Group | Where-Object { $_.Sensor -eq $leftName } | Select-Object -First 1
            $right = $g.Group | Where-Object { $_.Sensor -eq $rightName } | Select-Object -First 1
            if ($null -eq $left -or $null -eq $right) { continue }
            [void]$instances.Add([pscustomobject]@{
                RuleId       = $Rule.id
                Hardware     = $g.Name
                HardwareType = $left.HardwareType
                Sensor       = "$leftName - $rightName"
                SensorType   = $left.SensorType
                Value        = [double]$left.Value - [double]$right.Value
                Unit         = $left.Unit
            })
        }
    }
    else {
        $matched = $candidates | Where-Object { Test-NameMatch $_.Sensor $sensorPattern }
        foreach ($s in $matched) {
            [void]$instances.Add([pscustomobject]@{
                RuleId       = $Rule.id
                Hardware     = $s.Hardware
                HardwareType = $s.HardwareType
                Sensor       = $s.Sensor
                SensorType   = $s.SensorType
                Value        = [double]$s.Value
                Unit         = $s.Unit
            })
        }
    }

    if ($instances.Count -eq 0) {
        [void]$missing.Add([pscustomobject]@{
            RuleId   = $Rule.id
            Expected = "$hwPattern/$typePattern/$sensorPattern"
        })
    }

    [pscustomobject]@{
        Instances = $instances.ToArray()
        Missing   = $missing.ToArray()
    }
}

function Test-Threshold {
    param([double]$Value, [string]$Op, [double]$Threshold)
    switch ($Op) {
        '>'  { return $Value -gt $Threshold }
        '>=' { return $Value -ge $Threshold }
        '<'  { return $Value -lt $Threshold }
        '<=' { return $Value -le $Threshold }
        default { throw "Unsupported operator: $Op" }
    }
}

function Invoke-RuleEvaluation {
    <#
        Runs one evaluation pass.
        Input : rules, current sensor snapshot, mutable state table, repeat interval.
        Output: firings (new + repeats), recoveries, and which states are still active.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sensors,
        [Parameter(Mandatory)][hashtable]$States,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$DefaultRepeatSeconds = 180
    )
    $firings = New-Object System.Collections.ArrayList
    $recoveries = New-Object System.Collections.ArrayList
    $seen = @{}
    $missing = New-Object System.Collections.ArrayList

    foreach ($rule in $Rules) {
        if ($rule.enabled -eq $false) { continue }
        $resolved = Get-RuleInstances -Rule $rule -Sensors $Sensors
        foreach ($m in $resolved.Missing) { [void]$missing.Add($m) }

        foreach ($inst in $resolved.Instances) {
            $key = "$($rule.id)|$($inst.Hardware)|$($inst.Sensor)"
            $seen[$key] = $true

            if (-not $States.ContainsKey($key)) {
                $States[$key] = [pscustomobject]@{
                    RuleId       = $rule.id
                    Severity     = $rule.severity
                    Hardware     = $inst.Hardware
                    Sensor       = $inst.Sensor
                    Unit         = $inst.Unit
                    Value        = $null
                    Status       = 'OK'
                    PendingSince = $null
                    LastNotify   = $null
                }
            }
            $st = $States[$key]
            $st.Value = $inst.Value
            $st.Unit = $inst.Unit

            $cond = Test-Threshold -Value $inst.Value -Op $rule.op -Threshold ([double]$rule.threshold)
            $forSec = if ($null -ne $rule.forSeconds) { [int]$rule.forSeconds } else { 0 }
            $repeatSec = if ($null -ne $rule.repeatSeconds) { [int]$rule.repeatSeconds } else { $DefaultRepeatSeconds }
            if ($repeatSec -lt 180) { $repeatSec = 180 }   # hard floor: protect against Feishu 429

            if ($cond) {
                if ($null -eq $st.PendingSince) { $st.PendingSince = $Now }
                $heldFor = ($Now - $st.PendingSince).TotalSeconds

                if ($st.Status -ne 'FIRING') {
                    if ($heldFor -ge $forSec) {
                        $st.Status = 'FIRING'
                        $st.LastNotify = $Now
                        [void]$firings.Add([pscustomobject]@{
                            Kind         = 'firing'
                            IsNew        = $true
                            RuleId       = $rule.id
                            Severity     = $rule.severity
                            Hardware     = $inst.Hardware
                            HardwareType = $inst.HardwareType
                            Sensor       = $inst.Sensor
                            SensorType   = $inst.SensorType
                            Value        = $inst.Value
                            Unit         = $inst.Unit
                            Op           = $rule.op
                            Threshold    = [double]$rule.threshold
                            HeldSeconds  = [math]::Round($heldFor, 0)
                            At           = $Now
                        })
                    }
                    else {
                        $st.Status = 'PENDING'
                    }
                }
                elseif (($Now - $st.LastNotify).TotalSeconds -ge $repeatSec) {
                    $st.LastNotify = $Now
                    [void]$firings.Add([pscustomobject]@{
                        Kind         = 'firing'
                        IsNew        = $false
                        RuleId       = $rule.id
                        Severity     = $rule.severity
                        Hardware     = $inst.Hardware
                        HardwareType = $inst.HardwareType
                        Sensor       = $inst.Sensor
                        SensorType   = $inst.SensorType
                        Value        = $inst.Value
                        Unit         = $inst.Unit
                        Op           = $rule.op
                        Threshold    = [double]$rule.threshold
                        HeldSeconds  = [math]::Round(($Now - $st.PendingSince).TotalSeconds, 0)
                        At           = $Now
                    })
                }
            }
            else {
                if ($st.Status -eq 'FIRING') {
                    [void]$recoveries.Add([pscustomobject]@{
                        Kind        = 'recovery'
                        RuleId      = $rule.id
                        Severity    = $rule.severity
                        Hardware    = $inst.Hardware
                        Sensor      = $inst.Sensor
                        Value       = $inst.Value
                        Unit        = $inst.Unit
                        Op          = $rule.op
                        Threshold   = [double]$rule.threshold
                        Reason      = 'normal'
                        At          = $Now
                    })
                }
                $st.Status = 'OK'
                $st.PendingSince = $null
            }
        }
    }

    # Sensors that vanished while alerting: emit a recovery so the group is not left
    # believing an alert is still open forever.
    foreach ($key in @($States.Keys)) {
        if ($seen.ContainsKey($key)) { continue }
        $st = $States[$key]
        if ($st.Status -eq 'FIRING') {
            [void]$recoveries.Add([pscustomobject]@{
                Kind        = 'recovery'
                RuleId      = $st.RuleId
                Severity    = $st.Severity
                Hardware    = $st.Hardware
                Sensor      = $st.Sensor
                Value       = $st.Value
                Unit        = $st.Unit
                Op          = $null
                Threshold   = $null
                Reason      = 'sensor-unavailable'
                At          = $Now
            })
        }
        $States.Remove($key)
    }

    [pscustomobject]@{
        Firings    = $firings.ToArray()
        Recoveries = $recoveries.ToArray()
        Missing    = $missing.ToArray()
        Active     = @($States.Values | Where-Object { $_.Status -eq 'FIRING' })
    }
}
