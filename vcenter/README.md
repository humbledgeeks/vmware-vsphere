# vCenter

Automation for VMware vCenter — VM deployment, lab orchestration (vLab platform), as-built reporting, and cluster operations — in PowerShell (PowerCLI) and Ansible (`community.vmware`).

## Contents

| Path | Purpose |
|------|---------|
| `powershell/DeployUbuntu.ps1` | Deploy Ubuntu VMs from template |
| `powershell/Restore_LAB_VMs.ps1` | Restore lab VMs from backup |
| `powershell/Ubuntu_SRV_VM_Deploy.ps1` | Ubuntu server VM deployment |
| `powershell/vlab/` | Virtual lab management platform (30+ scripts, node.js dashboard) — derived from madlabber/vlab |
| `powershell/asbuiltreport/` | VMware vSphere As Built Report runner ([AsBuiltReport.com](https://www.asbuiltreport.com/)) — see `HOWTO.md` |
| `ansible/` | vCenter inventory gathering playbook |

## Prerequisites

- PowerShell 5.1+ or 7+ with VMware PowerCLI: `Install-Module VMware.PowerCLI`
- Ansible with the `community.vmware` collection

## Credentials

No secrets live in this tree. vLab reads `$env:VLAB_ADMIN_PASSWORD` / `VLAB_RDP_PASSWORD`; copy `vlab/settings.cfg.sample` to `settings.cfg` (never committed) for instance settings.

## Owner

humbledgeeks-allen | [HumbledGeeks.com](https://humbledgeeks.com)
