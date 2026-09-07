<#
.SYNOPSIS
    Mount or unmount NFS datastores across ESXi hosts from a CSV definition.
.DESCRIPTION
    Reads a datastore CSV (DatastoreName, NfsServer, NfsPath, Hosts) and either mounts or unmounts
    each datastore on the specified hosts. Supports -WhatIf. For unmounts, refuses to proceed if
    powered-on VMs are registered on the datastore unless -Force is supplied.

    Hosts column accepts:
      *                       -> all hosts in -Cluster (when ConnectionMode = vCenter)
      host1.fqdn;host2.fqdn   -> semicolon-separated explicit list

    Credentials resolve in this order:
      1. -Credential parameter (PSCredential)
      2. $env:VCENTER_PASSWORD + $env:VCENTER_USER (or -Username)
      3. Interactive Get-Credential prompt
.PARAMETER Action
    Mount or Unmount.
.PARAMETER DatastoreCsvPath
    Path to the datastore-definition CSV.
.PARAMETER OutputPath
    Directory for the CSV audit log. Defaults to C:\ESXi_Hardening.
.PARAMETER Credential
    PSCredential for vCenter authentication.
.PARAMETER Username
    Username for env-var auth fallback. Defaults to $env:VCENTER_USER, then 'root'.
.PARAMETER vCenter
    vCenter Server FQDN (required for resolving Hosts='*' against a cluster).
.PARAMETER Cluster
    Cluster name used to expand Hosts='*'.
.PARAMETER Force
    Allow unmounting datastores that have powered-on VMs registered. Use with extreme caution.
.EXAMPLE
    .\Set-NfsDatastoreMount.ps1 -Action Mount -DatastoreCsvPath .\nfs.csv -vCenter vc01.lab -Cluster Prod-01 -WhatIf
.EXAMPLE
    .\Set-NfsDatastoreMount.ps1 -Action Unmount -DatastoreCsvPath .\nfs.csv -vCenter vc01.lab -Cluster Prod-01
.NOTES
    Author  : Allen Johnson
    Date    : 2026-05-14
    Version : 1.0
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
    Warning : Unmount is destructive and impacts running VMs if -Force is used. Always run -WhatIf first.

    CSV columns:
      DatastoreName,NfsServer,NfsPath,Hosts
      shared-iso,nas01.lab,/vol/iso,*
      shared-vm01,nas01.lab,/vol/vm01,esx01.lab;esx02.lab
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Mount', 'Unmount')][string]$Action,
    [Parameter(Mandatory)][string]$DatastoreCsvPath,
    [Parameter()][string]$OutputPath = 'C:\ESXi_Hardening',
    [Parameter()][System.Management.Automation.PSCredential]$Credential,
    [Parameter()][string]$Username,
    [Parameter()][string]$vCenter,
    [Parameter()][string]$Cluster,
    [Parameter()][switch]$Force
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
    return Get-Credential -Message 'Enter vCenter credentials'
}

if (-not (Test-Path $DatastoreCsvPath)) { throw "CSV not found at $DatastoreCsvPath" }
$entries = Import-Csv -Path $DatastoreCsvPath
foreach ($col in 'DatastoreName', 'NfsServer', 'NfsPath', 'Hosts') {
    if (-not ($entries | Get-Member -Name $col -ErrorAction SilentlyContinue)) {
        throw "CSV is missing required column '$col'."
    }
}

if (-not $vCenter) { $vCenter = Read-Host "Enter vCenter Server" }
$cred = Resolve-PowerCLICredential -Credential $Credential -Username $Username

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$auditCsv = Join-Path $OutputPath "NfsMountOperations_${Action}_${timestamp}.csv"

$viserver = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
try {
    $clusterHosts = @()
    if ($Cluster) { $clusterHosts = Get-Cluster -Name $Cluster | Get-VMHost }

    $results = foreach ($entry in $entries) {
        $dsName    = $entry.DatastoreName
        $nfsServer = $entry.NfsServer
        $nfsPath   = $entry.NfsPath
        $hostsSpec = $entry.Hosts

        $targetHosts = if ($hostsSpec.Trim() -eq '*') {
            if (-not $clusterHosts) { throw "Hosts='*' requires -Cluster to be specified." }
            $clusterHosts
        } else {
            $names = $hostsSpec -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($n in $names) { Get-VMHost -Name $n -ErrorAction Stop }
        }

        foreach ($vmhost in $targetHosts) {
            $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $status = 'PENDING'
            $message = ''

            try {
                $existing = Get-Datastore -VMHost $vmhost -Name $dsName -ErrorAction SilentlyContinue

                switch ($Action) {
                    'Mount' {
                        if ($existing) {
                            $status = 'ALREADY MOUNTED'
                        } elseif ($PSCmdlet.ShouldProcess("$($vmhost.Name)", "Mount NFS datastore $dsName ($nfsServer`:$nfsPath)")) {
                            New-Datastore -Nfs -VMHost $vmhost -Name $dsName -NfsHost $nfsServer -Path $nfsPath -ErrorAction Stop | Out-Null
                            $status = 'MOUNTED'
                        } else {
                            $status = 'DRY-RUN'
                        }
                    }
                    'Unmount' {
                        if (-not $existing) {
                            $status = 'NOT MOUNTED'
                        } else {
                            $poweredOnVMs = @(Get-VM -Datastore $existing -ErrorAction SilentlyContinue |
                                Where-Object { $_.PowerState -eq 'PoweredOn' -and $_.VMHost.Name -eq $vmhost.Name })
                            if ($poweredOnVMs.Count -gt 0 -and -not $Force) {
                                $status = 'SKIPPED'
                                $message = "Powered-on VMs registered on $dsName via $($vmhost.Name): $($poweredOnVMs.Name -join ', '). Use -Force to override."
                            } elseif ($PSCmdlet.ShouldProcess("$($vmhost.Name)", "Unmount NFS datastore $dsName")) {
                                Remove-Datastore -Datastore $existing -VMHost $vmhost -Confirm:$false -ErrorAction Stop
                                $status = 'UNMOUNTED'
                                if ($poweredOnVMs.Count -gt 0) { $message = "Forced unmount with $($poweredOnVMs.Count) powered-on VMs." }
                            } else {
                                $status = 'DRY-RUN'
                            }
                        }
                    }
                }
            } catch {
                $status = 'ERROR'
                $message = $_.Exception.Message
            }

            $color = switch ($status) {
                'MOUNTED'         { 'Green' }
                'UNMOUNTED'       { 'Green' }
                'ALREADY MOUNTED' { 'Yellow' }
                'NOT MOUNTED'     { 'Yellow' }
                'DRY-RUN'         { 'Magenta' }
                'SKIPPED'         { 'Yellow' }
                'ERROR'           { 'Red' }
                default           { 'Gray' }
            }
            Write-Host ("[{0}] {1,-20} {2,-30} -> {3} {4}" -f $time, $vmhost.Name, $dsName, $status, $message) -ForegroundColor $color

            [pscustomobject]@{
                Timestamp = $time
                Action    = $Action
                VMHost    = $vmhost.Name
                Datastore = $dsName
                NfsServer = $nfsServer
                NfsPath   = $nfsPath
                Status    = $status
                Message   = $message
            }
        }
    }

    $results | Export-Csv -Path $auditCsv -NoTypeInformation -Encoding UTF8
    Write-Host "📄 Audit log written to: $auditCsv" -ForegroundColor Cyan
}
finally {
    if ($viserver) { Disconnect-VIServer -Server $viserver -Confirm:$false }
    Write-Host "🔌 Disconnected." -ForegroundColor DarkGray
}
