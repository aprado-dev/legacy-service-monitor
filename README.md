# Legacy Service Monitor

This package monitors:

- IIS websites
- IIS application pools
- Windows services

It sends a notification only when a component enters a failure state. It does not repeatedly send the same alert while the component remains unavailable. When the component becomes healthy again, the monitor can send one recovery notification.

Two notification implementations are included:

1. SMTP using `System.Net.Mail.SmtpClient`
2. Microsoft Graph using Microsoft Entra ID application authentication

## Package contents

| File | Purpose |
|---|---|
| `Monitor-Core.psm1` | Shared monitoring, logging, state management, and message generation |
| `Monitor-LegacyComponents-Smtp.ps1` | Monitoring entry point using SMTP |
| `Monitor-LegacyComponents-Graph.ps1` | Monitoring entry point using Microsoft Graph |
| `monitored-components.json` | Websites, application pools, services, and notification configuration |
| `Create-SmtpCredential.ps1` | Creates an encrypted SMTP credential file |
| `Install-MonitoringTask.ps1` | Copies the files and registers the Windows scheduled task |

## Recommended Windows version

Use Windows PowerShell 5.1 on the IIS server. The scripts use the built-in `WebAdministration` module and the `IIS:\` provider.

Before installation, verify:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable WebAdministration
```

## Service account

Use a dedicated domain service account or a group Managed Service Account when the company supports it.

For the initial implementation, the most reliable setup is:

- The account has the **Log on as a batch job** user right.
- The account can read IIS configuration and query Windows services.
- The account has Modify permission on the monitor installation directory.
- The account can reach the SMTP server or Microsoft Graph endpoints.
- The task is configured with **Run with highest privileges**.

On many IIS servers, reliably reading all websites and application pools through `WebAdministration` requires local administrative privileges. The recommended rollout is:

1. Start with a dedicated service account temporarily added to the local Administrators group.
2. Validate all required queries.
3. Ask the Windows/IIS administration team to reduce the account to delegated read permissions if the corporate security model supports this.
4. Do not grant permissions to restart websites, pools, or services unless automatic recovery is explicitly approved.

Membership in `IIS_IUSRS` alone should not be assumed to provide administrative IIS monitoring access.

## Directory permissions

The default installation directory is:

```text
C:\ProgramData\LegacyServiceMonitor
```

The scheduled task account needs:

- Read and Execute on PowerShell scripts and the JSON configuration
- Modify on the installation directory
- Modify on the `Logs` directory
- Modify on `state.json`

Example:

```powershell
$account = "DOMAIN\svc_legacy_monitor"
$path = "C:\ProgramData\LegacyServiceMonitor"

icacls $path /grant "${account}:(OI)(CI)M" /T
```

## Configure monitored components

Edit `monitored-components.json`.

Example:

```json
{
  "WebSites": [
    {
      "Name": "Legacy Portal",
      "Enabled": true
    }
  ],
  "ApplicationPools": [
    {
      "Name": "LegacyPortalPool",
      "Enabled": true
    }
  ],
  "WindowsServices": [
    {
      "Name": "LegacyIntegrationService",
      "DisplayName": "Legacy Integration Service",
      "Enabled": true
    }
  ]
}
```

Use the IIS website and application pool names exactly as they appear in IIS Manager.

Use the Windows service **service name**, not only the friendly display name.

To identify service names:

```powershell
Get-Service | Sort-Object DisplayName | Select-Object Name, DisplayName, Status
```

## Failure suppression behavior

`FailureThreshold` defines how many consecutive failed checks are required before the first alert.

Example:

```json
"FailureThreshold": 2
```

With a five-minute task interval:

- First failed check: no notification
- Second consecutive failed check: one failure notification
- Additional failed checks: no repeated notification
- First healthy check after failure: one recovery notification

State is stored in:

```text
C:\ProgramData\LegacyServiceMonitor\state.json
```

Deleting the state file resets all alert suppression history.

## SMTP configuration

Update the `Notification.Smtp` section:

```json
"Smtp": {
  "Server": "smtp.company.com",
  "Port": 587,
  "UseSsl": true,
  "UseDefaultCredentials": false,
  "CredentialFile": "C:\\ProgramData\\LegacyServiceMonitor\\smtp-credential.xml"
}
```

If the SMTP relay accepts the Windows identity, set:

```json
"UseDefaultCredentials": true
```

If explicit SMTP credentials are required, run the following command **while signed in as the same account that will execute the scheduled task**:

```powershell
.\Create-SmtpCredential.ps1
```

The credential file uses Windows Data Protection API through `Export-Clixml`. It is normally decryptable only by the same Windows account on the same computer.

Test manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\ProgramData\LegacyServiceMonitor\Monitor-LegacyComponents-Smtp.ps1" `
  -ConfigurationPath "C:\ProgramData\LegacyServiceMonitor\monitored-components.json"
```

## Microsoft Graph configuration

The Microsoft Entra application requires:

- Microsoft Graph application permission `Mail.Send`
- Administrator consent
- Permission to send through the configured sender mailbox
- Exchange Online application access restrictions according to corporate policy

Set machine-level environment variables from an elevated PowerShell session:

```powershell
[Environment]::SetEnvironmentVariable(
    "GRAPH_TENANT_ID",
    "tenant-id",
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "GRAPH_CLIENT_ID",
    "client-id",
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "GRAPH_CLIENT_SECRET",
    "client-secret",
    "Machine"
)
```

Restart the scheduled task service or reboot the server after creating machine-level variables if the running process does not detect them.

Update the sender mailbox in `monitored-components.json`:

```json
"Graph": {
  "TenantIdEnvironmentVariable": "GRAPH_TENANT_ID",
  "ClientIdEnvironmentVariable": "GRAPH_CLIENT_ID",
  "ClientSecretEnvironmentVariable": "GRAPH_CLIENT_SECRET",
  "SenderMailbox": "monitoring@company.com"
}
```

The server must be allowed to access:

```text
https://login.microsoftonline.com
https://graph.microsoft.com
```

Test manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\ProgramData\LegacyServiceMonitor\Monitor-LegacyComponents-Graph.ps1" `
  -ConfigurationPath "C:\ProgramData\LegacyServiceMonitor\monitored-components.json"
```

For production, prefer a certificate or an enterprise secret vault instead of a long-lived client secret when the company platform supports it.

## Install the scheduled task

Open Windows PowerShell as Administrator from the extracted package directory.

SMTP version:

```powershell
.\Install-MonitoringTask.ps1 `
  -NotificationMode Smtp `
  -ServiceAccount "DOMAIN\svc_legacy_monitor" `
  -IntervalMinutes 5
```

Microsoft Graph version:

```powershell
.\Install-MonitoringTask.ps1 `
  -NotificationMode Graph `
  -ServiceAccount "DOMAIN\svc_legacy_monitor" `
  -IntervalMinutes 5
```

The installer:

- Copies files to `C:\ProgramData\LegacyServiceMonitor`
- Creates the log directory
- Registers a scheduled task
- Runs the task whether the account is interactively logged on or not
- Prevents overlapping executions
- Restarts the task after execution failures
- Sets a ten-minute execution time limit
- Uses Windows PowerShell 5.1

## Recommended Task Scheduler settings

### General

- Run whether user is logged on or not
- Run with highest privileges
- Configure for the installed Windows Server version
- Use the dedicated monitoring account

### Triggers

- Start one minute after installation
- Repeat every five minutes
- Keep the task enabled

### Actions

Program:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

Typical arguments:

```text
-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\LegacyServiceMonitor\Monitor-LegacyComponents-Smtp.ps1" -ConfigurationPath "C:\ProgramData\LegacyServiceMonitor\monitored-components.json"
```

### Conditions

For servers:

- Do not require AC power
- Do not stop if the power state changes
- Do not require an idle condition

### Settings

- Allow the task to be run on demand
- Run the task as soon as possible after a missed start
- If the task fails, restart every one minute, up to three times
- If the task is already running, do not start a new instance
- Stop the task if it runs longer than ten minutes

## Validation checklist

1. Run the selected script manually with the service account.
2. Confirm the daily log file is created.
3. Confirm `state.json` is created.
4. Temporarily configure a nonexistent test service.
5. Run the script enough times to reach `FailureThreshold`.
6. Confirm exactly one failure message is sent.
7. Run the script again and confirm no duplicate message is sent.
8. Restore the valid component name.
9. Run the script and confirm one recovery message is sent.
10. Start the scheduled task manually and confirm exit code `0`.

## Logs and diagnostics

Daily logs are stored under:

```text
C:\ProgramData\LegacyServiceMonitor\Logs
```

The scheduled task should return:

- `0` when the monitoring cycle completes successfully
- `1` when an unexpected execution or notification error occurs

Review:

- Monitor log files
- Task Scheduler History
- Task Scheduler Last Run Result
- Windows Event Viewer
- SMTP relay or Microsoft Graph audit logs

## Security notes

- Do not store plain-text passwords in scripts or JSON files.
- Restrict access to the installation directory.
- Restrict the Microsoft Graph application to the required mailbox.
- Rotate SMTP passwords, client secrets, or certificates according to company policy.
- Do not enable automatic restart operations without formal approval.
- Use a dedicated monitoring identity rather than a personal account.
