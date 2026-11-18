# SensorGuard - LibreHardwareMonitor sensor collection (PowerShell 5.1 compatible)
#
# Wraps LibreHardwareMonitorLib (net472 build). The library must be loaded once per
# process; Add-Type caches the assembly so repeated calls are cheap.
#
# NOTE: reading CPU package temperature, board SuperIO sensors and NVMe SMART data
# requires an elevated process (the library loads a kernel driver for MSR / IO port
# access). GPU temperature and load are readable without elevation on most drivers.

function Initialize-Lhm {
    param(
        [Parameter(Mandatory)][string]$DllPath
    )
    if (-not (Test-Path -LiteralPath $DllPath)) {
        throw "LibreHardwareMonitorLib.dll not found at: $DllPath (run scripts\setup.ps1)"
    }
    $already = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'LibreHardwareMonitorLib' }
    if (-not $already) {
        Add-Type -Path $DllPath
    }

    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.IsGpuEnabled = $true
    $computer.IsMemoryEnabled = $true
    $computer.IsStorageEnabled = $true
    $computer.IsMotherboardEnabled = $true
    $computer.IsControllerEnabled = $true
    $computer.IsPsuEnabled = $false
    $computer.IsNetworkEnabled = $false
    $computer.Open()
    return $computer
}

function Get-SensorUnit {
    param([string]$SensorType)
    switch ($SensorType) {
        'Temperature' { 'C' }
        'Load'        { '%' }
        'Fan'         { 'RPM' }
        'Power'       { 'W' }
        'Clock'       { 'MHz' }
        'Voltage'     { 'V' }
        'Data'        { 'GB' }
        'Throughput'  { 'B/s' }
        'Level'       { '%' }
        'Factor'      { '' }
        default       { '' }
    }
}

function Get-HardwareInventory {
    <#
        Walks the LHM hardware tree and returns every readable sensor as a flat list.
        Sub-hardware (board SuperIO, per-drive nodes) is included and reported under the
        top-level hardware name so rules can match a stable label.
    #>
    param(
        [Parameter(Mandatory)]$Computer
    )
    $list = New-Object System.Collections.ArrayList

    function Walk {
        param($Hw, [string]$Owner, [string]$SubName)
        try { $Hw.Update() } catch { }

        $ownerName = $Owner
        if ([string]::IsNullOrEmpty($ownerName)) { $ownerName = $Hw.Name }

        foreach ($s in $Hw.Sensors) {
            $v = $s.Value
            if ($null -eq $v) { continue }
            $stype = $s.SensorType.ToString()
            [void]$list.Add([pscustomobject]@{
                Hardware     = $ownerName
                HardwareType = $Hw.HardwareType.ToString()
                SubName      = $SubName
                Sensor       = $s.Name
                SensorType   = $stype
                Value        = [double]$v
                Unit         = Get-SensorUnit $stype
            })
        }

        foreach ($sub in $Hw.SubHardware) {
            Walk -Hw $sub -Owner $ownerName -SubName $sub.Name
        }
    }

    foreach ($h in $Computer.Hardware) {
        Walk -Hw $h -Owner $h.Name -SubName $null
    }
    return $list.ToArray()
}

function Get-SensorMap {
    <#
        Indexes a sensor list by "HardwareType|Hardware|Sensor" for O(1) rule lookups.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Sensors
    )
    $map = @{}
    foreach ($s in $Sensors) {
        $key = "$($s.HardwareType)|$($s.Hardware)|$($s.Sensor)"
        $map[$key] = $s.Value
    }
    return $map
}

function Test-Elevation {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SensorHealth {
    <#
        Startup self-check. Returns a report of which sensitive sensor families are
        readable, so the service can warn instead of silently reporting nothing.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Sensors
    )
    $temps = @($Sensors | Where-Object { $_.SensorType -eq 'Temperature' })
    $cpuTemps = @($temps | Where-Object { $_.HardwareType -eq 'Cpu' })
    $gpuTemps = @($temps | Where-Object { $_.HardwareType -like 'Gpu*' })
    $storageTemps = @($temps | Where-Object { $_.HardwareType -eq 'Storage' })

    $missing = New-Object System.Collections.ArrayList
    if ($cpuTemps.Count -eq 0) { [void]$missing.Add('cpu-temperature') }
    if ($gpuTemps.Count -eq 0) { [void]$missing.Add('gpu-temperature') }
    if ($storageTemps.Count -eq 0) { [void]$missing.Add('storage-temperature') }

    [pscustomobject]@{
        Elevated         = Test-Elevation
        CpuTempSensors   = $cpuTemps.Count
        GpuTempSensors   = $gpuTemps.Count
        StorageTempSensors = $storageTemps.Count
        Missing          = $missing.ToArray()
    }
}
