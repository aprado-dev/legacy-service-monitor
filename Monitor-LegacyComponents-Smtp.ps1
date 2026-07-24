#Requires -Version 3.0

[CmdletBinding()]
param(
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot "monitored-components.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "Monitor-Core.psm1") -Force

function Send-SmtpMonitorEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        [string[]]$To,

        [string[]]$Cc = @(),

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$BodyHtml
    )

    $smtpConfiguration = $Configuration.Notification.Smtp
    $message = [System.Net.Mail.MailMessage]::new()
    $smtpClient = $null

    try {
        $message.From = [System.Net.Mail.MailAddress]::new($Configuration.Notification.From)

        foreach ($recipient in @($To)) {
            if (-not [string]::IsNullOrWhiteSpace($recipient)) {
                [void]$message.To.Add($recipient)
            }
        }

        foreach ($recipient in @($Cc)) {
            if (-not [string]::IsNullOrWhiteSpace($recipient)) {
                [void]$message.CC.Add($recipient)
            }
        }

        $message.Subject = $Subject
        $message.Body = $BodyHtml
        $message.IsBodyHtml = $true
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.BodyEncoding = [System.Text.Encoding]::UTF8

        $smtpClient = [System.Net.Mail.SmtpClient]::new(
            [string]$smtpConfiguration.Server,
            [int]$smtpConfiguration.Port
        )

        $smtpClient.EnableSsl = [bool]$smtpConfiguration.UseSsl
        $smtpClient.UseDefaultCredentials = [bool]$smtpConfiguration.UseDefaultCredentials

        if (-not $smtpClient.UseDefaultCredentials) {
            $credentialFile = [string]$smtpConfiguration.CredentialFile

            if (-not (Test-Path -LiteralPath $credentialFile -PathType Leaf)) {
                throw "SMTP credential file not found: $credentialFile"
            }

            $credential = Import-Clixml -LiteralPath $credentialFile
            $smtpClient.Credentials = $credential.GetNetworkCredential()
        }

        $smtpClient.Send($message)
    }
    finally {
        if ($null -ne $smtpClient) {
            $smtpClient.Dispose()
        }

        $message.Dispose()
    }
}

try {
    $configuration = Get-MonitorConfiguration -ConfigurationPath $ConfigurationPath
    $logDirectory = [string]$configuration.General.LogDirectory

    Write-MonitorLog -Message "SMTP monitoring cycle started." -LogDirectory $logDirectory

    Remove-OldMonitorLogs -LogDirectory $logDirectory -RetentionDays ([int]$configuration.General.LogRetentionDays)

    $results = @(Get-MonitoringCycle -Configuration $configuration)
    $currentState = Get-MonitorState -StateFile $configuration.General.StateFile

    $update = Update-MonitorState `
        -Results $results `
        -CurrentState $currentState `
        -FailureToleranceMinutes ([int]$configuration.General.FailureToleranceMinutes) `
        -SendRecoveryNotification ([bool]$configuration.General.SendRecoveryNotification)

    if (@($update.Notifications).Count -gt 0) {
        $groups = Group-NotificationsByVendor `
            -Configuration $configuration `
            -Notifications @($update.Notifications) `
            -LogDirectory $logDirectory

        foreach ($group in $groups) {
            $message = New-NotificationMessage `
                -Configuration $configuration `
                -Notifications @($group.Notifications) `
                -Vendor $group.Vendor

            Send-SmtpMonitorEmail `
                -Configuration $configuration `
                -To $group.To `
                -Cc $group.Cc `
                -Subject $message.Subject `
                -BodyHtml $message.BodyHtml

            Write-MonitorLog `
                -Message ("SMTP notification sent to vendor '{0}'. Event count: {1}" -f $group.Vendor, @($group.Notifications).Count) `
                -LogDirectory $logDirectory
        }
    }
    else {
        Write-MonitorLog -Message "No notification was required." -LogDirectory $logDirectory
    }

    # Save state only after notification delivery succeeds. If delivery fails,
    # the next execution will retry the alert.
    Save-MonitorState -State $update.State -StateFile $configuration.General.StateFile

    Write-MonitorLog -Message "SMTP monitoring cycle completed successfully." -LogDirectory $logDirectory
    exit 0
}
catch {
    $fallbackLogDirectory = "C:\ProgramData\LegacyServiceMonitor\Logs"

    try {
        Write-MonitorLog `
            -Message ("SMTP monitoring cycle failed: {0}" -f $_.Exception.Message) `
            -Level "ERROR" `
            -LogDirectory $fallbackLogDirectory
    }
    catch {
        # The Windows Task Scheduler history should still record the non-zero exit code.
    }

    Write-Error $_
    exit 1
}
