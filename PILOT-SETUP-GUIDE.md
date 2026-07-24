# Pilot Setup Guide — Legacy Service Monitor (SMTP)

This guide walks through a first pilot installation of Legacy Service Monitor on a single server, using SMTP notifications and a personal secondary administrative account instead of a dedicated service account. It assumes no prior context beyond what is written here.

This setup is temporary. Before this monitor is used for real production alerting, the pilot account must be replaced by a dedicated, non-personal service account (see [README.md](README.md#service-account)).

Read [README.md](README.md) first for background on how the monitor works. This guide only covers the pilot installation steps in order.

## What you need before starting

- Administrative (RDP) access to the target server, using your secondary admin account.
- The names of the IIS websites/application pools and Windows services your squad owns on that server.
- Answers from the email/infrastructure team about the SMTP relay (see Step 3).
- The four values to fill in per monitored component: **Application Name**, **BEAT ID**, **Squad**, **Vendor** (defaults to `TCS`).

## Step 1 — Verify PowerShell and the IIS module on the target server

Log in to the server (any account) and run:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable WebAdministration
```

You need PowerShell **3.0 or later** (Windows Server 2012 and later already meet this by default) and the `WebAdministration` module must be listed. If `WebAdministration` is missing, the IIS Management Scripts and Tools feature is not installed — ask the server owner to add it before continuing.

## Step 2 — Verify your account has *permanent* admin rights on this server

This monitor needs local Administrator rights to reliably read all IIS sites and pools. Some organizations only grant admin rights temporarily (PIM/JIT/PAM tools), which would make the scheduled task fail later when it runs unattended. Check this **before** installing anything.

**2a. Quick check (any account can run this):**

```powershell
net localgroup Administrators
```

Look for your account, or a domain group your account belongs to, in the output.

**2b. Definitive check — log in interactively as the pilot account itself** (do not manually elevate first), then run:

```powershell
whoami /groups | findstr /i "S-1-5-32-544"
```

`S-1-5-32-544` is the fixed SID of `BUILTIN\Administrators`. This resolves your actual, final group membership, including anything inherited from nested domain groups.

- If the line appears with `Enabled by default, Enabled group` in the Attributes column → you have permanent admin rights. Continue to Step 3.
- If the line does not appear, or shows a denied/disabled state → your admin rights are temporary (PIM/JIT). **Stop here** and ask your security team whether the account can be granted standing access for this server, or use a different account for the pilot.

## Step 3 — Get SMTP information from the email/infrastructure team

Ask for the following, ideally in a single ticket/email:

1. **SMTP relay hostname or IP** (the internal relay used by applications, not the end-user mailbox server).
2. **Port**, and whether TLS/SSL is required.
3. **Authentication method** the relay accepts. This is the most important answer — it changes what you do in Step 7:
   - **Anonymous relay, authorized by source IP** — ask them to allow-list this server's IP. No credentials needed.
   - **Windows integrated authentication** — the account running the scheduled task authenticates directly. Ask if it needs any extra "Send As" permission (see note below).
   - **Explicit username/password** — ask for a dedicated SMTP account (does not need to be a full mailbox).
4. **Approved "From" address** — many relays only accept a specific, pre-approved sender address.
5. Confirm **network access** is open from this server to the relay's host and port (open a firewall request now if not — this is usually the slowest step).
6. If any recipient is an external domain (for example, a vendor address), confirm the relay allows sending outside `@bayer.com`.

> Note on Windows integrated authentication: if the approved "From" address is a shared/generic mailbox (not your own), the relay may reject the message with an error like *"Client does not have permissions to send as this sender"* unless your account is explicitly granted **Send As** (or Send on Behalf) rights on that mailbox. Ask about this specifically if you choose this authentication method.

## Step 4 — Copy the package to the server

Copy the whole project folder to a **temporary working directory** on the target server, for example `C:\Temp\LegacyServiceMonitor`. It must contain all six files:

- `Monitor-Core.psm1`
- `Monitor-LegacyComponents-Smtp.ps1`
- `Monitor-LegacyComponents-Graph.ps1`
- `monitored-components.json`
- `Create-SmtpCredential.ps1`
- `Install-MonitoringTask.ps1`

`C:\ProgramData\LegacyServiceMonitor` **is** the official, final location — but you cannot run the installer from inside that folder. `Install-MonitoringTask.ps1` copies each file from wherever it is currently running (the working directory) into the install directory; if both were the same path, that copy step would fail with an error like *"Cannot overwrite the item with itself"*. Use any staging folder other than `C:\ProgramData\LegacyServiceMonitor` — the exact name and location do not matter, it only needs to exist long enough to run the installer once. The installer copies everything into the official location for you in Step 8.

## Step 5 — Identify the exact resource names

**IIS sites and application pools:** open IIS Manager on the server and copy the site name and application pool name exactly as shown (case and spacing matter).

**Windows services:** run this and use the value in the `Name` column, not `DisplayName`:

```powershell
Get-Service | Sort-Object DisplayName | Select-Object Name, DisplayName, Status
```

## Step 6 — Edit `monitored-components.json`

Open the file in the working directory and fill in your squad's real applications. See [README.md](README.md#configure-monitored-components) for the full field reference. Minimum you must set:

- `General.Environment` — `DEV`, `QA`, or `PROD`, matching this server.
- One entry per web application under `WebApplications`, with `SiteName` and `PoolName` from Step 5.
- One entry per Windows service under `WindowsServices`, with `ServiceName` from Step 5.
- `ApplicationName`, `BeatId`, `Squad`, `Vendor` for every entry.
- `Notification.From`, `Notification.To` (your squad's distribution list).
- `Notification.Smtp` — `Server`, `Port`, `UseSsl`, `UseDefaultCredentials`, based on the answers from Step 3.

Leave `FailureToleranceMinutes` (default `30`) and `LogRetentionDays` (default `7`) as-is unless told otherwise.

## Step 7 — Create the SMTP credential file (only if needed)

Skip this step entirely if Step 3 answered **anonymous relay by IP** or **Windows integrated authentication**.

If the relay requires an explicit username and password, run this **while logged in as the same account that will run the scheduled task** (your pilot account). The `.\` prefix means the command is relative to your current folder, so `Set-Location` into the working directory from Step 4 first:

```powershell
Set-Location "C:\Temp\LegacyServiceMonitor"
.\Create-SmtpCredential.ps1
```

Enter the SMTP account's username and password when prompted. The file it creates is encrypted for this specific Windows account on this specific computer — it cannot be copied to another server or read by another account.

## Step 8 — Install the scheduled task

Open PowerShell **as Administrator** (right-click → Run as Administrator), in the same session logged in as your pilot account. Move into the working directory from Step 4 first — the `.\` prefix below only works if your current folder is exactly where `Install-MonitoringTask.ps1` is:

```powershell
Set-Location "C:\Temp\LegacyServiceMonitor"
.\Install-MonitoringTask.ps1 `
  -NotificationMode Smtp `
  -ServiceAccount "DOMAIN\your_secondary_cwid" `
  -TaskName "Legacy Service Monitor (PILOT)" `
  -IntervalMinutes 5
```

When prompted `Enter the password for DOMAIN\...`, type the pilot account's own Windows password (input is hidden). On success you will see:

```
Scheduled task created: Legacy Service Monitor (PILOT)
Notification mode: Smtp
Execution interval: 5 minute(s)
Install directory: C:\ProgramData\LegacyServiceMonitor
```

## Step 9 — Validate the installation

1. Open **Task Scheduler**, find **Legacy Service Monitor (PILOT)**, click **Run**, and confirm **Last Run Result = 0x0**.
2. Confirm a log file exists: `C:\ProgramData\LegacyServiceMonitor\Logs\monitor-<date>.log`.
3. Confirm `C:\ProgramData\LegacyServiceMonitor\state.json` was created.
4. Stop a test service or site, run the task a few times — confirm **no email arrives** while inside the 30-minute tolerance window.
5. Once the component has been down for the full tolerance window, confirm exactly **one** failure email arrives, showing the correct Application/BEAT ID/Squad/Vendor columns.
6. Restart the service or site, run the task again, and confirm exactly **one** recovery email arrives.

## After the pilot

Before this moves beyond a pilot:

- Replace the personal secondary CWID with a dedicated, non-personal service account (see [README.md](README.md#service-account)).
- Remove or rename the `(PILOT)` scheduled task once the production task is in place, so there is no confusion about which one is authoritative.
- Confirm the final SMTP "From" address and recipient list with the squad before treating alerts as actionable.
