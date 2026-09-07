# VMware ESXi — Host Configuration Scripts

PowerShell scripts for automating full ESXi host configuration: NTP, DNS, networking, security hardening, NFS settings, and vSwitch layout.

See the parent [VMware/ESXi/PowerShell/README.md](../README.md) for prerequisites, installation, and credential setup.

---

## Scripts in This Folder

| Script | Description |
| --- | --- |
| `backup_esxihost_config_v2.ps1` | Back up ESXi host config bundles with menu, dry-run, log rotation, and HTML summary |
| `Configure_ESX_Hosts_v2.ps1` | Full host config from an Excel workbook: NTP, DNS, hardening, NFS settings, vSwitch layout |
| `configure_hosts.ps1` | CSV-driven host config (first host + remaining hosts) with NTP, DNS, hardening, networking |
| `configure_hosts_addon.ps1` | Add-on / companion CSV-driven host config for additional hosts |
| `EnableSSH.ps1` | Enable SSH service on a target ESXi host |
| `ESXConfiguration.ps1` | Full HPE node configuration for hybriddatacenter.net lab — vCenter add, networking, vMotion |

---

## Quick Start

```powershell

# Back up all host configs from a vCenter cluster

.\backup_esxihost_config_v2.ps1

# Apply full configuration to hosts from CSV

.\configure_hosts.ps1     # processes all hosts in configure_lab_hosts.csv

```text

---

## CSV Format (configure_lab_hosts.csv)

Scripts that read from CSV expect at minimum:

```csv
hostname,mgmtip,NTP1,NTP2,DNS1,DNS2,sw0name,sw0nic0,sw0nic1,...
esxi-01,10.10.1.11,0.pool.ntp.org,1.pool.ntp.org,10.10.1.1,9.9.9.9,vSwitch0,vmnic0,vmnic1,...

```

---

> **Security note:** Legacy scripts in this folder contain hardcoded credentials from lab environments. Run `/script-migrate` on any script before using in production to convert credentials to `Get-Credential` or `Import-Clixml` patterns.
