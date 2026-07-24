Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-MonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",

        [Parameter(Mandatory)]
        [string]$LogDirectory
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $logFile = Join-Path $LogDirectory ("monitor-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    $line = "{0} [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:COMPUTERNAME, $Level, $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Remove-OldMonitorLogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [Parameter(Mandatory)]
        [int]$RetentionDays
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        return
    }

    if ($RetentionDays -lt 1) {
        $RetentionDays = 1
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)

    Get-ChildItem -LiteralPath $LogDirectory -Filter "monitor-*.log" -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force
}

function Get-MonitorConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationPath
    )

    if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigurationPath"
    }

    return Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-InitialState {
    return [ordered]@{
        Version = 2
        Components = [ordered]@{}
    }
}

function Get-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StateFile
    )

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return Get-InitialState
    }

    try {
        return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $backupFile = "{0}.{1}.invalid" -f $StateFile, (Get-Date -Format "yyyyMMddHHmmss")
        Copy-Item -LiteralPath $StateFile -Destination $backupFile -Force
        return Get-InitialState
    }
}

function Save-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$StateFile
    )

    $stateDirectory = Split-Path -Parent $StateFile
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
    }

    $temporaryFile = "$StateFile.tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    Move-Item -LiteralPath $temporaryFile -Destination $StateFile -Force
}

function Get-ComponentKey {
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return "{0}::{1}" -f $Type, $Name
}

function New-ComponentResult {
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$IsHealthy,

        [Parameter(Mandatory)]
        [string]$CurrentStatus,

        [string]$Details = "",
        [string]$ApplicationName = "",
        [string]$BeatId = "",
        [string]$Squad = "",
        [string]$Vendor = ""
    )

    [pscustomobject]@{
        Type = $Type
        Name = $Name
        IsHealthy = $IsHealthy
        CurrentStatus = $CurrentStatus
        Details = $Details
        ApplicationName = $ApplicationName
        BeatId = $BeatId
        Squad = $Squad
        Vendor = $Vendor
        CheckedAt = (Get-Date).ToString("o")
    }
}

function Test-WebApplications {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $WebApplications
    )

    Import-Module WebAdministration -ErrorAction Stop

    foreach ($webApplication in @($WebApplications | Where-Object { $_.Enabled -eq $true })) {
        try {
            $site = Get-Item -LiteralPath ("IIS:\Sites\{0}" -f $webApplication.SiteName) -ErrorAction Stop
            $siteStatus = [string]$site.State
            New-ComponentResult -Type "WebSite" -Name $webApplication.SiteName `
                -IsHealthy ($siteStatus -eq "Started") -CurrentStatus $siteStatus `
                -ApplicationName $webApplication.ApplicationName -BeatId $webApplication.BeatId `
                -Squad $webApplication.Squad -Vendor $webApplication.Vendor
        }
        catch {
            New-ComponentResult -Type "WebSite" -Name $webApplication.SiteName `
                -IsHealthy $false -CurrentStatus "NotFoundOrUnavailable" -Details $_.Exception.Message `
                -ApplicationName $webApplication.ApplicationName -BeatId $webApplication.BeatId `
                -Squad $webApplication.Squad -Vendor $webApplication.Vendor
        }

        try {
            $pool = Get-Item -LiteralPath ("IIS:\AppPools\{0}" -f $webApplication.PoolName) -ErrorAction Stop
            $poolStatus = [string]$pool.State
            New-ComponentResult -Type "ApplicationPool" -Name $webApplication.PoolName `
                -IsHealthy ($poolStatus -eq "Started") -CurrentStatus $poolStatus `
                -ApplicationName $webApplication.ApplicationName -BeatId $webApplication.BeatId `
                -Squad $webApplication.Squad -Vendor $webApplication.Vendor
        }
        catch {
            New-ComponentResult -Type "ApplicationPool" -Name $webApplication.PoolName `
                -IsHealthy $false -CurrentStatus "NotFoundOrUnavailable" -Details $_.Exception.Message `
                -ApplicationName $webApplication.ApplicationName -BeatId $webApplication.BeatId `
                -Squad $webApplication.Squad -Vendor $webApplication.Vendor
        }
    }
}

function Test-WindowsServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $WindowsServices
    )

    foreach ($configuredService in @($WindowsServices | Where-Object { $_.Enabled -eq $true })) {
        try {
            $service = Get-Service -Name $configuredService.ServiceName -ErrorAction Stop
            $status = [string]$service.Status

            New-ComponentResult -Type "WindowsService" -Name $configuredService.ServiceName `
                -IsHealthy ($status -eq "Running") -CurrentStatus $status -Details $service.DisplayName `
                -ApplicationName $configuredService.ApplicationName -BeatId $configuredService.BeatId `
                -Squad $configuredService.Squad -Vendor $configuredService.Vendor
        }
        catch {
            New-ComponentResult -Type "WindowsService" -Name $configuredService.ServiceName `
                -IsHealthy $false -CurrentStatus "NotFoundOrUnavailable" -Details $_.Exception.Message `
                -ApplicationName $configuredService.ApplicationName -BeatId $configuredService.BeatId `
                -Squad $configuredService.Squad -Vendor $configuredService.Vendor
        }
    }
}

function ConvertTo-StateDictionary {
    param($State)

    $dictionary = [ordered]@{}

    if ($null -ne $State.Components) {
        foreach ($property in $State.Components.PSObject.Properties) {
            $dictionary[$property.Name] = $property.Value
        }
    }

    return $dictionary
}

function Update-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        $CurrentState,

        [Parameter(Mandatory)]
        [int]$FailureToleranceMinutes,

        [Parameter(Mandatory)]
        [bool]$SendRecoveryNotification
    )

    if ($FailureToleranceMinutes -lt 0) {
        $FailureToleranceMinutes = 0
    }

    $components = ConvertTo-StateDictionary -State $CurrentState
    $notifications = @()
    $now = Get-Date

    foreach ($result in $Results) {
        $key = Get-ComponentKey -Type $result.Type -Name $result.Name

        if (-not $components.Contains($key)) {
            $components[$key] = [pscustomobject]@{
                Type = $result.Type
                Name = $result.Name
                IsInFailure = $false
                FirstFailureAt = $null
                LastStatus = "Unknown"
                LastChange = $null
                LastAlert = $null
            }
        }

        $entry = $components[$key]

        if ($result.IsHealthy) {
            if ($entry.IsInFailure -eq $true) {
                if ($SendRecoveryNotification) {
                    $notifications += [pscustomobject]@{
                        EventType = "Recovery"
                        Component = $result
                        PreviousStatus = $entry.LastStatus
                    }
                }

                $entry.LastChange = $now.ToString("o")
            }

            $entry.IsInFailure = $false
            $entry.FirstFailureAt = $null
        }
        else {
            if ([string]::IsNullOrEmpty($entry.FirstFailureAt)) {
                $entry.FirstFailureAt = $now.ToString("o")
            }

            $elapsedMinutes = ($now - [datetime]$entry.FirstFailureAt).TotalMinutes

            if (($entry.IsInFailure -ne $true) -and ($elapsedMinutes -ge $FailureToleranceMinutes)) {
                $entry.IsInFailure = $true
                $entry.LastChange = $now.ToString("o")
                $entry.LastAlert = $now.ToString("o")

                $notifications += [pscustomobject]@{
                    EventType = "Failure"
                    Component = $result
                    PreviousStatus = $entry.LastStatus
                }
            }
        }

        $entry.LastStatus = $result.CurrentStatus
        $components[$key] = $entry
    }

    $newState = [ordered]@{
        Version = 2
        LastExecution = $now.ToString("o")
        Components = $components
    }

    [pscustomobject]@{
        State = $newState
        Notifications = $notifications
    }
}

function Get-MonitoringCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration
    )

    $results = @()

    if ($Configuration.WebApplications) {
        $results += @(Test-WebApplications -WebApplications $Configuration.WebApplications)
    }

    if ($Configuration.WindowsServices) {
        $results += @(Test-WindowsServices -WindowsServices $Configuration.WindowsServices)
    }

    return $results
}

function New-NotificationMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        [object[]]$Notifications
    )

    $failureCount = @($Notifications | Where-Object { $_.EventType -eq "Failure" }).Count
    $recoveryCount = @($Notifications | Where-Object { $_.EventType -eq "Recovery" }).Count

    $statusLabel = if ($failureCount -gt 0) { "ALERT" } else { "RECOVERY" }
    $subject = "{0} [{1}] {2} - {3}" -f `
        $Configuration.Notification.SubjectPrefix,
        $Configuration.General.Environment,
        $Configuration.General.ApplicationName,
        $statusLabel

    $rows = foreach ($notification in $Notifications) {
        $component = $notification.Component
        $eventColor = if ($notification.EventType -eq "Failure") { "#b42318" } else { "#067647" }
        $category = if ($component.Type -eq "WindowsService") { "Windows" } else { "Web" }

        @"
<tr>
  <td style="padding:8px;border:1px solid #ddd;">$($notification.EventType)</td>
  <td style="padding:8px;border:1px solid #ddd;">$category</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.Type)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.Name)</td>
  <td style="padding:8px;border:1px solid #ddd;color:$eventColor;font-weight:bold;">$($component.CurrentStatus)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.ApplicationName)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.BeatId)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.Squad)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.Vendor)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.Details)</td>
  <td style="padding:8px;border:1px solid #ddd;">$($component.CheckedAt)</td>
</tr>
"@
    }

    $body = @"
<html>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;">
  <h2>$($Configuration.General.ApplicationName)</h2>
  <p><strong>Environment:</strong> $($Configuration.General.Environment)</p>
  <p><strong>Server:</strong> $env:COMPUTERNAME</p>
  <p><strong>Execution time:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
  <p><strong>Failures:</strong> $failureCount &nbsp; <strong>Recoveries:</strong> $recoveryCount</p>
  <table style="border-collapse:collapse;width:100%;">
    <thead>
      <tr>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Event</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Category</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Type</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Name</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Status</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Application</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">BEAT ID</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Squad</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Vendor</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Details</th>
        <th style="padding:8px;border:1px solid #ddd;text-align:left;">Checked at</th>
      </tr>
    </thead>
    <tbody>
      $($rows -join [Environment]::NewLine)
    </tbody>
  </table>
  <p>This is an automated monitoring notification. Do not reply.</p>
</body>
</html>
"@

    [pscustomobject]@{
        Subject = $subject
        BodyHtml = $body
    }
}

Export-ModuleMember -Function `
    Write-MonitorLog, `
    Remove-OldMonitorLogs, `
    Get-MonitorConfiguration, `
    Get-MonitorState, `
    Save-MonitorState, `
    Get-MonitoringCycle, `
    Update-MonitorState, `
    New-NotificationMessage
