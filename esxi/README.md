# ESXi

Automation for VMware ESXi host management — security hardening, host configuration, and NFS datastore management — in both PowerShell (PowerCLI) and Ansible (`community.vmware`).

## Contents

| Path | Purpose |
|------|---------|
| `powershell/hardening/` | ESXi security hardening (VMware SCG), password and certificate lifecycle tools |
| `powershell/host-config/` | Host baseline configuration scripts and data files |
| `powershell/nfs/` | NFS datastore and NetApp VIB management, with Pester tests |
| `ansible/HDC/` | Playbooks and inventory for the HDC environment |
| `ansible/Humbled/` | Playbooks and inventory for the Humbled lab environment |

## Prerequisites

- PowerShell 5.1+ or 7+ with VMware PowerCLI: `Install-Module VMware.PowerCLI`
- Ansible with the `community.vmware` collection

## Credentials

No secrets live in this tree. PowerShell scripts read passwords from environment variables (`$env:VCENTER_PASSWORD`, `$env:ADJOIN_PASSWORD`, `$env:ESXI_TARGET_PASSWORD`); Ansible playbooks use `ansible-vault` lookups — copy `group_vars/all/vault.yml.example` in each environment folder and create an encrypted `vault.yml` beside it.

## Owner

humbledgeeks-allen | [HumbledGeeks.com](https://humbledgeeks.com)
