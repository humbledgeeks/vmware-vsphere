# VMware ESXi — NFS Scripts

PowerShell scripts for inventorying NFS datastores, applying NetApp NFS best-practice advanced settings, mounting/unmounting NFS datastores at scale, and installing the NetApp VAAI VIB.

See the parent [VMware/ESXi/PowerShell/README.md](../README.md) for prerequisites, installation, and credential setup.

---

## Scripts in This Folder

| Script | Description | Destructive |
| --- | --- | --- |
| `Get-NfsDatastoreReport.ps1` | Inventory NFS datastores across hosts; CSV + HTML report with mount-consistency check | No |
| `ESXI_NFS_BestPracticesV4.ps1` | Apply NetApp NFS best-practice advanced settings — V5 with `-WhatIf` and HTML report | Yes |
| `Set-NfsDatastoreMount.ps1` | Mount or unmount NFS datastores across hosts from a CSV definition | Yes |
| `NetAppVIB_Installation.ps1` | Install NetApp NFS VAAI VIB (NetAppNasPlugin) with `-WhatIf` and HTML summary | Yes |

All four scripts share the same parameter shape: `-OutputPath`, `-Credential`, `-Username`, `-ConnectionMode`, `-vCenter`, `-Cluster`, `-VMHost`, `-HostCsvPath`. Destructive scripts add `[CmdletBinding(SupportsShouldProcess)]` so `-WhatIf` works.

---

## Prerequisites (one-time)

```powershell
# Install VMware PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser -Force

# Trust self-signed certs in your lab (skip in prod)
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

# Install Pester (only if you want to run the smoke tests)
Install-Module Pester -Scope CurrentUser -Force
```

---

## Authentication

Credentials resolve in this order:

1. `-Credential` parameter (PSCredential)
2. `$env:VCENTER_PASSWORD` + `$env:VCENTER_USER` (or `-Username` parameter; defaults to `root`)
3. Interactive `Get-Credential` prompt

**A. Pass `-Credential` directly (good for interactive sessions)**

```powershell
$cred = Get-Credential
.\Get-NfsDatastoreReport.ps1 -Credential $cred -vCenter vc01.lab -Cluster Prod-01
```

**B. Environment variables (good for scheduled tasks / CI)**

```powershell
$env:VCENTER_USER     = 'svc-automation@vsphere.local'
$env:VCENTER_PASSWORD = 'YourPassword'
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01
```

**C. No params — script prompts you**

```powershell
.\Get-NfsDatastoreReport.ps1     # interactive Get-Credential + menu
```

> **Security note:** `NetAppVIB_Installation.ps1` no longer accepts passwords in CSV rows. Supply credentials via `-Credential` or `$env:VCENTER_PASSWORD`.

---

## Quick Start

```powershell
# Audit NFS datastores (read-only)
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01

# Apply best-practice advanced settings (dry-run)
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# Apply best-practice advanced settings (real run)
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01

# Mount NFS datastores from CSV (dry-run)
.\Set-NfsDatastoreMount.ps1 -Action Mount -DatastoreCsvPath .\nfs.csv -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# Install NetApp VAAI VIB (dry-run)
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib -WhatIf
```

---

## Script-by-Script Usage

### `Get-NfsDatastoreReport.ps1` — read-only audit (run this first)

Inventories every NFS datastore across your hosts and flags any datastore mounted on some hosts in a cluster but not others.

```powershell
# vCenter, single cluster
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01

# vCenter, all hosts (leave -Cluster off)
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab

# Standalone hosts
.\Get-NfsDatastoreReport.ps1 -ConnectionMode Standalone -VMHost esx01.lab,esx02.lab

# From a CSV list (CSV needs a HostName column)
.\Get-NfsDatastoreReport.ps1 -ConnectionMode Csv -HostCsvPath .\hosts.csv

# Custom output location
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01 -OutputPath D:\Reports\NFS
```

**Output:** `NfsDatastoreReport_<timestamp>.csv` and `.html` in `C:\ESXi_Hardening` (default).

---

### `ESXI_NFS_BestPracticesV4.ps1` — apply 11 NetApp NFS settings

**Always run with `-WhatIf` first** to see what would change.

```powershell
# Preview only — makes no changes
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# Apply for real
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01

# Apply with per-change confirmation prompt
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01 -Confirm

# Standalone hosts
.\ESXI_NFS_BestPracticesV4.ps1 -ConnectionMode Standalone -VMHost esx01.lab -WhatIf
```

**Output (in `C:\ESXi_Hardening` by default):**
- `NFS_AdvancedSettings_Baseline_*.csv` — what each setting was before
- `NFS_AdvancedSettings_Changes_*.csv` — what was changed/skipped/dry-run
- `NFS_AdvancedSettings_Log_*.txt` — readable log
- `nfs_summary_*.html` — color-coded HTML summary

---

### `Set-NfsDatastoreMount.ps1` — mount/unmount NFS datastores at scale

Reads a datastore CSV and mounts or unmounts each datastore on the listed hosts.

**Step 1: Create your datastore CSV** (e.g. `nfs.csv`):

```csv
DatastoreName,NfsServer,NfsPath,Hosts
shared-iso,nas01.lab,/vol/iso,*
shared-vm01,nas01.lab,/vol/vm01,esx01.lab;esx02.lab
```

- `Hosts = *` → all hosts in `-Cluster`
- `Hosts = host1;host2` → semicolon-separated explicit list

**Step 2: Run it**

```powershell
# Mount — always dry-run first
.\Set-NfsDatastoreMount.ps1 -Action Mount -DatastoreCsvPath .\nfs.csv `
    -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# Mount for real
.\Set-NfsDatastoreMount.ps1 -Action Mount -DatastoreCsvPath .\nfs.csv `
    -vCenter vc01.lab -Cluster Prod-01

# Unmount (refuses to unmount datastores with powered-on VMs)
.\Set-NfsDatastoreMount.ps1 -Action Unmount -DatastoreCsvPath .\nfs.csv `
    -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# Unmount with powered-on VMs — DANGEROUS, requires -Force
.\Set-NfsDatastoreMount.ps1 -Action Unmount -DatastoreCsvPath .\nfs.csv `
    -vCenter vc01.lab -Cluster Prod-01 -Force
```

**Output:** `NfsMountOperations_<Mount|Unmount>_<timestamp>.csv` in `C:\ESXi_Hardening`.

---

### `NetAppVIB_Installation.ps1` — install the NetApp NAS Plugin VIB

Pre-stage the VIB on a datastore or local path first. The script checks if the VIB is already installed on each host before attempting install.

```powershell
# vCenter — VIB on a shared datastore (always WhatIf first)
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 `
    -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib -WhatIf

# Install for real
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 `
    -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib

# Using -DatastoreName + -VibFile (script builds the path)
.\NetAppVIB_Installation.ps1 -ConnectionMode Datastore `
    -DatastoreName ISO -VibFile NetAppNasPlugin.vib `
    -VMHost esx01.lab,esx02.lab

# CSV mode — CSV has Host column (and optional VIBPath, FQDN)
.\NetAppVIB_Installation.ps1 -ConnectionMode Csv -HostCsvPath .\hosts.csv `
    -VibPath /tmp/NetAppNasPlugin.vib

# Auto-open the HTML report at the end
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 `
    -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib -OpenHtmlReport
```

> **Note:** Some hosts report `RebootRequired = Yes` after install. Check the HTML summary and reboot via your normal maintenance workflow.

**Output (in `C:\VAAI_VIB_Install` by default):**
- `vaai_vib_install_<timestamp>.csv` — audit log
- `vaai_vib_summary_<timestamp>.html` — color-coded HTML summary

---

## Recommended Workflow for a New Cluster

```powershell
# 1. Set creds once
$env:VCENTER_USER     = 'svc-automation@vsphere.local'
$env:VCENTER_PASSWORD = 'YourPassword'

# 2. Audit what's there
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01

# 3. Preview best-practice settings
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01 -WhatIf

# 4. Apply best-practice settings
.\ESXI_NFS_BestPracticesV4.ps1 -vCenter vc01.lab -Cluster Prod-01

# 5. Preview VIB install
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 `
    -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib -WhatIf

# 6. Install VIB
.\NetAppVIB_Installation.ps1 -vCenter vc01.lab -Cluster Prod-01 `
    -VibPath /vmfs/volumes/ISO/NetAppNasPlugin.vib

# 7. Re-audit to confirm settings stuck
.\Get-NfsDatastoreReport.ps1 -vCenter vc01.lab -Cluster Prod-01
```

---

## CSV Formats

### Host list (`-HostCsvPath`) — used by all 4 scripts in Csv mode

```csv
HostName
esx01.lab.example.com
esx02.lab.example.com
```

### Datastore definitions (`-DatastoreCsvPath`) — used by `Set-NfsDatastoreMount.ps1`

```csv
DatastoreName,NfsServer,NfsPath,Hosts
shared-iso,nas01.lab,/vol/iso,*
shared-vm01,nas01.lab,/vol/vm01,esx01.lab;esx02.lab
```

`Hosts = *` expands to all hosts in `-Cluster`. Otherwise use a semicolon-separated FQDN list.

---

## NFS Settings Applied by `ESXI_NFS_BestPracticesV4.ps1`

| Setting | Recommended Value |
| --- | --- |
| `Net.TcpipHeapSize` | 32 |
| `Net.TcpipHeapMax` | 1024 |
| `NFS.MaxVolumes` | 256 |
| `NFS41.MaxVolumes` | 256 |
| `NFS.MaxQueueDepth` | 128 |
| `NFS.HeartbeatMaxFailures` | 10 |
| `NFS.HeartbeatFrequency` | 12 |
| `NFS.HeartbeatTimeout` | 5 |
| `Disk.QFullSampleSize` | 32 |
| `Disk.QFullThreshold` | 8 |
| `SunRPC.MaxConnPerIP` | 128 |

---

## VAAI VIB

The `NetAppNasPlugin` VIB enables hardware-accelerated NFS operations (full copy, space reservation) on NetApp storage. Pre-stage the VIB file on a datastore or local path accessible to the target hosts before running `NetAppVIB_Installation.ps1`. The repository ships a copy (`NetAppNasPlugin_2.0.1-16.vib`) for reference.

---

## Running Tests

Smoke tests verify that scripts parse, expose the expected parameters, declare `SupportsShouldProcess` where applicable, and do not regress the CSV-password security fix. They do not require a live ESXi.

```powershell
# Install Pester if needed
Install-Module Pester -Scope CurrentUser -Force

Invoke-Pester ./NFS/Tests -Output Detailed
```

---

## Output Locations

By default, all scripts write reports to `C:\ESXi_Hardening` (or `C:\VAAI_VIB_Install` for the VIB installer). Override with `-OutputPath`.

| File pattern | Producer |
| --- | --- |
| `NfsDatastoreReport_*.{csv,html}` | `Get-NfsDatastoreReport.ps1` |
| `NFS_AdvancedSettings_{Changes,Baseline,Log}_*.{csv,txt}`, `nfs_summary_*.html` | `ESXI_NFS_BestPracticesV4.ps1` |
| `NfsMountOperations_{Mount,Unmount}_*.csv` | `Set-NfsDatastoreMount.ps1` |
| `vaai_vib_install_*.csv`, `vaai_vib_summary_*.html` | `NetAppVIB_Installation.ps1` |

---

## Tips

- **Get full help for any script** — `Get-Help .\Get-NfsDatastoreReport.ps1 -Full`
- **List its parameters** — `Get-Help .\Get-NfsDatastoreReport.ps1 -Parameter *`
- **Both connection menus still work** if you call a script with no `-ConnectionMode`, so you can run them interactively the old way too.
- **`-WhatIf` works on all three destructive scripts** (`ESXI_NFS_BestPracticesV4`, `Set-NfsDatastoreMount`, `NetAppVIB_Installation`). Use it.
