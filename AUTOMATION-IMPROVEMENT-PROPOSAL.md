# Automation Improvement Proposal: Legacy Service Monitor

**Type:** Automation Improvement Suggestion
**Subject:** Automated failure detection and notification for legacy .NET Framework applications (IIS websites, application pools, and Windows services)

## 1. Executive Summary

Many legacy .NET Framework applications hosted on IIS — along with the Windows services that support them — currently have no automated way to detect when they stop running. A website going down, an application pool crashing, or a background service stopping typically goes unnoticed until a user or the business reports it, extending downtime and impact.

This proposal introduces **Legacy Service Monitor**: a lightweight, PowerShell-based automation that runs directly on each application server, detects failures within a configurable time window, and automatically notifies the responsible team by email — with no additional licensing cost, no new infrastructure, and no agents beyond what Windows Server already provides. It can be piloted on a single server in under a day.

## 2. Problem Statement

- Legacy .NET Framework applications on IIS, and the Windows services around them, are often outside the scope of formal enterprise monitoring — either because onboarding them is not prioritized, or because extending paid monitoring platforms to every legacy asset is not cost-justified.
- Without automated detection, the time between an outage starting and someone noticing depends entirely on when a user complains or a business process fails downstream — directly extending Mean Time To Detect (MTTD) and, by extension, Mean Time To Resolve (MTTR).
- Ownership is often unclear at the moment of failure: knowing *which* server, application, squad, and vendor is responsible for a failing component is not always immediate without this context being attached to the alert itself.

## 3. What the Solution Does

For each server, Legacy Service Monitor watches a squad-curated list of:

- **Web applications** — an IIS website and its application pool, monitored together (both must be in a `Started` state).
- **Windows services** — monitored by service name (must be in a `Running` state).

It intentionally does **not** auto-discover every site/service on a server — only the components explicitly listed are monitored, so a team only gets alerted about what it actually owns, never about another team's applications running on the same box.

When a component fails and stays down past a configurable tolerance window (default 30 minutes), the monitor sends **exactly one** alert email — not one per check — and one recovery email when the component comes back. This tolerance window also means planned maintenance (e.g., a manual deployment that stops a service for a few minutes) does not trigger a false alert, with no manual "maintenance mode" step required.

Every alert is routed by **Vendor**, so if multiple vendors or squads share the same server, each only receives notifications for the components tagged as theirs — full isolation, no cross-visibility.

Each alert email includes: server name, environment (DEV/QA/PROD), affected component and its status, owning application name, BEAT ID, squad, and vendor — giving the responder full context without needing to log into the server first.

## 4. How It Works (Technical Overview)

- **Pure PowerShell, no third-party dependencies.** Requires PowerShell 3.0 or later, which ships by default with Windows Server 2012 and every version since — no Windows Management Framework upgrade needed.
- **Runs as a native Windows Scheduled Task** on each server, on a configurable interval (default every 5 minutes), whether or not any user is logged on, and survives server reboots.
- **Configuration is a single JSON file per server** listing the monitored components and notification settings — no database, no central server, no additional infrastructure.
- **State is tracked locally** in a small JSON file that records, per component, how long it has been failing and whether an alert has already been sent — this is what prevents repeat alerts during an ongoing outage.
- **Two interchangeable notification channels**, selected at install time:
  - **SMTP**, using the .NET `SmtpClient`, for environments with an internal mail relay.
  - **Microsoft Graph**, using an Entra ID app registration with application permissions, for environments that prefer Microsoft 365-native mail delivery over direct SMTP.
- **Self-cleaning logs**: a daily log file records cycle start/completion and notification decisions (not a line-by-line record of every check), and files older than a configurable retention period (default 90 days) are deleted automatically — no manual housekeeping.

## 5. Key Benefits

| Benefit | Detail |
|---|---|
| Faster outage detection | Reduces MTTD from "whenever someone notices" to a configurable, predictable window |
| Zero licensing cost | Built entirely on capabilities already present in Windows Server and the existing mail platform |
| Minimal operational footprint | One JSON file per server; no servers, databases, or collectors to provision or patch |
| Multi-vendor / multi-squad ready | One deployment model serves several vendors or squads on the same server without cross-visibility |
| Low alert noise | Tolerance window plus single-alert/single-recovery logic avoids alert fatigue and ignored mailboxes |
| Full ownership context in every alert | BEAT ID, squad, and vendor are attached to every notification, speeding up triage and routing |
| Fast to pilot | A single server can be piloted and validated within a day, with no procurement cycle |

## 6. Requirements

### 6.1 Server Requirements

- Windows Server 2012 or later.
- PowerShell 3.0 or later (already present by default on Server 2012 and later).
- IIS with the `WebAdministration` module (present automatically when IIS Management Tools are installed) for websites and application pools; the built-in `Get-Service` cmdlet is used for Windows services — no additional module needed.

### 6.2 Execution Account ("Machine CWID")

The monitor runs as a Windows Scheduled Task under a **dedicated, non-personal service account** — a Machine CWID rather than an individual's account — so the automation's identity, auditability, and continuity do not depend on any one employee.

Required rights for that account:

- **Log on as a batch job**, on the target server.
- **Local Administrator**, scoped to that specific server only — required for the `WebAdministration`/`IIS:\` provider to reliably enumerate all sites and application pools. This is a monitoring-only grant: no permission to restart sites, pools, or services is included unless automatic recovery is separately proposed and approved.
- **Write access** to the installation directory (`C:\ProgramData\LegacyServiceMonitor`) for its logs and state file.
- **Network reachability** to whichever notification channel is selected (internal mail relay, or Microsoft 365 endpoints — see 6.3).

No interactive logon is required; the account only needs to exist and hold the rights above.

### 6.3 If Using Microsoft Entra ID (Microsoft Graph) for Notifications

- An **App Registration** in Microsoft Entra ID, with:
  - Microsoft Graph **application permission** `Mail.Send`.
  - **Administrator consent** granted on that permission (application permissions require tenant-admin consent; they cannot be self-consented).
  - A client secret (or, preferably for production, a certificate).
  - An Exchange Online **Application Access Policy** scoping the app to only the approved sending mailbox — this prevents the app from being able to send mail as any mailbox in the tenant, limiting blast radius if the credential is ever compromised.
- Outbound network access from the server to `login.microsoftonline.com` and `graph.microsoft.com`.

## 7. Bayer-Specific Notification Consideration

Bayer's environment does not use a direct SMTP relay for this class of application notification — mail is sent through the **Bayer Utils** component, which exposes email-sending functionality via a legacy ASMX web service.

To integrate with this environment as a first step, the monitor's SMTP delivery path will need to be adapted to call the Bayer Utils ASMX endpoint instead of a direct `SmtpClient` connection, and the corresponding access to that endpoint will need to be requested from the team that owns it.

This raises a design point worth flagging directly: using a legacy web service to deliver notifications *about* legacy web service failures introduces a shared point of failure. If Bayer Utils itself becomes unavailable or degraded, the very notification meant to report an outage could be delayed or lost at the moment it matters most.

For this reason, the recommended target state is to onboard the **Microsoft Graph** notification path (section 6.3) as the primary or backup channel once Entra ID access can be arranged, since it depends only on Microsoft 365 platform availability rather than an internal legacy web service — removing that shared point of failure. Bayer Utils can remain the interim channel while that access request is processed.

## 8. Future Integration Potential

### 8.1 ServiceNow — Automatic Incident Creation

Today the monitor only sends email. A natural extension is to have it also open a ServiceNow **Incident** automatically once a failure crosses the tolerance window (via ServiceNow's REST Table API, following the same pattern already used for the Microsoft Graph HTTP integration), and optionally auto-resolve the ticket on recovery.

**Benefit:** guarantees the outage is captured in the incident-management system of record even if an alert email is missed, delayed, or filtered by a mailbox rule, and creates a formal, SLA-tracked audit trail for each event.

### 8.2 Grafana and the Broader Observability Ecosystem

The monitor's check results could optionally be published into a metrics or logging backend already feeding Grafana (for example, a Prometheus-compatible endpoint, a Loki push, or structured events into an existing log pipeline), enabling trend dashboards and long-term availability history across every monitored legacy application.

**Why this solution still adds value in an organization that already has Grafana:** Grafana is a visualization and alerting *layer* — it is only as useful as the data already being collected underneath it. Most of the legacy .NET Framework and on-prem IIS applications in scope here are not currently instrumented with any exporter or agent feeding Grafana, and standing that up (a Windows/IIS exporter per server, plus the pipeline to ship that data) is a materially larger effort than deploying this lightweight, agentless script. Legacy Service Monitor is intentionally the fast, low-cost **first layer of coverage** for applications that would otherwise have no monitoring at all — it can feed a Grafana pipeline later as an enhancement, not as a prerequisite.

## 9. Comparison to Commercial (Licensed) Monitoring Solutions

Commercial application and infrastructure monitoring platforms typically require per-node or per-agent licensing, dedicated collector infrastructure, and a formal onboarding/rollout project. For a defined set of legacy .NET Framework applications that are not currently prioritized for that level of investment, Legacy Service Monitor offers:

- **Zero incremental license cost** — it uses only capabilities already licensed and present: Windows Server, PowerShell, and the existing mail platform (SMTP relay or Microsoft 365).
- **No new infrastructure** — deployment is copying a handful of files to a server and registering one Scheduled Task; there is no central server, database, or collector to provision, patch, or secure.
- **Minutes-to-pilot** — a single server can be piloted and validated the same day, compared to the procurement and agent-rollout timeline typical of a commercial platform.

This is explicitly **not proposed as a replacement** for enterprise-grade monitoring where that investment is already justified — for Tier-1 or revenue-critical systems, a full commercial APM/infrastructure monitoring platform remains the right tool. Legacy Service Monitor is proposed as a pragmatic, near-zero-cost way to close the monitoring gap for legacy and lower-tier applications that currently have no automated detection at all.

## 10. Suggested Rollout Plan

1. **Pilot** — one server, one squad's applications, SMTP via Bayer Utils (or Microsoft Graph if Entra ID access is available sooner). Validate detection, tolerance-window behavior, and notification delivery end to end.
2. **Service account hardening** — replace the pilot's personal account with the dedicated Machine CWID service account described in section 6.2.
3. **Broader rollout** — extend to additional servers, squads, and vendors, using the existing per-vendor recipient routing to keep alerts isolated by owner.
4. **Optional future integrations** — ServiceNow Incident creation and/or a Grafana observability feed, once the base rollout is stable.
