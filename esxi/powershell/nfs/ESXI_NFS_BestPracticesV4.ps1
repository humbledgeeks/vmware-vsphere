<#
.SYNOPSIS
    Apply NetApp NFS best-practice advanced settings to ESXi hosts with dry-run and HTML report.
.DESCRIPTION
    Connects to vCenter, standalone ESXi hosts, or a CSV list and applies 11 recommended NFS
    advanced settings including Net.TcpipHeapSize, NFS.MaxVolumes, NFS41.MaxVolumes,
    NFS.MaxQueueDepth, SunRPC.MaxConnPerIP, and Disk.QFullSampleSize/Threshold. Supports
    -WhatIf and generates an HTML change summary report.

    Credentials resolve in this order:
      1. -Credential parameter (PSCredential)
      2. $env:VCENTER_PASSWORD + $env:VCENTER_USER (or -Username)
      3. Interactive Get-Credential prompt
.PARAMETER OutputPath
    Directory for CSV/HTML/log output. Defaults to C:\ESXi_Hardening.
.PARAMETER Credential
    PSCredential for vCenter/ESXi authentication. Overrides env vars and interactive prompt.
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
    .\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01 -WhatIf
.EXAMPLE
    $env:VCENTER_PASSWORD = 'secret'; $env:VCENTER_USER = 'svc-automation'
    .\ESXI_NFS_BestPracticesV4.ps1 -ConnectionMode vCenter -vCenter vc01.lab -Cluster Prod-01
.NOTES
    Author  : HumbledGeeks / Allen Johnson
    Date    : 2023-06-05 (refactored 2026-05-14)
    Version : V5
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
    Warning : Makes configuration changes to ESXi hosts. Always run -WhatIf first.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
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
Write-Host "        NFS Best Practices Hardening Script" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan

if (-not $ConnectionMode) {
    Write-Host "`nPlease choose a connection method:"
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

# NetApp NFS best-practice settings (kept inline by design)
$nfsSettings = @{
    'Net.TcpipHeapSize'        = '32'
    'Net.TcpipHeapMax'         = '1024'
    'NFS.MaxVolumes'           = '256'
    'NFS41.MaxVolumes'         = '256'
    'NFS.MaxQueueDepth'        = '128'
    'NFS.HeartbeatMaxFailures' = '10'
    'NFS.HeartbeatFrequency'   = '12'
    'NFS.HeartbeatTimeout'     = '5'
    'Disk.QFullSampleSize'     = '32'
    'Disk.QFullThreshold'      = '8'
    'SunRPC.MaxConnPerIP'      = '128'
}

# Paths and logs
New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$changeLogCsv = Join-Path $OutputPath "NFS_AdvancedSettings_Changes_${timestamp}.csv"
$baselineCsv  = Join-Path $OutputPath "NFS_AdvancedSettings_Baseline_${timestamp}.csv"
$textLogPath  = Join-Path $OutputPath "NFS_AdvancedSettings_Log_${timestamp}.txt"

'Timestamp,HostName,Setting,OldValue,NewValue,Result' | Out-File $changeLogCsv -Encoding UTF8
'Timestamp,HostName,Setting,CurrentValue'             | Out-File $baselineCsv  -Encoding UTF8
"[{0}] Starting NFS Best Practices Run" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
    Out-File $textLogPath -Encoding UTF8

function Write-ChangedSetting   { param($msg) Write-Host "⚠️  $msg" -ForegroundColor Yellow; $msg | Out-File $textLogPath -Append -Encoding UTF8 }
function Write-CompliantSetting { param($msg) Write-Host "✅ $msg" -ForegroundColor Green;  $msg | Out-File $textLogPath -Append -Encoding UTF8 }
function Write-ErrorSetting     { param($msg) Write-Host "❌ $msg" -ForegroundColor Red;    $msg | Out-File $textLogPath -Append -Encoding UTF8 }

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
                Write-Host "🔄 Connected to $esxiHostName" -ForegroundColor Green
            } catch {
                Write-ErrorSetting "Could not connect to ${esxiHostName}: $($_.Exception.Message)"
            }
        }
    }
    'Csv' {
        if (-not $HostCsvPath) { $HostCsvPath = Join-Path $OutputPath 'hosts.csv' }
        if (-not (Test-Path $HostCsvPath)) {
            Write-ErrorSetting "CSV file not found at: $HostCsvPath"
            exit 1
        }
        foreach ($entry in (Import-Csv -Path $HostCsvPath)) {
            try {
                $viserver = Connect-VIServer -Server $entry.HostName -Credential $cred -ErrorAction Stop
                $connectedVIServers += $viserver
                $hosts += Get-VMHost -Server $viserver -Name $entry.HostName
                Write-Host "🔄 Connected to $($entry.HostName)" -ForegroundColor Green
            } catch {
                Write-ErrorSetting "Could not connect to $($entry.HostName): $($_.Exception.Message)"
            }
        }
    }
}

# Apply NFS Best Practices
foreach ($vmhost in $hosts) {
    $hostName = $vmhost.Name
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "`n🔧 [$time] Processing $hostName..." -ForegroundColor Cyan

    foreach ($setting in $nfsSettings.Keys) {
        $desiredValue = $nfsSettings[$setting]
        try {
            $currentSetting = Get-AdvancedSetting -Entity $vmhost -Name $setting -ErrorAction Stop
        } catch {
            Write-ErrorSetting "$hostName - MISSING: setting '$setting' not present"
            "$time,$hostName,$setting,,${desiredValue},MissingOnHost" | Out-File $changeLogCsv -Append -Encoding UTF8
            continue
        }

        $currentValue = $currentSetting.Value
        "$time,${hostName},${setting},${currentValue}" | Out-File $baselineCsv -Append -Encoding UTF8

        if ($currentValue -eq $desiredValue) {
            Write-CompliantSetting "$hostName - COMPLIANT: $setting = '$currentValue'"
            "$time,$hostName,$setting,$currentValue,$desiredValue,Already compliant" | Out-File $changeLogCsv -Append -Encoding UTF8
            continue
        }

        if ($PSCmdlet.ShouldProcess($hostName, "Set $setting from '$currentValue' to '$desiredValue'")) {
            try {
                Set-AdvancedSetting -AdvancedSetting $currentSetting -Value $desiredValue -Confirm:$false -ErrorAction Stop | Out-Null
                Write-ChangedSetting "$hostName - CHANGED: $setting from '$currentValue' to '$desiredValue'"
                "$time,$hostName,$setting,$currentValue,$desiredValue,Updated" | Out-File $changeLogCsv -Append -Encoding UTF8
            } catch {
                Write-ErrorSetting "$hostName - ERROR setting $setting`: $($_.Exception.Message)"
                "$time,$hostName,$setting,$currentValue,$desiredValue,Error" | Out-File $changeLogCsv -Append -Encoding UTF8
            }
        } else {
            "$time,$hostName,$setting,$currentValue,$desiredValue,DryRun" | Out-File $changeLogCsv -Append -Encoding UTF8
        }
    }
}

# Disconnect sessions
$connectedVIServers | ForEach-Object {
    Disconnect-VIServer -Server $_ -Confirm:$false
    Write-Host "🔌 Disconnected from $($_.Name)" -ForegroundColor DarkGray
}

# Generate HTML Summary
Write-Host "`n📝 Generating HTML Summary Report..." -ForegroundColor Cyan
$htmlPath = Join-Path $OutputPath "nfs_summary_${timestamp}.html"
$csv = Import-Csv -Path $changeLogCsv
$html = @"
<html><head><title>NFS Summary</title><style>
body { font-family: Arial; margin: 20px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
th { background-color: #f2f2f2; }
.compliant { background-color: #d4edda; }
.changed { background-color: #fff3cd; }
.dryrun { background-color: #fce4ec; }
.error { background-color: #f8d7da; }
.unknown { background-color: #eeeeee; }
</style></head><body>
<h1>ESXi NFS Best Practices Summary</h1>
<p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<table>
<tr><th>Timestamp</th><th>Host</th><th>Setting</th><th>Old Value</th><th>New Value</th><th>Result</th></tr>
"@
foreach ($entry in $csv) {
    $result = $entry.Result.ToLower().Trim()
    $css = switch -Wildcard ($result) {
        '*compliant*' { 'compliant'; break }
        '*updated*'   { 'changed';   break }
        '*dryrun*'    { 'dryrun';    break }
        '*error*'     { 'error';     break }
        '*missing*'   { 'error';     break }
        default       { 'unknown' }
    }
    $html += "<tr class='$css'><td>$($entry.Timestamp)</td><td>$($entry.HostName)</td><td>$($entry.Setting)</td><td>$($entry.OldValue)</td><td>$($entry.NewValue)</td><td>$($entry.Result)</td></tr>`n"
}
$html += "</table></body></html>"
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "📄 HTML summary exported to: $htmlPath" -ForegroundColor Cyan

# Final summary
Write-Host "`n✅ NFS best practices configuration complete." -ForegroundColor Cyan
Write-Host "📄 Changes CSV:     $changeLogCsv" -ForegroundColor Cyan
Write-Host "📄 Baseline CSV:    $baselineCsv" -ForegroundColor Cyan
Write-Host "📄 Log file (TXT):  $textLogPath" -ForegroundColor Cyan
Write-Host "🌐 HTML Summary:    $htmlPath" -ForegroundColor Cyan
