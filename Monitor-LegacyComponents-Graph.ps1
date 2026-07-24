#Requires -Version 3.0

[CmdletBinding()]
param(
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot "monitored-components.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "Monitor-Core.psm1") -Force

function ConvertTo-GraphRecipient {
    param([string[]]$Addresses)

    return @(
        foreach ($address in @($Addresses)) {
            if (-not [string]::IsNullOrWhiteSpace($address)) {
                @{
                    emailAddress = @{
                        address = $address
                    }
                }
            }
        }
    )
}

function Send-GraphMonitorEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$BodyHtml
    )

    $graphConfiguration = $Configuration.Notification.Graph

    $tenantVariable = [string]$graphConfiguration.TenantIdEnvironmentVariable
    $clientVariable = [string]$graphConfiguration.ClientIdEnvironmentVariable
    $secretVariable = [string]$graphConfiguration.ClientSecretEnvironmentVariable

    $tenantId = [Environment]::GetEnvironmentVariable($tenantVariable, "Machine")
    $clientId = [Environment]::GetEnvironmentVariable($clientVariable, "Machine")
    $clientSecret = [Environment]::GetEnvironmentVariable($secretVariable, "Machine")

    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        $tenantId = [Environment]::GetEnvironmentVariable($tenantVariable, "Process")
    }

    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $clientId = [Environment]::GetEnvironmentVariable($clientVariable, "Process")
    }

    if ([string]::IsNullOrWhiteSpace($clientSecret)) {
        $clientSecret = [Environment]::GetEnvironmentVariable($secretVariable, "Process")
    }

    if ([string]::IsNullOrWhiteSpace($tenantId) -or
        [string]::IsNullOrWhiteSpace($clientId) -or
        [string]::IsNullOrWhiteSpace($clientSecret)) {
        throw "One or more Microsoft Graph environment variables are missing."
    }

    $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenBody = @{
        client_id = $clientId
        client_secret = $clientSecret
        scope = "https://graph.microsoft.com/.default"
        grant_type = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri $tokenUri `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $tokenBody

    if ([string]::IsNullOrWhiteSpace($tokenResponse.access_token)) {
        throw "Microsoft Entra ID did not return an access token."
    }

    $payload = @{
        message = @{
            subject = $Subject
            body = @{
                contentType = "HTML"
                content = $BodyHtml
            }
            toRecipients = ConvertTo-GraphRecipient -Addresses @($Configuration.Notification.To)
            ccRecipients = ConvertTo-GraphRecipient -Addresses @($Configuration.Notification.Cc)
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 10

    $senderMailbox = [string]$graphConfiguration.SenderMailbox
    $encodedMailbox = [Uri]::EscapeDataString($senderMailbox)
    $sendMailUri = "https://graph.microsoft.com/v1.0/users/$encodedMailbox/sendMail"

    Invoke-RestMethod `
        -Method Post `
        -Uri $sendMailUri `
        -Headers @{ Authorization = "Bearer $($tokenResponse.access_token)" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
}

try {
    $configuration = Get-MonitorConfiguration -ConfigurationPath $ConfigurationPath
    $logDirectory = [string]$configuration.General.LogDirectory

    Write-MonitorLog -Message "Microsoft Graph monitoring cycle started." -LogDirectory $logDirectory

    Remove-OldMonitorLogs -LogDirectory $logDirectory -RetentionDays ([int]$configuration.General.LogRetentionDays)

    $results = @(Get-MonitoringCycle -Configuration $configuration)
    $currentState = Get-MonitorState -StateFile $configuration.General.StateFile

    $update = Update-MonitorState `
        -Results $results `
        -CurrentState $currentState `
        -FailureToleranceMinutes ([int]$configuration.General.FailureToleranceMinutes) `
        -SendRecoveryNotification ([bool]$configuration.General.SendRecoveryNotification)

    if (@($update.Notifications).Count -gt 0) {
        $message = New-NotificationMessage `
            -Configuration $configuration `
            -Notifications @($update.Notifications)

        Send-GraphMonitorEmail `
            -Configuration $configuration `
            -Subject $message.Subject `
            -BodyHtml $message.BodyHtml

        Write-MonitorLog `
            -Message ("Microsoft Graph notification sent. Event count: {0}" -f @($update.Notifications).Count) `
            -LogDirectory $logDirectory
    }
    else {
        Write-MonitorLog -Message "No notification was required." -LogDirectory $logDirectory
    }

    # Save state only after notification delivery succeeds. If delivery fails,
    # the next execution will retry the alert.
    Save-MonitorState -State $update.State -StateFile $configuration.General.StateFile

    Write-MonitorLog -Message "Microsoft Graph monitoring cycle completed successfully." -LogDirectory $logDirectory
    exit 0
}
catch {
    $fallbackLogDirectory = "C:\ProgramData\LegacyServiceMonitor\Logs"

    try {
        Write-MonitorLog `
            -Message ("Microsoft Graph monitoring cycle failed: {0}" -f $_.Exception.Message) `
            -Level "ERROR" `
            -LogDirectory $fallbackLogDirectory
    }
    catch {
        # The Windows Task Scheduler history should still record the non-zero exit code.
    }

    Write-Error $_
    exit 1
}
