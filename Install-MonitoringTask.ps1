#Requires -Version 3.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Smtp", "Graph")]
    [string]$NotificationMode,

    [string]$TaskName = "Legacy Service Monitor",

    [string]$InstallDirectory = "C:\ProgramData\LegacyServiceMonitor",

    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory)]
    [string]$ServiceAccount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($IntervalMinutes -lt 1) {
    throw "IntervalMinutes must be greater than or equal to 1."
}

$sourceDirectory = $PSScriptRoot

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null
}

$requiredFiles = @(
    "Monitor-Core.psm1",
    "monitored-components.json",
    "Monitor-LegacyComponents-Smtp.ps1",
    "Monitor-LegacyComponents-Graph.ps1",
    "Create-SmtpCredential.ps1"
)

foreach ($file in $requiredFiles) {
    $sourceFile = Join-Path $sourceDirectory $file

    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required file not found: $sourceFile"
    }

    Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $InstallDirectory $file) -Force
}

$logsDirectory = Join-Path $InstallDirectory "Logs"
if (-not (Test-Path -LiteralPath $logsDirectory)) {
    New-Item -Path $logsDirectory -ItemType Directory -Force | Out-Null
}

$scriptName = if ($NotificationMode -eq "Smtp") {
    "Monitor-LegacyComponents-Smtp.ps1"
}
else {
    "Monitor-LegacyComponents-Graph.ps1"
}

$scriptPath = Join-Path $InstallDirectory $scriptName
$configurationPath = Join-Path $InstallDirectory "monitored-components.json"

$actionArguments = @(
    "-NoLogo"
    "-NoProfile"
    "-NonInteractive"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    "`"$scriptPath`""
    "-ConfigurationPath"
    "`"$configurationPath`""
) -join " "

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument $actionArguments `
    -WorkingDirectory $InstallDirectory

$trigger = New-ScheduledTaskTrigger `
    -Daily `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 1)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$password = Read-Host "Enter the password for $ServiceAccount" -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)

try {
    $plainTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -User $ServiceAccount `
        -Password $plainTextPassword `
        -RunLevel Highest `
        -Description "Monitors IIS websites, IIS application pools, and Windows services." `
        -Force | Out-Null
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }

    $plainTextPassword = $null
}

Write-Host "Scheduled task created: $TaskName"
Write-Host "Notification mode: $NotificationMode"
Write-Host "Execution interval: $IntervalMinutes minute(s)"
Write-Host "Install directory: $InstallDirectory"
