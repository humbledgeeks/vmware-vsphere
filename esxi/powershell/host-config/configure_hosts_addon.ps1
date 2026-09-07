<#
.SYNOPSIS
    CSV-driven ESXi host configuration add-on: applies NTP, DNS, security hardening, NFS, and networking to all hosts.
.DESCRIPTION
    Companion to configure_hosts.ps1. Reads configure_lab_hosts.csv and iterates all hosts applying the same
    full configuration set: NTP, DNS, security hardening, NFS best-practice settings, vSwitch port groups,
    NFS datastore mount, and scratch location. Intended for applying configuration to additional or remaining hosts
    after initial first-host setup.
.NOTES
    Author  : HumbledGeeks
    Date    : 2023-06-05
    Version : 1.0
    Module  : VMware.PowerCLI
    Prereq  : configure_lab_hosts.csv in the same directory as this script
    Repo    : vmware-esxi-powershell
    WARNING : Contains hardcoded ESXi credentials (hostpass). Replace with Get-Credential before production use.
              Run /script-migrate on this file to update to repo credential standards.
#>
#====================================================================================================================
# 
# AUTHOR: HumbledGeeks  
# DATE  : 06/05/2023
# 
# COMMENT: Script to Automate ESX Host and vCenter Configuration
#     
#
# ====================================================================================================================

#========================================================================================================================
# Specify host credentials
#========================================================================================================================
$hostuser = 'root'
$hostpass = $env:ESXI_HOST_PASSWORD   # supply via environment; never store a password in this file

#========================================================================================================================
# Specify CSV file
#========================================================================================================================
$vmhosts = Import-CSV -Path configure_lab_hosts.csv

$vmhosts| ForEach-Object {$vmhosts.hostname} {
    #====================================================================================================================
	# Connect to each host
	#====================================================================================================================
write-host Connecting to vCenter Server instance -ForegroundColor Yellow
    Connect-VIServer -Server $_.mgmtip -User $hostuser -Password $hostpass
	
	#====================================================================================================================
	# Configure NTP Server and Restart Service
	#====================================================================================================================
write-host Configure NTP Server and Restarting Service -ForegroundColor Yellow
    #Get-VMHost | Add-VMHostNtpServer -NtpServer us.pool.ntp.org
	#Get-VMHost | Add-VMHostNtpServer -NtpServer us.pool.ntp.org
	#Get-VMHost | Add-VMHostNtpServer -NtpServer $_.NTP1, $_.NTP2
	Get-VMHost | Get-VMHostService | Where-Object {$_.Key -eq "ntpd"} | Restart-VMHostService -Confirm:$false
	
	#====================================================================================================================
	# Configure DNS Server
	#====================================================================================================================
write-host Configure DNS Server and Restarting Service -ForegroundColor Yellow
	#Get-VMHost | Get-VMHostNetwork | Set-VMHostNetwork -DnsAddress $_.DNS1, $_.DNS2
	
	#====================================================================================================================
	# Rename Local Datastore (if needed)
	#====================================================================================================================
write-host Rename Local Datastore -ForegroundColor Yellow
	#Get-Datastore -Name datastore1 | Set-Datastore -Name $_.localdatastore

	#====================================================================================================================
	#  Security Hardening Advanced Settings
	#====================================================================================================================
write-host Security Hardening Advanced Settings -ForegroundColor Yellow
	#Set-AdvancedSetting -AdvancedSetting UserVars.SuppressShellWarning -Value 1 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Config.HostAgent.log.level | Set-AdvancedSetting -Value info -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Config.HostAgent.plugins.solo.enableMob | Set-AdvancedSetting -Value False -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Mem.ShareForceSalting | Set-AdvancedSetting -Value 2 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Security.AccountLockFailures | Set-AdvancedSetting -Value 5 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Security.AccountUnlockTime | Set-AdvancedSetting -Value 900 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Security.PasswordHistory | Set-AdvancedSetting -Value 5 -Confirm:$false
	#Get-VMHost | Get-AdvancedSetting -Name Security.PasswordQulityControl | Set-AdvancedSetting -Value "similar=deny retry=3 min=disabled,disabled,disabled,disabled,15" -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name UserVars.DcuiTimeOut | Set-AdvancedSetting -Value 600 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name UserVars.ESXiShellInteractiveTimeOut | Set-AdvancedSetting -Value 900 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name UserVars.ESXiShellTimeOut | Set-AdvancedSetting -Value 900 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name UserVars.ESXiVPsDisabledProtocols | Set-AdvancedSetting -Value "sslv3,tlsv1,tlsv1.1" -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name UserVars.SuppressShellWarning | Set-AdvancedSetting -Value 1 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name VMkernel.Boot.execInstalledOnly | Set-AdvancedSetting -Value True -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Mem.ShareForceSalting | Set-AdvancedSetting -Value 0 -Confirm:$false
	Get-VMHost | Get-AdvancedSetting -Name Misc.BlueScreenTimeout | Set-AdvancedSetting -Value 60 -Confirm:$false

	#====================================================================================================================
	#  NFS Advanced Settings
	#====================================================================================================================
write-host NFS NetApp Best Practices Advanced Settings -ForegroundColor Yellow
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name Net.TcpipHeapSize -Value 32
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name Net.TcpipHeapMax -Value 512
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name NFS.MaxVolumes -Value 256
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name NFS.HeartbeatMaxFailures -Value 10
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name NFS.HeartbeatFrequency -Value 12
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name NFS.HeartbeatTimeout -Value 5
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name NFS.MaxQueueDepth -Value 64
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name Disk.QFullSampleSize -Value 32
	Get-VMHost  | Set-VMHostAdvancedConfiguration -Name Disk.QFullThreshold -Value 8
	Get-VMHost  | Get-AdvancedSetting -Name 'Power.CPUPolicy' | Set-AdvancedSetting -Value 'High Performance' -Confirm:$false
	Get-VMHost  | Get-AdvancedSetting -Name 'Power.CPUPolicy' | Set-AdvancedSetting -Value 'High Performance' -Confirm:$false
	
	#====================================================================================================================
	#  iSCSI Advanced Settings
	#====================================================================================================================
#write-host iSCSI Best Practices Advanced Settings -ForegroundColor Yellow
	#Path selection policy Set value to Round Robin for all Paths
	#Disk.QFullSampleSize set value to 32
	#Disk.QFullThreshold set value to 8
	
	
	#====================================================================================================================
	# Configure local networking
	#====================================================================================================================

	#====================================================================================================================
	# Add Physical Adapter and Edit MTU on vSwitch0 (needed?)
	#====================================================================================================================
write-host Add Physical Adapter on vSwitch0 -ForegroundColor Yellow
	Get-VirtualSwitch -Name $_.sw0name | Add-VirtualSwitchPhysicalNetworkAdapter -VMHostPhysicalNic (Get-VMHostNetworkAdapter -Physical -Name $_.sw0nic1) -Confirm:$false
	
    #====================================================================================================================
	# Create additional vSwitches / Add Physical Adapters / Set MTU
	#====================================================================================================================

	#====================================================================================================================
	# Edit NIC Teaming Policy
	#====================================================================================================================
	Get-VirtualSwitch -Name $_.sw0name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $_.sw0nic0,$_.sw0nic1
	#Get-VirtualSwitch -name $_.sw0name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $_.sw0nic0 -MakeNicStandby $_.sw0nic1
	
	#====================================================================================================================
	# Remove Default VMPG
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | Get-VirtualPortGroup -Name 'VM Network' | Remove-VirtualPortGroup -Confirm:$false
	
	#====================================================================================================================
	# Rename Default Management Network
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | Get-VirtualPortGroup -Name 'Management Network' | Set-VirtualPortGroup -Name $_.mgmtpgname
	
	#====================================================================================================================
	# Add OOB Mgmt VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.oobmpgname -VLanId $_.oobmpgvlan
	
	#====================================================================================================================
	# Add vCenter Mgmt VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.vcenpgname -VLanId $_.vcenpgvlan
	
	#====================================================================================================================
	# Add Nested Labs Mgmt VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.nlabpgname -VLanId $_.nlabpgvlan
	
	#====================================================================================================================
	# Add Core Servers Mgmt VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.corepgname -VLanId $_.corepgvlan
	
	#====================================================================================================================
	# Add vMotion VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.vmopgname -VLanId $_.vmovlan
	
	#====================================================================================================================
	# Add NFS VMPG and VLAN
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.nfspgname -VLanId $_.nfsvlan
	
	#====================================================================================================================
	# Add iSCSI-A VMPG and VLAN & Edit NIC Teaming Policy
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.iscsipg1name -VLanId $_.iscsipg1vlan
	Get-VirtualPortGroup -Name $_.iscsipg1name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $_.sw0nic0 -MakeNicUnused $_.sw0nic1
	
	#====================================================================================================================
	# Add iSCSI-B VMPG and VLAN & Edit NIC Teaming Policy
	#====================================================================================================================
	Get-VirtualSwitch -name $_.sw0name | New-VirtualPortGroup -Name $_.iscsipg2name -VLanId $_.iscsipg2vlan
	Get-VirtualPortGroup -Name $_.iscsipg2name | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $_.sw0nic1 -MakeNicUnused $_.sw0nic0
	
	#====================================================================================================================
	# Configure iSCSI vmk (vmk1 /vmk2)
	#====================================================================================================================
	New-VMHostNetworkAdapter -VirtualSwitch $_.sw0name -PortGroup $_.iscsipg1name -IP $_.iscsi1ip -SubnetMask $_.iscsi1sn
	New-VMHostNetworkAdapter -VirtualSwitch $_.sw0name -PortGroup $_.iscsipg2name -IP $_.iscsi2ip -SubnetMask $_.iscsi2sn
	
	#====================================================================================================================
	# Configure vMotion vmk (vmk3)
	#====================================================================================================================
	New-VMHostNetworkAdapter -VirtualSwitch $_.sw0name -PortGroup $_.vmopgname -IP $_.vmoip -SubnetMask $_.vmosn -VMotionEnabled:$true
	
	#====================================================================================================================
	# Configure NFS vmk (vmk4)
	#====================================================================================================================
	New-VMHostNetworkAdapter -VirtualSwitch $_.sw0name -PortGroup $_.nfspgname -IP $_.nfsip -SubnetMask $_.nfssn
	
	#====================================================================================================================
	# Configure iSCSI Initiator
	#====================================================================================================================
	#Get-VMHostStorage $_.mgmtip | Set-VMHostStorage -SoftwareIScsiEnabled $true
	#New-IScsiHbaTarget -IScsiHba $_.vmhbax -Address $_.iscsitg1ip -Port $_.iscsitg1port
    #New-IScsiHbaTarget -IScsiHba $_.vmhbax -Address $_.iscsitg2ip -Port $_.iscsitg2port
    #New-IScsiHbaTarget -IScsiHba $_.vmhbax -Address $_.iscsitg3ip -Port $_.iscsitg3port
    #New-IScsiHbaTarget -IScsiHba $_.vmhbax -Address $_.iscsitg4ip -Port $_.iscsitg4port
	#$bind1 = @{
	    #adapter = $_.vmhbax
		#force = $true
		#nic = 'vmk1'
	#}
	#$bind2 = @{
		#adapter = $_.vmhbax
		#force = $true
		#nic = 'vmk2'
	#}
	#$esxcli = Get-EsxCli -V2 -VMHost $_.mgmtip
	#$esxcli.iscsi.networkportal.add.Invoke($bind1)
	#$esxcli.iscsi.networkportal.add.Invoke($bind2)
	#Get-VMHostStorage -RescanAllHba -RescanVmfs
	
	#====================================================================================================================
	# Attach NFS Datastore NFS1NAME is Scratch DataStore / 
	#====================================================================================================================
	Get-VMHost  | New-Datastore -Nfs -Name $_.nfs1name  -NfsHost $_.nfstg1ip -Path $_.nfs1path
	#Get-VMHost  | New-Datastore -Nfs -Name $_.nfs2name -Path /$nfs2path -NfsHost $_.nfspg2ip
	#Get-VMHost  | New-Datastore -Nfs -Name $_.nfs2name -Path /$nfs2path -NfsHost $_.nfstg2ip
	
	#====================================================================================================================
	# Configure Scratch Location Datastore
	#====================================================================================================================
	# NEED to create scratch log DataStore 'scratch/esxscratch'
	Get-VMhost | Get-AdvancedSetting -Name "ScratchConfig.ConfiguredScratchLocation" | Set-AdvancedSetting -Value "/vmfs/volumes/NFS_DS001/scratch/esxscratch" -Confirm:$false
	Get-VMhost | Get-AdvancedSetting -Name "Syslog.global.logDirUnique" | Set-AdvancedSetting -Value:$true -Confirm:$false
	
	#====================================================================================================================
	# Disconnect from each host
	#====================================================================================================================
	Disconnect-VIServer $_.mgmtip -Confirm:$false
}