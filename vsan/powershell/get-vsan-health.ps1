<#
.SYNOPSIS
    Gathers vSAN cluster health, disk group summary, and capacity utilization.
.DESCRIPTION
    Connects to vCenter Server using stored credentials and retrieves vSAN
    health test results, disk group configuration, and capacity usage for
    all vSAN-enabled clusters. Read-only — no changes made to the environment.
.PARAMETER vCenterServer
    FQDN or IP address of the vCenter Server managing the vSAN cluster.
.PARAMETER Credential
    PSCredential object for vCenter authentication. Prompted if not supplied.
.PARAMETER SkipCertCheck
    Suppress TLS certificate validation. Use only in lab environments.
.EXAMPLE
    .\get-vsan-health.ps1 -vCenterServer vcenter.lab.local -SkipCertCheck
.EXAMPLE
    $cred = Get-Credential
    .\get-vsan-health.ps1 -vCenterServer vcenter.prod.local -Credential $cred
.NOTES
    Author  : humbledgeeks-allen
    Date    : 2026-03-16
    Version : 1.0
    Module  : VMware.VimAutomation.Core, VMware.VimAutomation.vDS
    Repo    : vmware-vsan-powershell
    Prereq  : PowerCLI 13+ — Install-Module VMware.PowerCLI
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Certificate handling
# ---------------------------------------------------------------------------
if ($SkipCertCheck) {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

# ---------------------------------------------------------------------------
# Connect to vCenter
# ---------------------------------------------------------------------------
Write-Host "`n[INFO] Connecting to vCenter: $vCenterServer" -ForegroundColor Cyan

$connectParams = @{
    Server  = $vCenterServer
    Force   = $true
    ErrorAction = 'Stop'
}
if ($Credential) { $connectParams['Credential'] = $Credential }

try {
    $viConnection = Connect-VIServer @connectParams
    Write-Host "[OK]   Connected as $($viConnection.User)" -ForegroundColor Green
}
catch {
    Write-Error "[ERROR] Failed to connect to vCenter: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
try {

    # Enumerate vSAN-enabled clusters
    $vsanClusters = @(Get-Cluster | Where-Object { $_.VsanEnabled })

    if (-not $vsanClusters) {
        Write-Warning "[WARN] No vSAN-enabled clusters found on $vCenterServer"
    }
    else {
        Write-Host "`n[INFO] Found $($vsanClusters.Count) vSAN cluster(s)" -ForegroundColor Cyan
    }

    foreach ($cluster in $vsanClusters) {

        Write-Host "`n========================================" -ForegroundColor Yellow
        Write-Host " Cluster : $($cluster.Name)" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow

        # --- Disk group summary per host ---
        Write-Host "`n[DISK GROUPS]"
        $vsanHosts = Get-VMHost -Location $cluster | Sort-Object Name

        foreach ($vmhost in $vsanHosts) {
            $diskGroups = Get-VsanDiskGroup -VMHost $vmhost -ErrorAction SilentlyContinue
            if ($diskGroups) {
                foreach ($dg in $diskGroups) {
                    $cacheDisks    = ($dg.ExtensionData.DiskMapping.SSD | Measure-Object).Count
                    $capacityDisks = ($dg.ExtensionData.DiskMapping.NonSSD | Measure-Object).Count
                    Write-Host ("  Host: {0,-35} DiskGroup: {1}  Cache: {2}  Capacity: {3}" -f `
                        $vmhost.Name, $dg.Name, $cacheDisks, $capacityDisks)
                }
            }
            else {
                Write-Host "  Host: $($vmhost.Name) — No disk groups found"
            }
        }

        # --- vSAN health tests ---
        Write-Host "`n[HEALTH TESTS]"
        try {
            $vsanView   = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system"
            $healthData = $vsanView.VsanQueryVcClusterHealthSummary(
                $cluster.ExtensionData.MoRef, $null, $null, $true, $null, $null, 'defaultView'
            )

            foreach ($group in $healthData.Groups) {
                $statusColor = if ($group.GroupHealth -eq 'green') { 'Green' }
                               elseif ($group.GroupHealth -eq 'yellow') { 'Yellow' }
                               else { 'Red' }
                Write-Host ("  [{0}] {1}" -f $group.GroupHealth.ToUpper(), $group.GroupName) -ForegroundColor $statusColor
            }
        }
        catch {
            Write-Warning "  Health query not available: $($_.Exception.Message)"
        }

        # --- Capacity summary ---
        Write-Host "`n[CAPACITY]"
        try {
            $datastores = Get-Datastore -Location $cluster | Where-Object { $_.Type -eq 'vsan' }
            foreach ($ds in $datastores) {
                $totalGB     = [math]::Round($ds.CapacityGB, 1)
                $freeGB      = [math]::Round($ds.FreeSpaceGB, 1)
                $usedGB      = [math]::Round($totalGB - $freeGB, 1)
                $usedPct     = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 1) } else { 0 }

                $capacityColor = if ($usedPct -ge 80) { 'Red' } elseif ($usedPct -ge 60) { 'Yellow' } else { 'Green' }
                Write-Host ("  Datastore: {0,-30} Total: {1,8} GB   Used: {2,8} GB   Free: {3,8} GB   Utilization: {4}%" -f `
                    $ds.Name, $totalGB, $usedGB, $freeGB, $usedPct) -ForegroundColor $capacityColor
            }
        }
        catch {
            Write-Warning "  Capacity query failed: $($_.Exception.Message)"
        }
    }

    Write-Host "`n[INFO] vSAN health gathering complete" -ForegroundColor Cyan

}
finally {
    Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[INFO] Disconnected from $vCenterServer`n" -ForegroundColor Cyan
}
