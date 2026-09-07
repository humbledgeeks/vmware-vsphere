# vSAN

Automation for VMware vSAN — cluster health, disk group, and capacity reporting — in both PowerShell (PowerCLI) and Ansible (`community.vmware`). Read-only; no changes are made to the environment.

## Contents

| Path | Purpose |
|------|---------|
| `powershell/get-vsan-health.ps1` | vSAN health tests, disk group summary, and capacity utilization per cluster |
| `ansible/vsan-cluster-info.yml` | Gather vSAN cluster health and datastore capacity from vCenter |

## Prerequisites

- PowerShell 5.1+ or 7+ with VMware PowerCLI 13+: `Install-Module VMware.PowerCLI`
- Ansible with the `community.vmware` collection

## Credentials

No secrets live in this tree. The PowerShell script takes a `PSCredential` (prompted if not supplied); the Ansible playbook uses `ansible-vault` lookups — copy `ansible/group_vars/all/vault.yml.example` and create an encrypted `vault.yml` beside it.

## Owner

humbledgeeks-allen | [HumbledGeeks.com](https://humbledgeeks.com)
