<#
    .SYNOPSIS
        This script automates the initial configuration of ESXi hosts and their vCenter integration.

    .DESCRIPTION
        Rather than hard coding host‑specific values directly in the body of the script, this refactored
        version reads all tunable parameters from an external Excel workbook.  The first row of the
        spreadsheet contains variable names (without the leading '$') and the second row holds the
        corresponding values.  You can find a sample workbook in the repository named
        ``esx_config.xlsx``.  Use the ImportExcel module to parse the workbook.  If the module is
        unavailable on your system, install it via PowerShell Gallery: ``Install-Module -Name ImportExcel``.

        The script caches the VMHost objects up front to avoid repeatedly calling ``Get-VMHost`` and
        removes duplicate or redundant advanced setting calls.  Most operations are batched against
        ``$vmHostsList`` to improve readability.  All interactive confirmations are suppressed via
        ``-Confirm:$false``.

    .NOTES
        Author:  HumbledGeeks
        Updated: 24 July 2025
        Location: La Puente, California, USA (America/Los_Angeles)

    .EXAMPLE
        PS> .\Configure_ESX_Hosts_v2.ps1 -ConfigPath "C:\\path\\to\\esx_config.xlsx"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

# Ensure the ImportExcel module is available
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "ImportExcel module not found. Install it with 'Install-Module -Name ImportExcel'." -ForegroundColor Yellow
    throw "ImportExcel module is required to run this script."
}

<#
    Import configuration from Excel.  Two layouts are supported:
      1. Vertical layout: the first two columns represent the parameter name and its value.
         Additional section headers (e.g., 'ESXi Hosts', 'User / Password') may appear in the first
         column with a blank value.  These rows are ignored.  Rows with non‑empty values are used
         to populate variables.  This approach allows you to customise the label of the first column
         without impacting the import logic.
      2. Horizontal layout: the first row holds variable names and the second row holds values.
         This is retained for backward compatibility.

    The script determines the layout by examining the number of properties returned by Import‑Excel.
    If at least two columns exist, vertical parsing is attempted.  Otherwise the script falls back
    to horizontal parsing.
#>
$configRows = Import-Excel -Path $ConfigPath
if ($configRows.Count -gt 0) {
    $propNames = $configRows[0].PSObject.Properties.Name
    if ($propNames.Count -ge 2) {
        # vertical layout using the first two columns
        $nameCol  = $propNames[0]
        $valueCol = $propNames[1]
        foreach ($row in $configRows) {
            $key   = $row.$nameCol
            $value = $row.$valueCol
            # Skip rows where either the key or value is empty, or the value is a header label like "Value"
            if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value) -or $value -eq 'Value') { continue }
            if ($key -match '^[A-Za-z_]') {
                Set-Variable -Name $key -Value $value
            }
        }
    } else {
        # horizontal layout: first row holds names, second row holds values
        $config = $configRows | Select-Object -First 1
        foreach ($property in $config.PSObject.Properties.Name) {
            if ($property -match '^[A-Za-z_]') {
                Set-Variable -Name $property -Value ($config.$property)
            }
        }
    }
}

# Connect to vCenter or directly to ESXi host(s)
Write-Host "Connecting to vCenter/ESXi hosts..." -ForegroundColor Green
    # Build an array of VMHosts if individual host variables (VMHost1..VMHost8) are present
    $vmHostVariables = Get-Variable -Name 'VMHost?' -ErrorAction SilentlyContinue
    if ($vmHostVariables) {
        $hosts = @()
        foreach ($var in $vmHostVariables) {
            if (-not [string]::IsNullOrWhiteSpace($var.Value)) { $hosts += $var.Value }
        }
        if ($hosts.Count -gt 0) { $VMHosts = $hosts }
    }
    $credential = New-Object System.Management.Automation.PSCredential($esxiuser,(ConvertTo-SecureString -String $esxipass -AsPlainText -Force))
    Connect-VIServer -Server $VMHosts -Credential $credential

# Cache the VMHost collection
$vmHostsList = Get-VMHost

# Helper function to determine if a string is non-empty/non-whitespace
function Test-NotEmpty {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value)
}

###########################################################################
# Configure NTP servers
###########################################################################
Write-Host "Configuring NTP servers..." -ForegroundColor Green
if ((Test-NotEmpty $NTP1) -or (Test-NotEmpty $NTP2)) {
    $ntpServers = @()
    if (Test-NotEmpty $NTP1) { $ntpServers += $NTP1 }
    if (Test-NotEmpty $NTP2) { $ntpServers += $NTP2 }
    foreach ($esxHost in $vmHostsList) {
        $existing = Get-VMHostNtpServer -VMHost $esxHost -ErrorAction SilentlyContinue
        # Determine which servers are missing on this host
        $missing = $ntpServers | Where-Object { $_ -notin $existing }
        if ($missing.Count -gt 0) {
            Write-Host ("[{0}] Missing NTP servers: {1}" -f $esxHost.Name, ($missing -join ', ')) -ForegroundColor Yellow
            $esxHost | Add-VMHostNtpServer -NtpServer $missing
            $esxHost | Get-VMHostService | Where-Object { $_.Key -eq 'ntpd' } | Restart-VMHostService -Confirm:$false
            Write-Host ("[{0}] NTP servers configured." -f $esxHost.Name) -ForegroundColor Green
        } else {
            Write-Host ("[{0}] All desired NTP servers already configured." -f $esxHost.Name) -ForegroundColor Green
        }
    }
} else {
    Write-Host "Skipping NTP configuration – no NTP servers defined." -ForegroundColor Yellow
}

###########################################################################
# Configure DNS and domain settings
###########################################################################
Write-Host "Configuring DNS and domain settings..." -ForegroundColor Green
if ((Test-NotEmpty $domainname) -or (Test-NotEmpty $DNS1) -or (Test-NotEmpty $DNS2)) {
    $dnsServers = @()
    if (Test-NotEmpty $DNS1) { $dnsServers += $DNS1 }
    if (Test-NotEmpty $DNS2) { $dnsServers += $DNS2 }
    foreach ($esxHost in $vmHostsList) {
        $net = $esxHost | Get-VMHostNetwork
        $currentDns    = $net.DnsAddress
        $currentDomain = $net.DomainName
        # Determine if DNS/domain need updating
        $dnsMismatch = $false
        if ($dnsServers.Count -gt 0) {
            $missingDns = $dnsServers | Where-Object { $_ -notin $currentDns }
            if ($missingDns.Count -gt 0 -or $currentDns.Count -gt $dnsServers.Count) { $dnsMismatch = $true }
        }
        $domainMismatch = $false
        if (Test-NotEmpty $domainname) {
            if ($currentDomain -ne $domainname) { $domainMismatch = $true }
        }
        if ($dnsMismatch -or $domainMismatch) {
            Write-Host ("[{0}] Updating DNS/domain settings." -f $esxHost.Name) -ForegroundColor Yellow
            $esxHost | Get-VMHostNetwork | Set-VMHostNetwork -DomainName $domainname -DNSAddress $dnsServers -Confirm:$false
            Write-Host ("[{0}] DNS/domain configured." -f $esxHost.Name) -ForegroundColor Green
        } else {
            Write-Host ("[{0}] DNS/domain already configured." -f $esxHost.Name) -ForegroundColor Green
        }
    }
} else {
    Write-Host "Skipping DNS/Domain configuration – no DNS servers or domain specified." -ForegroundColor Yellow
}

###########################################################################
# Apply security hardening advanced settings
###########################################################################
Write-Host "Applying security hardening settings..." -ForegroundColor Green
$advancedSettings = @{
    'Config.HostAgent.log.level'             = 'info';
    'Config.HostAgent.plugins.solo.enableMob' = $false;
    'Mem.ShareForceSalting'                  = 2;
    'Security.AccountLockFailures'           = 5;
    'Security.AccountUnlockTime'             = 900;
    'Security.PasswordHistory'               = 5;
    'UserVars.DcuiTimeOut'                   = 600;
    'UserVars.ESXiShellInteractiveTimeOut'   = 900;
    'UserVars.ESXiShellTimeOut'              = 900;
    'UserVars.ESXiVPsDisabledProtocols'      = 'sslv3,tlsv1,tlsv1.1';
    'UserVars.SuppressShellWarning'          = 1;
    'VMkernel.Boot.execInstalledOnly'        = $true;
    'Misc.BlueScreenTimeout'                 = 60
}

foreach ($setting in $advancedSettings.GetEnumerator()) {
    $vmHostsList | Get-AdvancedSetting -Name $setting.Key | Set-AdvancedSetting -Value $setting.Value -Confirm:$false
}

# Ensure the power policy is set to High Performance
$vmHostsList | Get-AdvancedSetting -Name 'Power.CPUPolicy' | Set-AdvancedSetting -Value 'High Performance' -Confirm:$false

###########################################################################
# Apply NetApp NFS best practice advanced settings
###########################################################################
Write-Host "Applying NetApp NFS best practice settings..." -ForegroundColor Green
$nfsSettings = @{
    'Net.TcpipHeapSize'          = 32;
    'Net.TcpipHeapMax'           = 512;
    'NFS.MaxVolumes'             = 256;
    'NFS.HeartbeatMaxFailures'   = 10;
    'NFS.HeartbeatFrequency'     = 12;
    'NFS.HeartbeatTimeout'       = 5;
    'NFS.MaxQueueDepth'          = 64;
    'Disk.QFullSampleSize'       = 32;
    'Disk.QFullThreshold'        = 8
}

foreach ($setting in $nfsSettings.GetEnumerator()) {
    $vmHostsList | Set-VMHostAdvancedConfiguration -Name $setting.Key -Value $setting.Value
}

###########################################################################
# Networking configuration
###########################################################################
Write-Host "Configuring virtual networking..." -ForegroundColor Green

# Add secondary uplink to vSwitch0
Get-VirtualSwitch -Name $sw0name | Add-VirtualSwitchPhysicalNetworkAdapter -VMHostPhysicalNic (Get-VMHostNetworkAdapter -Physical -Name $sw0nic1) -Confirm:$false

# Configure NIC teaming for vSwitch0
Get-VirtualSwitch -Name $sw0name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $sw0nic0,$sw0nic1

# Remove default port group and rename Management Network
Get-VirtualSwitch -Name $sw0name | Get-VirtualPortGroup -Name 'VM Network' | Remove-VirtualPortGroup -Confirm:$false
Get-VirtualSwitch -Name $sw0name | Get-VirtualPortGroup -Name 'Management Network' | Set-VirtualPortGroup -Name $mgmtpgname

# Create additional port groups with VLAN assignments
@(
    @{Name=$oobmpgname;  VlanId=$oobmpgvlan},
    @{Name=$vcenpgname;  VlanId=$vcenpgvlan},
    @{Name=$nlabpgname;  VlanId=$nlabpgvlan},
    @{Name=$corepgname;  VlanId=$corepgvlan},
    @{Name=$vmopgname;   VlanId=$vmovlan},
    @{Name=$nfspgname;   VlanId=$nfsvlan},
    @{Name=$iscsipg1name;VlanId=$iscsipg1vlan},
    @{Name=$iscsipg2name;VlanId=$iscsipg2vlan}
) | Where-Object { (Test-NotEmpty $_.Name) -and (Test-NotEmpty $_.VlanId) } | ForEach-Object {
    foreach ($esxHost in $vmHostsList) {
        $vSwitch = Get-VirtualSwitch -VMHost $esxHost -Name $sw0name
        $existingPG = $vSwitch | Get-VirtualPortGroup -Name $_.Name -ErrorAction SilentlyContinue
        if ($null -eq $existingPG) {
            Write-Host ("[{0}] Creating port group {1} (VLAN {2})" -f $esxHost.Name, $_.Name, $_.VlanId) -ForegroundColor Yellow
            $vSwitch | New-VirtualPortGroup -Name $_.Name -VLanId $_.VlanId -Confirm:$false
            Write-Host ("[{0}] Port group {1} created." -f $esxHost.Name, $_.Name) -ForegroundColor Green
        } else {
            Write-Host ("[{0}] Port group {1} already exists." -f $esxHost.Name, $_.Name) -ForegroundColor Green
        }
    }
}

# iSCSI specific NIC teaming policies
if (Test-NotEmpty $iscsipg1name) {
    Get-VirtualPortGroup -Name $iscsipg1name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $sw0nic0 -MakeNicUnused $sw0nic1
}
if (Test-NotEmpty $iscsipg2name) {
    Get-VirtualPortGroup -Name $iscsipg2name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $sw0nic1 -MakeNicUnused $sw0nic0
}

# Create VMkernel adapters for iSCSI
if ((Test-NotEmpty $iscsipg1name) -and (Test-NotEmpty $iscsi1ip) -and (Test-NotEmpty $iscsi1sn)) {
    New-VMHostNetworkAdapter -VirtualSwitch $sw0name -PortGroup $iscsipg1name -IP $iscsi1ip -SubnetMask $iscsi1sn
}
if ((Test-NotEmpty $iscsipg2name) -and (Test-NotEmpty $iscsi2ip) -and (Test-NotEmpty $iscsi2sn)) {
    New-VMHostNetworkAdapter -VirtualSwitch $sw0name -PortGroup $iscsipg2name -IP $iscsi2ip -SubnetMask $iscsi2sn
}

# Configure vMotion netstack and VMkernel
Write-Host "Configuring vMotion network stack..." -ForegroundColor Green
if ((Test-NotEmpty $vmopgname) -and (Test-NotEmpty $vmoip) -and (Test-NotEmpty $vmosn)) {
    foreach ($esxHost in $vmHostsList) {
        $esxcli = Get-EsxCli -VMHost $esxHost -V2
        $esxcli.network.ip.netstack.add.Invoke(@{ netstack = 'vmotion' })
        $esxcli.network.ip.interface.add.Invoke(@{ interfacename = 'vmk3'; portgroupname = $vmopgname; netstack = 'vmotion' })
        $esxcli.network.ip.interface.ipv4.set.Invoke(@{ interfacename = 'vmk3'; ipv4 = $vmoip; netmask = $vmosn; type = 'static' })
    }
} else {
    Write-Host "Skipping vMotion configuration – missing port group name or IP settings." -ForegroundColor Yellow
}

# Create NFS VMkernel adapter
if ((Test-NotEmpty $nfspgname) -and (Test-NotEmpty $nfsip) -and (Test-NotEmpty $nfssn)) {
    New-VMHostNetworkAdapter -VirtualSwitch $sw0name -PortGroup $nfspgname -IP $nfsip -SubnetMask $nfssn
} else {
    Write-Host "Skipping NFS VMkernel configuration – missing port group or IP settings." -ForegroundColor Yellow
}

# Mount NFS datastore(s)
Write-Host "Mounting NFS datastores..." -ForegroundColor Green
if ((Test-NotEmpty $nfs1name) -and (Test-NotEmpty $nfstg1ip) -and (Test-NotEmpty $nfs1path)) {
    $vmHostsList | New-Datastore -Nfs -Name $nfs1name -NfsHost $nfstg1ip -Path $nfs1path
} else {
    Write-Host "Skipping NFS datastore mount – missing datastore name, host IP or path." -ForegroundColor Yellow
}

# Configure scratch location and unique log directory
Write-Host "Configuring scratch location and syslog settings..." -ForegroundColor Green
if (Test-NotEmpty $nfs1name) {
    $vmHostsList | Get-AdvancedSetting -Name "ScratchConfig.ConfiguredScratchLocation" | Set-AdvancedSetting -Value ("/vmfs/volumes/{0}/scratch/esxscratch" -f $nfs1name) -Confirm:$false
    $vmHostsList | Get-AdvancedSetting -Name "Syslog.global.logDirUnique" | Set-AdvancedSetting -Value $true -Confirm:$false
} else {
    Write-Host "Skipping scratch/log configuration – NFS datastore name not defined." -ForegroundColor Yellow
}

# Disconnect gracefully
Write-Host "Disconnecting from vCenter/ESXi hosts..." -ForegroundColor Green
Disconnect-VIServer $VMHosts -Confirm:$false