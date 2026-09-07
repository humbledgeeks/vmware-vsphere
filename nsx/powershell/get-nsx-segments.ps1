<#
.SYNOPSIS
    Retrieves all NSX-T segments (logical switches) and their configuration summary.
.DESCRIPTION
    Authenticates to the NSX Manager Policy API and returns a list of all segments
    with their VLAN/overlay configuration, transport zone, and admin state.
    Read-only — no changes are made to the environment.
.PARAMETER NSXManager
    FQDN or IP of the NSX Manager.
.PARAMETER SkipCertCheck
    Suppress TLS certificate validation. Use only in lab environments.
    Requires PowerShell 7+ (-SkipCertificateCheck is not available in 5.1).
.EXAMPLE
    .\get-nsx-segments.ps1 -NSXManager nsx-mgr.lab.local
.NOTES
    Author  : humbledgeeks-allen
    Date    : 2026-03-16
    Version : 1.0
    Module  : N/A (NSX-T Policy REST API via Invoke-RestMethod)
    API     : NSX-T Policy API v1
    Repo    : vmware-nsx-powershell
    Prereq  : PowerShell 7+ when using -SkipCertCheck
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$NSXManager,

    [switch]$SkipCertCheck
)

$ErrorActionPreference = "Stop"

# ── Auth header ───────────────────────────────────────────────────────────────
$creds      = Get-Credential -Message "Enter NSX Manager credentials"
$base64Auth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("$($creds.UserName):$($creds.GetNetworkCredential().Password)")
)
$headers = @{
    "Authorization" = "Basic $base64Auth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

$baseUrl     = "https://$NSXManager/policy/api/v1"
$restParams  = if ($SkipCertCheck) { @{ SkipCertificateCheck = $true } } else { @{} }

# ── Segments ──────────────────────────────────────────────────────────────────
Write-Output "Connecting to NSX Manager: $NSXManager"
Write-Output "`n=== NSX-T Segments ==="
$segResponse = Invoke-RestMethod -Uri "$baseUrl/infra/segments" `
    -Headers $headers -Method GET @restParams

$segResponse.results | Select-Object `
    @{N="Segment";         E={$_.display_name}},
    @{N="Type";            E={$_.type}},
    @{N="VLAN";            E={$_.vlan_ids -join ","}},
    @{N="TransportZone";   E={$_.transport_zone_path -replace ".*/",""}},
    @{N="AdminState";      E={$_.admin_state}} |
    Format-Table -AutoSize

Write-Output "Total segments: $($segResponse.result_count)"

# ── Tier-1 Gateways ───────────────────────────────────────────────────────────
Write-Output "`n=== Tier-1 Gateways ==="
$t1Response = Invoke-RestMethod -Uri "$baseUrl/infra/tier-1s" `
    -Headers $headers -Method GET @restParams

$t1Response.results | Select-Object `
    @{N="T1 Gateway";     E={$_.display_name}},
    @{N="HA Mode";        E={$_.ha_mode}},
    @{N="Tier0 Path";     E={$_.tier0_path -replace ".*/",""}} |
    Format-Table -AutoSize

Write-Output "`nNSX segment inventory complete."
