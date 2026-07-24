# Legacy Service Monitor

This package monitors:

- IIS websites and their application pools, grouped as web applications
- Windows services

It sends a notification only when a component enters a failure state. It does not repeatedly send the same alert while the component remains unavailable. When the component becomes healthy again, the monitor can send one recovery notification.

## Scope

The monitor only checks the web applications and Windows services explicitly listed in `monitored-components.json`. It does not discover or monitor IIS sites, pools, or services automatically. This is intentional: the list is meant to represent only the applications owned by a single squad, so that squad is never alerted about components owned by other teams or vendors. Each entry also carries ownership metadata (application name, BEAT ID, squad, vendor) so that alert emails identify who owns the affected component.

Two notification implementations are included:

1. SMTP using `System.Net.Mail.SmtpClient`
2. Microsoft Graph using Microsoft Entra ID application authentication

For a guided first-time installation (SMTP, single server, pilot account), follow [PILOT-SETUP-GUIDE.md](PILOT-SETUP-GUIDE.md) instead of assembling the steps below yourself.

## Package contents

| File | Purpose |
|---|---|
| `Monitor-Core.psm1` | Shared monitoring, logging, state management, and message generation |
| `Monitor-LegacyComponents-Smtp.ps1` | Monitoring entry point using SMTP |
| `Monitor-LegacyComponents-Graph.ps1` | Monitoring entry point using Microsoft Graph |
| `monitored-components.json` | Squad-owned web applications, Windows services, ownership metadata, and notification configuration |
| `Create-SmtpCredential.ps1` | Creates an encrypted SMTP credential file |
| `Install-MonitoringTask.ps1` | Copies the files and registers the Windows scheduled task |

## Recommended Windows version

The scripts require Windows PowerShell 3.0 or later and the built-in `WebAdministration` module with the `IIS:\` provider. This covers Windows Server 2012 and later out of the box, including servers that were never upgraded to a later Windows Management Framework.

Before installation, verify on each target server:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable WebAdministration
```

Windows Server 2012 (RTM) ships with PowerShell 3.0 and Windows Server 2012 R2 ships with PowerShell 4.0 by default — both already meet the requirement; no Windows Management Framework upgrade is needed for this package.

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

## Server and environment identification

Set `General.Environment` in `monitored-components.json` to `DEV`, `QA`, or `PROD` for each server the package is installed on. The server's computer name (`$env:COMPUTERNAME`) is captured automatically; no configuration is required for it. The environment, the server name, and the owning vendor (see "Notification recipients") all appear in every alert subject line, in the log lines, and in the alert email body, so recipients can immediately tell which server, environment, and vendor raised the alert:

```text
[Legacy Monitor] [QA] [SERVER01] [Acme Vendor] Legacy Applications Monitoring - ALERT
```

## Configure monitored components

Edit `monitored-components.json`. Only list web applications and Windows services owned by your squad.

Example — `Acme Vendor` and every other value below are placeholders; JSON has no comment syntax, so replace them directly with your own organization's values before deploying:

```json
{
  "WebApplications": [
    {
      "ApplicationName": "Legacy Portal",
      "BeatId": "BEAT-1234",
      "Squad": "Payments",
      "Vendor": "Acme Vendor",
      "SiteName": "Legacy Portal",
      "PoolName": "LegacyPortalPool",
      "Enabled": true
    }
  ],
  "WindowsServices": [
    {
      "ApplicationName": "Legacy Integration Service",
      "BeatId": "BEAT-5678",
      "Squad": "Payments",
      "Vendor": "Acme Vendor",
      "ServiceName": "LegacyIntegrationService",
      "Enabled": true
    }
  ]
}
```

Each `WebApplications` entry represents one legacy web application and produces two checks: the IIS website (`SiteName`) and its application pool (`PoolName`) must both be `Started`. Use the site and pool names exactly as they appear in IIS Manager.

Use the Windows service **service name** in `ServiceName`, not only the friendly display name. To identify service names:

```powershell
Get-Service | Sort-Object DisplayName | Select-Object Name, DisplayName, Status
```

`ApplicationName`, `BeatId`, and `Squad` identify the owning application and team, and appear in alert emails. `Vendor` identifies the vendor operating the application on behalf of the squad; `Acme Vendor` in this example is a placeholder — replace it with your real vendor name (or your own team's name, if there is no external vendor). The field accepts any value.

## Notification recipients

Recipients are routed by `Vendor`, not a single global list. This lets one server monitor components owned by multiple vendors while keeping each vendor's alerts visible only to that vendor's own team — one vendor never sees another vendor's alerts. `Notification.VendorRecipients` maps each `Vendor` value used in `WebApplications`/`WindowsServices` to its own `To`/`Cc` list, each of which accepts multiple addresses:

```json
"VendorRecipients": {
  "Default": {
    "To": ["fallback-admin@company.com"],
    "Cc": []
  },
  "Acme Vendor": {
    "To": ["acme-support@example.com", "acme-lead@example.com"],
    "Cc": ["on-call-distribution-list@company.com"]
  }
}
```

`Default` is **required** — the monitor refuses to run a notification cycle without it. It is used whenever a component's `Vendor` does not match any key in `VendorRecipients` (for example, a typo, or a vendor added to `WebApplications`/`WindowsServices` before its recipient list was configured). Every time this fallback is used, a `WARN` line is written to the log naming the unmatched vendor, so the gap gets noticed and fixed.

A single monitoring cycle can send **more than one email** — one per vendor that has an active failure or recovery that run, each addressed only to that vendor's own recipients. `Cc` can be left as an empty array (`[]`) if not needed. This applies to both the SMTP and the Microsoft Graph notification path, and the vendor name is included in the email subject line (see "Server and environment identification").

## Failure suppression behavior

`FailureToleranceMinutes` defines how long a component must remain **continuously unhealthy, in wall-clock time**, before the first alert is sent — not a count of failed checks. This makes the behavior independent of the task interval: whether the task runs every minute or every ten minutes, a component only alerts once it has actually been down for the configured number of minutes.

```json
"FailureToleranceMinutes": 30
```

Internally, each monitored component keeps a small state entry (see below) with a `FirstFailureAt` timestamp. Every cycle recomputes `elapsed = now - FirstFailureAt` and compares it against `FailureToleranceMinutes` to decide whether to alert. Walking through a real failure, with a 5-minute task interval and `FailureToleranceMinutes: 30`:

| Time | What happens | Notification |
|---|---|---|
| 08:00 | Site goes down. `FirstFailureAt` is recorded. | None |
| 08:05 – 08:25 | Still down each cycle; elapsed time is still under 30 minutes. | None |
| 08:30 | Still down; elapsed time now exceeds 30 minutes. | **One** failure email |
| 08:35 – 09:00 | Still down every cycle after that. | None (already alerted) |
| 09:05 | Site is back up. | **One** recovery email |

If the site had come back at, say, 08:20 (before the 30-minute mark), the sequence would have produced **zero emails** — the failure resolved inside the tolerance window and never crossed the alert threshold. This is what makes a normal 30-minute manual deployment invisible to on-call without any manual "maintenance mode" step.

Set `FailureToleranceMinutes` to match the longest planned maintenance window you want to go unnoticed. Set it to `0` to alert on the first failed check (no tolerance).

### State file

State is stored in:

```text
C:\ProgramData\LegacyServiceMonitor\state.json
```

This file is a **current snapshot, not a history** — it is overwritten every cycle and holds exactly one entry per monitored component (keyed by `Type::Name`), not a log of past events. Deleting it resets all alert suppression history (every component is treated as freshly healthy on the next cycle).

Example entry for a site that alerted at 08:30 and is still down:

```json
"WebSite::Legacy Portal": {
  "Type": "WebSite",
  "Name": "Legacy Portal",
  "IsInFailure": true,
  "FirstFailureAt": "2026-07-24T08:00:00.0000000-03:00",
  "LastStatus": "Stopped",
  "LastChange": "2026-07-24T08:30:00.0000000-03:00",
  "LastAlert": "2026-07-24T08:30:00.0000000-03:00"
}
```

`IsInFailure: true` is what suppresses repeat emails while the outage continues. Once the site recovers, this entry resets to `"IsInFailure": false, "FirstFailureAt": null`, ready to time a future outage from zero.

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
- Uses the Windows PowerShell 5.1 engine path (`WindowsPowerShell\v1.0\powershell.exe`), which runs any installed PowerShell version 3.0 or later

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
5. Run the script until the elapsed time exceeds `FailureToleranceMinutes` (temporarily lower the value for faster testing).
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

One file is written per calendar day (`monitor-yyyy-MM-dd.log`). A new line is appended at fixed points in every monitoring cycle — **not** once per monitored site, pool, or service. The individual Started/Stopped/Running status of each component is only ever written to `state.json` (see "State file" above); it is never logged line-by-line. This means log volume depends on how often the task runs and how often alerts actually fire, **not** on how many components are configured — monitoring 30 components produces the same log volume as monitoring 3, as long as neither has active failures.

| Moment | Level | Example message |
|---|---|---|
| Cycle starts | `INFO` | `SMTP monitoring cycle started.` |
| No alert/recovery needed this cycle | `INFO` | `No notification was required.` |
| Email sent to a vendor | `INFO` | `SMTP notification sent to vendor 'Acme Vendor'. Event count: 1` |
| A component's `Vendor` has no matching recipient list | `WARN` | `No VendorRecipients entry for vendor 'Globant'. Falling back to Default recipients.` |
| Cycle completes | `INFO` | `SMTP monitoring cycle completed successfully.` |
| Unexpected error | `ERROR` | `SMTP monitoring cycle failed: <exception message>` |

Example of a real log excerpt, spanning a quiet cycle followed by one that raises an alert:

```text
2026-07-24 08:00:07 [SERVER01] [INFO] SMTP monitoring cycle started.
2026-07-24 08:00:08 [SERVER01] [INFO] No notification was required.
2026-07-24 08:00:08 [SERVER01] [INFO] SMTP monitoring cycle completed successfully.
2026-07-24 08:05:07 [SERVER01] [INFO] SMTP monitoring cycle started.
2026-07-24 08:05:09 [SERVER01] [INFO] SMTP notification sent to vendor 'Acme Vendor'. Event count: 1
2026-07-24 08:05:09 [SERVER01] [INFO] SMTP monitoring cycle completed successfully.
```

Each line is prefixed with the server name, so logs collected from multiple servers can be told apart.

**Estimating volume:** with the default 5-minute interval, that is `1440 / 5 = 288` cycles per day, or roughly 3 log lines per cycle (plus one extra line per vendor that has an active alert or recovery that cycle) — around 850–900 lines/day, well under 100 KB/day regardless of how many web applications or Windows services are configured. Log files older than `General.LogRetentionDays` (default `90`) are deleted automatically at the start of every monitoring cycle, based on each file's last-modified time (in practice equivalent to its creation date, since each day writes to its own file and stops being touched once the next day's file starts). At the default 90-day retention, steady-state disk usage is on the order of a few megabytes.

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
