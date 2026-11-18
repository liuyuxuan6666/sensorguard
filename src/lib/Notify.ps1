# SensorGuard - Feishu (Lark) custom-bot notification (PowerShell 5.1 compatible)
#
# Feishu signing differs from DingTalk:
#   HMAC-SHA256, key = "<unix-seconds>\n<secret>", message = empty, then base64.
#   The timestamp and sign travel in the JSON body (not the URL), seconds not millis.
#
# Keep the hard rate discipline: Feishu webhook bots are throttled (~100 msg/min) and
# answer 429 once exceeded. A single host should never get close, but a repeating alert
# with a short interval will.

$script:LastSendAt = $null
$script:MinSendGapSeconds = 2

function Get-FeishuSign {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][long]$Timestamp
    )
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes("$Timestamp`n$Secret")
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $hash = $hmac.ComputeHash([byte[]]@())
    $hmac.Dispose()
    return [Convert]::ToBase64String($hash)
}

function Wait-SendSlot {
    param([int]$MinGapSeconds = $script:MinSendGapSeconds)
    if ($null -ne $script:LastSendAt) {
        $elapsed = ((Get-Date) - $script:LastSendAt).TotalSeconds
        $wait = $MinGapSeconds - $elapsed
        if ($wait -gt 0) {
            Start-Sleep -Milliseconds ([int]($wait * 1000))
        }
    }
}

function Invoke-FeishuPost {
    param(
        [Parameter(Mandatory)][string]$Webhook,
        [string]$Secret,
        [Parameter(Mandatory)]$Card,
        [int]$TimeoutSeconds = 15,
        [switch]$DryRun
    )

    $payload = @{
        msg_type = 'interactive'
        card     = $Card
    }

    if (-not [string]::IsNullOrEmpty($Secret)) {
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $payload['timestamp'] = "$ts"
        $payload['sign'] = Get-FeishuSign -Secret $Secret -Timestamp $ts
    }

    $json = $payload | ConvertTo-Json -Depth 12 -Compress

    if ($DryRun) {
        Write-Host "[dry-run] payload: $json" -ForegroundColor DarkGray
        return [pscustomobject]@{ Ok = $true; DryRun = $true; Attempts = 0 }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $maxAttempts = 3
    $lastError = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Wait-SendSlot
        try {
            $resp = Invoke-RestMethod -Uri $Webhook -Method Post `
                -ContentType 'application/json; charset=utf-8' `
                -Body $bytes -TimeoutSec $TimeoutSeconds
            $script:LastSendAt = Get-Date

            if ($null -ne $resp.code -and [int]$resp.code -ne 0) {
                throw "feishu returned code=$($resp.code) msg=$($resp.msg)"
            }
            return [pscustomobject]@{ Ok = $true; Attempts = $attempt; Raw = $resp }
        }
        catch {
            $script:LastSendAt = Get-Date
            $lastError = $_.Exception.Message
            $status = $null
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            }
            # 429 means we already spent the budget: back off hard and stop retrying fast.
            if ($status -eq 429) {
                $sleepSec = 10 * $attempt
                Write-Host "[warn] feishu rate limited (429), sleeping ${sleepSec}s" -ForegroundColor Yellow
            }
            else {
                $sleepSec = [math]::Pow(2, $attempt - 1)
            }
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $sleepSec }
        }
    }

    return [pscustomobject]@{ Ok = $false; Attempts = $maxAttempts; Error = $lastError }
}

function Format-MetricValue {
    # Keep this ASCII-only: Windows PowerShell 5.1 reads .ps1 files as ANSI when they
    # have no BOM, so any non-ASCII literal here would arrive corrupted.
    param([double]$Value, [string]$Unit)
    if ([string]::IsNullOrEmpty($Unit)) { return ('{0:N1}' -f $Value) }
    if ($Unit -eq 'C') { return ('{0:N1} C' -f $Value) }
    if ($Unit -eq '%') { return ('{0:N1} %' -f $Value) }
    return ('{0:N1} {1}' -f $Value, $Unit)
}

function New-AlertCard {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][ValidateSet('firing', 'recovery')][string]$Kind,
        $Messages,
        [string]$HostName = $env:COMPUTERNAME,
        [AllowEmptyCollection()][string[]]$TopProcesses = @(),
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Messages) { $Messages = @{} }
    $titleFiring = if ($Messages.titleFiring) { $Messages.titleFiring } else { 'Hardware alert' }
    $titleRecovery = if ($Messages.titleRecovery) { $Messages.titleRecovery } else { 'Hardware recovered' }
    $labelDuration = if ($Messages.labelDuration) { $Messages.labelDuration } else { 'held' }
    $labelThreshold = if ($Messages.labelThreshold) { $Messages.labelThreshold } else { 'threshold' }
    $labelProcess = if ($Messages.labelProcess) { $Messages.labelProcess } else { 'top process' }
    $labelNew = if ($Messages.labelNew) { $Messages.labelNew } else { 'new' }
    $labelRepeat = if ($Messages.labelRepeat) { $Messages.labelRepeat } else { 'still firing' }

    $severity = 'warning'
    foreach ($it in $Items) {
        if ($it.Severity -eq 'critical') { $severity = 'critical' }
    }

    $template = 'orange'
    $title = $titleFiring
    if ($Kind -eq 'recovery') {
        $template = 'green'
        $title = $titleRecovery
    }
    elseif ($severity -eq 'critical') {
        $template = 'red'
    }

    $elements = New-Object System.Collections.ArrayList

    foreach ($it in $Items) {
        $val = Format-MetricValue -Value $it.Value -Unit $it.Unit
        $fields = @(
            @{ is_short = $true; text = @{ tag = 'lark_md'; content = "**$($it.Hardware)**`n$($it.Sensor)" } },
            @{ is_short = $true; text = @{ tag = 'lark_md'; content = "**$val**" } }
        )
        if ($Kind -eq 'firing') {
            $thr = Format-MetricValue -Value $it.Threshold -Unit $it.Unit
            $state = if ($it.IsNew) { $labelNew } else { $labelRepeat }
            $detail = "$labelThreshold $($it.Op) $thr | $labelDuration $([int]$it.HeldSeconds)s | $state"
        }
        else {
            $reason = if ($it.Reason -eq 'sensor-unavailable') { 'sensor unavailable' } else { 'back to normal' }
            $detail = "$val | $reason"
            if ($null -ne $it.Threshold) {
                $thr = Format-MetricValue -Value $it.Threshold -Unit $it.Unit
                $detail = "$val | $labelThreshold $($it.Op) $thr | $reason"
            }
        }

        [void]$elements.Add(@{
                tag    = 'div'
                fields = $fields
            })
        [void]$elements.Add(@{
                tag  = 'div'
                text = @{ tag = 'lark_md'; content = $detail }
            })
        [void]$elements.Add(@{ tag = 'hr' })
    }

    if ($Kind -eq 'firing' -and $TopProcesses.Count -gt 0) {
        $procLines = ($TopProcesses -join "`n")
        [void]$elements.Add(@{
                tag  = 'div'
                text = @{ tag = 'lark_md'; content = "**$labelProcess**`n$procLines" }
            })
        [void]$elements.Add(@{ tag = 'hr' })
    }

    [void]$elements.Add(@{
            tag      = 'note'
            elements = @(
                @{ tag = 'plain_text'; content = "SensorGuard | $HostName | $($Now.ToString('yyyy-MM-dd HH:mm:ss'))" }
            )
        })

    return @{
        config   = @{ wide_screen_mode = $true }
        header   = @{
            template = $template
            title    = @{ tag = 'plain_text'; content = $title }
        }
        elements = $elements.ToArray()
    }
}

function Send-AlertCard {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][ValidateSet('firing', 'recovery')][string]$Kind,
        [AllowEmptyCollection()][string[]]$TopProcesses = @(),
        [switch]$DryRun
    )
    $feishu = $Config.feishu
    $card = New-AlertCard -Items $Items -Kind $Kind -Messages $Config.messages `
        -HostName $env:COMPUTERNAME -TopProcesses $TopProcesses

    $noWebhook = [string]::IsNullOrEmpty($feishu.webhook) -or $feishu.webhook -like '*REPLACE_ME*'
    $useDryRun = $DryRun -or $noWebhook -or ($feishu.enabled -eq $false)

    if ($noWebhook -and -not $DryRun) {
        Write-Host '[warn] feishu.webhook is not configured; printing instead of sending' -ForegroundColor Yellow
    }

    return Invoke-FeishuPost -Webhook $feishu.webhook -Secret $feishu.secret `
        -Card $card -DryRun:$useDryRun
}
