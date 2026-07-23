#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\ProgramData\LegacyServiceMonitor\smtp-credential.xml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$outputDirectory = Split-Path -Parent $OutputPath

if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$credential = Get-Credential -Message "Enter the SMTP account credentials."
$credential | Export-Clixml -LiteralPath $OutputPath

Write-Host "The SMTP credential file was created at: $OutputPath"
Write-Host "The file can normally be decrypted only by the same Windows account on the same computer."
