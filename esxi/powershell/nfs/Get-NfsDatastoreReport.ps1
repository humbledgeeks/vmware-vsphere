<#
.SYNOPSIS
    Inventory NFS datastores across ESXi hosts and export CSV + HTML reports.
.DESCRIPTION
    Connects to vCenter, standalone ESXi hosts, or a CSV list and collects per-host NFS datastore
    details (server, path, accessibility, capacity, free space). Flags any datastore mounted on
    some hosts in the cluster but not others (consistency check). Read-only.

    Credentials resolve in this order:
      1. -Credential parameter (PSCredential)
      2. $env:VCENTER_PASSWORD + $env:VCENTER_USER (or -Username)
      3. Interactive Get-Credential prompt
.PARAMETER OutputPath
    Directory for CSV/HTML output. Defaults to C:\ESXi_Hardening.
.PARAMETER Credential
    PSCredential for vCenter/ESXi authentication.
.PARAMETER Username
    Username for env-var auth fallback. Defaults to $env:VCENTER_USER, then 'root'.
.PARAMETER ConnectionMode
    vCenter | Standalone | Csv. If omitted, an interactive menu is shown.
.PARAMETER vCenter
    vCenter Server FQDN (used when ConnectionMode = vCenter).
.PARAMETER Cluster
    Cluster name to target (used when ConnectionMode = vCenter). Empty = all hosts.
.PARAMETER VMHost
    One or more standalone ESXi hostnames (used when ConnectionMode = Standalone).
.PARAMETER HostCsvPath
    Path to a CSV with a HostName column (used when ConnectionMode = Csv).
.EXAMPLE
    .\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01
.NOTES
    Author  : Allen Johnson
    Date    : 2026-05-14
    Version : 1.0
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
#>
[CmdletBinding()]
param(
    [Parameter()][string]$OutputPath = 'C:\ESXi_Hardening',
    [Parameter()][System.Management.Automation.PSCredential]$Credential,
    [Parameter()][string]$Username,
    [Parameter()][ValidateSet('vCenter', 'Standalone', 'Csv')][string]$ConnectionMode,
    [Parameter()][string]$vCenter,
    [Parameter()][string]$Cluster,
    [Parameter()][string[]]$VMHost,
    [Parameter()][string]$HostCsvPath
)

Import-Module VMware.PowerCLI -ErrorAction Stop

function Resolve-PowerCLICredential {
    [CmdletBinding()]
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Username
    )
    if ($Credential) { return $Credential }
    if ($env:VCENTER_PASSWORD) {
        $user = if ($Username) { $Username } elseif ($env:VCENTER_USER) { $env:VCENTER_USER } else { 'root' }
        $secure = ConvertTo-SecureString -String $env:VCENTER_PASSWORD -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($user, $secure)
    }
    return Get-Credential -Message 'Enter ESXi/vCenter credentials'
}

Clear-Host
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "        NFS Datastore Inventory Report" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan

if (-not $ConnectionMode) {
    Write-Host "`nChoose a connection method:"
    Write-Host "1. vCenter (cluster-based or all hosts)"
    Write-Host "2. Standalone ESXi Hosts"
    Write-Host "3. Use hosts.csv File"
    switch (Read-Host "Enter your choice (1-3)") {
        '1' { $ConnectionMode = 'vCenter' }
        '2' { $ConnectionMode = 'Standalone' }
        '3' { $ConnectionMode = 'Csv' }
        default { throw "Invalid selection." }
    }
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvOut  = Join-Path $OutputPath "NfsDatastoreReport_${timestamp}.csv"
$htmlOut = Join-Path $OutputPath "NfsDatastoreReport_${timestamp}.html"

$cred = Resolve-PowerCLICredential -Credential $Credential -Username $Username
$connectedVIServers = @()
$hosts = @()

switch ($ConnectionMode) {
    'vCenter' {
        if (-not $vCenter) { $vCenter = Read-Host "Enter vCenter Server" }
        $viserver = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
        $connectedVIServers += $viserver
        if (-not $PSBoundParameters.ContainsKey('Cluster')) {
            $Cluster = Read-Host "Enter cluster name (leave blank for all hosts)"
        }
        $hosts = if ($Cluster) { Get-Cluster -Name $Cluster | Get-VMHost } else { Get-VMHost }
    }
    'Standalone' {
        if (-not $VMHost) {
            $VMHost = (Read-Host "Enter comma-separated list of standalone ESXi hosts") -split ',' |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        foreach ($esxiHostName in $VMHost) {
            try {
                $viserver = Connect-VIServer -Server $esxiHostName -Credential $cred -ErrorAction Stop
                $connectedVIServers += $viserver
                $hosts += Get-VMHost -Server $viserver
            } catch {
                Write-Warning "Could not connect to ${esxiHostName}: $($_.Exception.Message)"
            }
        }
    }
    'Csv' {
        if (-not $HostCsvPath) { $HostCsvPath = Join-Path $OutputPath 'hosts.csv' }
        if (-not (Test-Path $HostCsvPath)) { throw "CSV not found at $HostCsvPath" }
        foreach ($entry in (Import-Csv -Path $HostCsvPath)) {
            try {
                $viserver = Connect-VIServer -Server $entry.HostName -Credential $cred -ErrorAction Stop
                $connectedVIServers += $viserver
                $hosts += Get-VMHost -Server $viserver -Name $entry.HostName
            } catch {
                Write-Warning "Could not connect to $($entry.HostName): $($_.Exception.Message)"
            }
        }
    }
}

# Inventory
$records = foreach ($vmhost in $hosts) {
    Write-Host "🔍 Inventorying $($vmhost.Name)..." -ForegroundColor Cyan
    $nfs = Get-Datastore -VMHost $vmhost | Where-Object { $_.Type -eq 'NFS' }
    foreach ($ds in $nfs) {
        $view = $ds | Get-View
        $info = $view.Info.Nas
        $capacityGB = [math]::Round($ds.CapacityGB, 2)
        $freeGB     = [math]::Round($ds.FreeSpaceGB, 2)
        $freePct    = if ($capacityGB -gt 0) { [math]::Round(($freeGB / $capacityGB) * 100, 1) } else { 0 }
        [pscustomobject]@{
            VMHost      = $vmhost.Name
            Datastore   = $ds.Name
            RemoteHost  = $info.RemoteHost
            RemotePath  = $info.RemotePath
            Accessible  = $ds.ExtensionData.Summary.Accessible
            CapacityGB  = $capacityGB
            FreeGB      = $freeGB
            FreePct     = $freePct
        }
    }
}

# Consistency check: datastores not mounted on all hosts
$allHosts = $hosts.Name | Sort-Object -Unique
$byDatastore = $records | Group-Object Datastore
$inconsistent = @{}
foreach ($g in $byDatastore) {
    $mountedOn = $g.Group.VMHost | Sort-Object -Unique
    $missingFrom = $allHosts | Where-Object { $_ -notin $mountedOn }
    if ($missingFrom) {
        $inconsistent[$g.Name] = $missingFrom
    }
}

# Export CSV
$records | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Host "📄 CSV exported to: $csvOut" -ForegroundColor Cyan

# Export HTML
$rowsHtml = foreach ($r in $records) {
    $cls = if ($r.FreePct -lt 10) { 'warn' } elseif (-not $r.Accessible) { 'err' } else { 'ok' }
    "<tr class='$cls'><td>$($r.VMHost)</td><td>$($r.Datastore)</td><td>$($r.RemoteHost)</td><td>$($r.RemotePath)</td><td>$($r.Accessible)</td><td>$($r.CapacityGB)</td><td>$($r.FreeGB)</td><td>$($r.FreePct)%</td></tr>"
}

$inconsistencyHtml = if ($inconsistent.Count -gt 0) {
    $items = foreach ($k in $inconsistent.Keys) {
        "<li><strong>$k</strong> — missing from: $($inconsistent[$k] -join ', ')</li>"
    }
    "<h2>Mount Consistency Issues</h2><ul>$($items -join "`n")</ul>"
} else {
    "<h2>Mount Consistency</h2><p>All NFS datastores are mounted consistently across enumerated hosts.</p>"
}

$html = @"
<html><head><title>NFS Datastore Report</title><style>
body { font-family: Arial; margin: 20px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
th { background-color: #f2f2f2; }
.ok { background-color: #d4edda; }
.warn { background-color: #fff3cd; }
.err { background-color: #f8d7da; }
</style></head><body>
<h1>NFS Datastore Report</h1>
<p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Hosts:</strong> $($allHosts.Count) &nbsp; <strong>Datastores:</strong> $($byDatastore.Count) &nbsp; <strong>Records:</strong> $($records.Count)</p>
$inconsistencyHtml
<h2>Per-Host NFS Datastores</h2>
<table>
<tr><th>Host</th><th>Datastore</th><th>NFS Server</th><th>Remote Path</th><th>Accessible</th><th>Capacity GB</th><th>Free GB</th><th>Free %</th></tr>
$($rowsHtml -join "`n")
</table>
</body></html>
"@
$html | Out-File -FilePath $htmlOut -Encoding UTF8
Write-Host "🌐 HTML exported to: $htmlOut" -ForegroundColor Cyan

$connectedVIServers | ForEach-Object { Disconnect-VIServer -Server $_ -Confirm:$false }
Write-Host "🔌 Disconnected." -ForegroundColor DarkGray
