# vmware-vsphere

Reusable **VMware** automation, organised by product. Each product folder contains `powershell/`
(PowerCLI) and/or `ansible/` (`community.vmware` or `uri`). See the README in each product
folder for details and prerequisites.

## Contents

| Product | Read-only | Change-making (all support review: dry-run, `-WhatIf`, interactive confirmation or CSV-driven explicit input) |
|---|---|---|
| `esxi/` | `nfs/Get-NfsDatastoreReport.ps1`; Pester tests in `nfs/Tests/` | `hardening/ESXi_Hardening_V6i.ps1` (menu, dry-run, HTML report), `hardening/Regenerate_ESXi_Host_Certificates_Interactive_v1.1.ps1`, `host-config/Configure_ESX_Hosts_v2.ps1`, `host-config/configure_hosts*.ps1` (CSV-driven), `host-config/EnableSSH.ps1`, `host-config/backup_esxihost_config_v2.ps1` (writes backups locally), `nfs/ESXI_NFS_BestPracticesV4.ps1` (dry-run), `nfs/Set-NfsDatastoreMount.ps1` (CSV-driven), `nfs/NetAppVIB_Installation.ps1` (`-WhatIf`) |
| `vcenter/` | `ansible/vcenter-gather-inventory.yml`; `powershell/asbuiltreport/` (AsBuiltReport.VMware.vSphere configuration sample + HOWTO) | — |
| `nsx/` | `powershell/get-nsx-segments.ps1`, `ansible/nsx-gather-segments.yml` (NSX-T Policy API) | — |
| `vsan/` | `powershell/get-vsan-health.ps1`, `ansible/vsan-cluster-info.yml` | — |

## Prerequisites

- PowerShell 5.1/7 with `Install-Module VMware.PowerCLI`.
- Ansible with `ansible-galaxy collection install community.vmware`; playbooks run with `--ask-vault-pass` and `group_vars/all/vault.yml` built from the provided `vault.yml.example`.

## Environment-specific configuration

Host lists, CSV inputs and site defaults are supplied by the caller; the sample/example files in
this repository contain placeholders only. Lab inventories, lab CSVs, lab-default scripts, the
NetApp VIB binary and the third-party vLab platform from the previous tree are kept outside this
repository.

## Credentials and safety

No credentials are stored in this repository. PowerShell scripts prompt (`Get-Credential`) or read
environment variables; Ansible playbooks expect an Ansible Vault (`--ask-vault-pass`) providing the
`vault_*` variables named in `group_vars`. Never commit vault files, Clixml exports or `.env` files
(see `.gitignore`). Run output (reports, CSV, logs) is generated content and is git-ignored; keep it
outside the repository.

## Provenance

Consolidated from previous local automation repositories during the 2026 LabOps repository
cleanup. This repository starts with a fresh history; earlier history is retained locally only.
