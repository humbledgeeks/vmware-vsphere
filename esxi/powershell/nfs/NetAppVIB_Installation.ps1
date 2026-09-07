<#
.SYNOPSIS
    Install the NetApp NFS VAAI VIB (NetAppNasPlugin) on ESXi hosts with -WhatIf and HTML summary.
.DESCRIPTION
    Connects to vCenter, standalone hosts, a CSV list, or installs from a local path or datastore.
    Checks whether NetAppNasPlugin is already installed on each host before attempting installation
    via esxcli software vib install. Supports -WhatIf and generates an HTML installation summary
    report plus a CSV audit log.

    Credentials resolve in this order:
      1. -Credential parameter (PSCredential)
      2. $env:VCENTER_PASSWORD + $env:VCENTER_USER (or -Username)
      3. Interactive Get-Credential prompt
.PARAMETER OutputPath
    Directory for HTML summary and CSV audit log. Defaults to C:\VAAI_VIB_Install.
.PARAMETER Credential
    PSCredential for vCenter/ESXi authentication. Overrides env vars and interactive prompt.
.PARAMETER Username
    Username for env-var auth fallback. Defaults to $env:VCENTER_USER, then 'root'.
.PARAMETER ConnectionMode
    vCenter | Standalone | Csv | LocalPath | Datastore. If omitted, an interactive menu is shown.
.PARAMETER vCenter
    vCenter Server FQDN (used when ConnectionMode = vCenter).
.PARAMETER Cluster
    Cluster name to target (used when ConnectionMode = vCenter). Empty = all hosts.
.PARAMETER VMHost
    One or more ESXi hostnames (used when ConnectionMode = Standalone/LocalPath/Datastore).
.PARAMETER HostCsvPath
    Path to a CSV with a Host column and optional VIBPath/FQDN columns (used for Csv mode).
.PARAMETER VibPath
    Explicit VIB path on the ESXi host (e.g. /tmp/NetAppNasPlugin.vib or /vmfs/volumes/ds/file.vib).
.PARAMETER DatastoreName
    Datastore that hosts the VIB (used when ConnectionMode = Datastore). VibPath is computed.
.PARAMETER VibFile
    VIB filename within the datastore (used when ConnectionMode = Datastore).
.PARAMETER OpenHtmlReport
    If set, opens the HTML summary in the default browser when complete. Default: off.
.EXAMPLE
    .\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib -WhatIf
.EXAMPLE
    $env:VCENTER_PASSWORD = '<vcenter-password-placeholder>'; $env:VCENTER_USER = 'svc-automation'
    .\NetAppVIB_Installation.ps1 -ConnectionMode Csv -HostCsvPath .\hosts.csv -VibPath /tmp/NetAppNasPlugin.vib
.NOTES
    Author  : Allen Johnson
    Date    : 2025-07-28 (refactored 2026-05-14)
    Version : 2.0
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
    Prereq  : NetApp NAS Plugin VIB pre-staged on a datastore or local path accessible to the target hosts.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][string]$OutputPath = 'C:\VAAI_VIB_Install',
    [Parameter()][System.Management.Automation.PSCredential]$Credential,
    [Parameter()][string]$Username,
    [Parameter()][ValidateSet('vCenter', 'Standalone', 'Csv', 'LocalPath', 'Datastore')][string]$ConnectionMode,
    [Parameter()][string]$vCenter,
    [Parameter()][string]$Cluster,
    [Parameter()][string[]]$VMHost,
    [Parameter()][string]$HostCsvPath,
    [Parameter()][string]$VibPath,
    [Parameter()][string]$DatastoreName,
    [Parameter()][string]$VibFile,
    [Parameter()][switch]$OpenHtmlReport
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

function Show-Summary {
    param ([object[]]$Summary, [switch]$IsDryRun)
    $header = if ($IsDryRun) { "🧪 DRY-RUN Summary" } else { "📄 VAAI VIB Installation Summary" }
    Write-Host "`n===== $header =====" -ForegroundColor Gray
    foreach ($row in $Summary) {
        $color = switch -Wildcard ($row.Status) {
            'SUCCESS*'  { 'Green';  break }
            'ALREADY*'  { 'Yellow'; break }
            'FAILURE*'  { 'Red';    break }
            'DRY-RUN*'  { 'Yellow'; break }
            default     { 'Gray' }
        }
        Write-Host ("{0,-30} => {1}" -f $row.Host, $row.Status) -ForegroundColor $color
    }
    Write-Host "`nTotal processed: $($Summary.Count)`n" -ForegroundColor White
}

function Export-SummaryToHtml {
    param ([object[]]$Summary, [string]$Path, [string]$Timestamp, [string]$Username)
    $htmlPath = Join-Path $Path "vaai_vib_summary_$Timestamp.html"

    $rows = foreach ($r in $Summary) {
        $class = switch -Wildcard ($r.Status) {
            'SUCCESS*'  { 'success'; break }
            'ALREADY*'  { 'already'; break }
            'FAILURE*'  { 'failure'; break }
            'DRY-RUN*'  { 'dryrun';  break }
            default     { 'failure' }
        }
        "<tr><td>$($r.Host)</td><td>$($r.FQDN)</td><td>$($r.VibPath)</td><td class='$class'>$($r.Status)</td><td>$($r.RebootRequired)</td><td>$($r.DurationSec) sec</td><td>$([System.Web.HttpUtility]::HtmlEncode($r.Message))</td></tr>"
    }

    $html = @"
<html><head><meta charset='UTF-8'><style>
body { font-family: Consolas, monospace; background-color: #121212; color: #eee; padding: 1rem; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { border: 1px solid #555; padding: 6px; text-align: left; }
th { background-color: #1e1e1e; color: #fff; }
.success { color: lightgreen; }
.already { color: khaki; }
.failure { color: salmon; }
.dryrun { color: khaki; }
</style></head><body>
<h2>NetApp NFS VAAI VIB Installation Summary - $Timestamp</h2>
<p><strong>Generated by:</strong> $Username</p>
<table>
<tr><th>Host</th><th>FQDN</th><th>VIB Path</th><th>Status</th><th>Reboot Required</th><th>Duration</th><th>Message</th></tr>
$($rows -join "`n")
</table></body></html>
"@
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Host "📄 HTML summary exported to $htmlPath" -ForegroundColor Yellow
    return $htmlPath
}

function Invoke-VibCheckAndInstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory)] $VMHost,
        [Parameter(Mandatory)] [string]$Fqdn,
        [Parameter(Mandatory)] [string]$VibPath
    )
    $startTime = Get-Date
    $rebootRequired = 'No'
    $status = 'UNKNOWN'
    $message = ''

    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2
        $vibList = $esxcli.software.vib.list.Invoke()
        $vibInstalled = [bool]($vibList | Where-Object { $_.Name -eq 'NetAppNasPlugin' })

        if ($vibInstalled) {
            $status = 'ALREADY INSTALLED'
        }
        elseif ($PSCmdlet.ShouldProcess($Fqdn, "Install NetAppNasPlugin from $VibPath")) {
            Write-Host "Installing NetApp VAAI VIB on $Fqdn from $VibPath..." -ForegroundColor Cyan
            $installResult = $esxcli.software.vib.install.Invoke(@{ v = $VibPath; noSigCheck = $true })
            if ($installResult.RebootRequired) { $rebootRequired = 'Yes' }
            $status = 'SUCCESS'
        }
        else {
            $status = 'DRY-RUN'
        }
    } catch {
        $status = 'FAILURE'
        $message = $_.Exception.Message
    }

    $duration = [math]::Round((New-TimeSpan -Start $startTime).TotalSeconds, 1)
    return [pscustomobject]@{
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Host           = $VMHost.Name
        FQDN           = $Fqdn
        VibPath        = $VibPath
        Status         = $status
        RebootRequired = $rebootRequired
        DurationSec    = $duration
        Message        = $message
    }
}

Clear-Host
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "NetApp NFS VAAI VIB Installer Script" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Yellow

if (-not $ConnectionMode) {
    Write-Host "[1] vCenter (cluster-based or all hosts)"
    Write-Host "[2] Standalone ESXi Host(s)"
    Write-Host "[3] Import ESXi Hosts from CSV"
    Write-Host "[4] Install VAAI VIB from Local Path"
    Write-Host "[5] Install VAAI VIB from Datastore"
    switch (Read-Host "Enter selection [1-5]") {
        '1' { $ConnectionMode = 'vCenter' }
        '2' { $ConnectionMode = 'Standalone' }
        '3' { $ConnectionMode = 'Csv' }
        '4' { $ConnectionMode = 'LocalPath' }
        '5' { $ConnectionMode = 'Datastore' }
        default { throw "Invalid selection." }
    }
}

# Output directory
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$auditCsv = Join-Path $OutputPath "vaai_vib_install_$timestamp.csv"

$cred = Resolve-PowerCLICredential -Credential $Credential -Username $Username
$summary = @()
$connectedVIServers = @()

switch ($ConnectionMode) {
    'vCenter' {
        if (-not $vCenter) { $vCenter = Read-Host "Enter vCenter Server name or IP" }
        $viserver = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
        $connectedVIServers += $viserver
        if (-not $PSBoundParameters.ContainsKey('Cluster')) {
            $Cluster = Read-Host "Enter cluster name (leave blank for all hosts)"
        }
        if (-not $VibPath) { $VibPath = Read-Host "Enter VIB Path on target hosts" }
        $vmhosts = if ([string]::IsNullOrWhiteSpace($Cluster)) { Get-VMHost } else { Get-Cluster -Name $Cluster | Get-VMHost }
        foreach ($vmhost in $vmhosts) { $summary += Invoke-VibCheckAndInstall -VMHost $vmhost -Fqdn $vmhost.Name -VibPath $VibPath }
    }
    'Standalone' {
        if (-not $VMHost) {
            $VMHost = (Read-Host "Enter standalone ESXi hostnames/IPs (comma-separated)") -split ',' |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        if (-not $VibPath) { $VibPath = Read-Host "Enter VIB Path" }
        foreach ($esxiHost in $VMHost) {
            $viSession = Connect-VIServer -Server $esxiHost -Credential $cred -ErrorAction Stop
            $connectedVIServers += $viSession
            $vmhostObj = Get-VMHost -Server $viSession
            $summary += Invoke-VibCheckAndInstall -VMHost $vmhostObj -Fqdn $esxiHost -VibPath $VibPath
        }
    }
    'Csv' {
        if (-not $HostCsvPath) { $HostCsvPath = Read-Host "Enter path to hosts.csv" }
        if (-not (Test-Path $HostCsvPath)) { throw "CSV not found at $HostCsvPath" }
        $csvHosts = Import-Csv $HostCsvPath
        foreach ($row in $csvHosts) {
            # SECURITY: passwords NEVER come from CSV. Use -Credential or $env:VCENTER_PASSWORD.
            $targetHost = $row.Host
            $rowVibPath = if ($row.PSObject.Properties['VIBPath'] -and $row.VIBPath) { $row.VIBPath } else { $VibPath }
            if (-not $rowVibPath) { throw "No VIBPath in CSV row for $targetHost and no -VibPath parameter supplied." }
            $rowFqdn = if ($row.PSObject.Properties['FQDN'] -and $row.FQDN) { $row.FQDN } else { $targetHost }
            $viSession = Connect-VIServer -Server $targetHost -Credential $cred -ErrorAction Stop
            $connectedVIServers += $viSession
            $vmhostObj = Get-VMHost -Server $viSession
            $summary += Invoke-VibCheckAndInstall -VMHost $vmhostObj -Fqdn $rowFqdn -VibPath $rowVibPath
        }
    }
    'LocalPath' {
        if (-not $VibPath) { $VibPath = Read-Host "Enter local VIB Path (example: /tmp/NetAppNasPlugin.vib)" }
        if (-not $VMHost) {
            $VMHost = (Read-Host "Enter ESXi hostnames/IPs (comma-separated)") -split ',' |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        foreach ($esxiHost in $VMHost) {
            $viSession = Connect-VIServer -Server $esxiHost -Credential $cred -ErrorAction Stop
            $connectedVIServers += $viSession
            $vmhostObj = Get-VMHost -Server $viSession
            $summary += Invoke-VibCheckAndInstall -VMHost $vmhostObj -Fqdn $esxiHost -VibPath $VibPath
        }
    }
    'Datastore' {
        if (-not $DatastoreName) { $DatastoreName = Read-Host "Enter datastore name" }
        if (-not $VibFile)       { $VibFile       = Read-Host "Enter VIB file name (example: NetAppNasPlugin.vib)" }
        $VibPath = "/vmfs/volumes/$DatastoreName/$VibFile"
        if (-not $VMHost) {
            $VMHost = (Read-Host "Enter ESXi hostnames/IPs (comma-separated)") -split ',' |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        foreach ($esxiHost in $VMHost) {
            $viSession = Connect-VIServer -Server $esxiHost -Credential $cred -ErrorAction Stop
            $connectedVIServers += $viSession
            $vmhostObj = Get-VMHost -Server $viSession
            $summary += Invoke-VibCheckAndInstall -VMHost $vmhostObj -Fqdn $esxiHost -VibPath $VibPath
        }
    }
}

# Persist audit log
$summary | Export-Csv -Path $auditCsv -NoTypeInformation -Encoding UTF8
Write-Host "📝 Audit log written to $auditCsv" -ForegroundColor Cyan

# Console + HTML summary
$isDryRun = $WhatIfPreference -or ($summary | Where-Object { $_.Status -eq 'DRY-RUN' })
Show-Summary -Summary $summary -IsDryRun:$isDryRun
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
$htmlFile = Export-SummaryToHtml -Summary $summary -Path $OutputPath -Timestamp $timestamp -Username $cred.UserName

if ($OpenHtmlReport) { Start-Process $htmlFile }

$connectedVIServers | ForEach-Object { Disconnect-VIServer -Server $_ -Confirm:$false }
Write-Host "🔌 Disconnected from all servers." -ForegroundColor Cyan
