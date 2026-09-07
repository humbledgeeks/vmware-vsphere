<#
.SYNOPSIS
    Enables and starts the SSH service on a target ESXi host.
.DESCRIPTION
    Sets the SSH service (TSM-SSH) policy to "on", restarts the service to
    ensure it is running, and suppresses the shell warning banner on the host.
    This script is intended to be called from a parent script that has already
    set the $vmhost variable (e.g. via Get-VMHost) and established a vCenter
    connection. It does not connect or disconnect on its own.
.NOTES
    Author  : humbledgeeks-allen
    Date    : 2026-03-16
    Version : 1.0
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
    Warning : Enabling SSH increases the attack surface — disable SSH again after
              completing administrative tasks in production environments.
    Prereq  : $vmhost must be set by the calling script before invoking this file.
#>

##Enable SSH##
Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"} | Set-VMHostService -policy "on" -Confirm:$false
Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"} | Restart-VMHostService -Confirm:$false
Get-VMHost $VMHost | Get-AdvancedSetting UserVars.SuppressShellWarning | Set-AdvancedSetting -Value 1 -Confirm:$false
