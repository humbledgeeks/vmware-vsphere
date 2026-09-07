# NSX

Automation for VMware NSX — segment and Tier-1 gateway inventory via the NSX-T Policy API — in both PowerShell (REST) and Ansible (`uri` module). Read-only; no changes are made to the environment.

## Contents

| Path | Purpose |
|------|---------|
| `powershell/get-nsx-segments.ps1` | List all segments and Tier-1 gateways with VLAN/overlay, transport zone, and admin state |
| `ansible/nsx-gather-segments.yml` | Gather segment and Tier-1 gateway summary from the NSX Manager |

## Prerequisites

- PowerShell 7+ (`Invoke-RestMethod -SkipCertificateCheck`)
- Ansible (no extra collection needed — uses the built-in `uri` module)

## Credentials

No secrets live in this tree. The PowerShell script prompts via `Get-Credential`; the Ansible playbook uses `ansible-vault` lookups — copy `ansible/group_vars/all/vault.yml.example` and create an encrypted `vault.yml` beside it.

## Owner

humbledgeeks-allen | [HumbledGeeks.com](https://humbledgeeks.com)
