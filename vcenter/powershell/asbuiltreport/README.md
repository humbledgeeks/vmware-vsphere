# AsBuiltReport — VMware vSphere

Generate VMware vSphere As Built documentation for one or more vCenter Servers
using [AsBuiltReport](https://www.asbuiltreport.com/). `New-VMwareAsBuiltReport.ps1`
wraps `New-AsBuiltReport` so a report can be produced with a single command.

## Prerequisites

- PowerShell 7+
- VMware PowerCLI (`Install-Module VMware.PowerCLI -Scope CurrentUser`)
- AsBuiltReport modules:

```powershell
Install-Module AsBuiltReport.Core -Scope CurrentUser
Install-Module AsBuiltReport.VMware.vSphere -Scope CurrentUser
```

`PScribo` is installed automatically as a dependency. Word and HTML output are
generated natively by PScribo — Microsoft Word is **not** required.

## Files

| File | Purpose |
|------|---------|
| `New-VMwareAsBuiltReport.ps1` | Runner that wraps `New-AsBuiltReport` |
| `AsBuiltReport.Config.sample.json` | As Built config template (author / company / email) |
| `AsBuiltReport.Config.json` | Your working config — git-ignored, created from the sample |
| `AsBuiltReport.VMware.vSphere.json` | Report config: sections, info level, health-check thresholds |
| `output/` | Generated reports — git-ignored |

## First-time setup

Copy the sample config and edit the author / company details:

```powershell
Copy-Item AsBuiltReport.Config.sample.json AsBuiltReport.Config.json
```

If `AsBuiltReport.Config.json` is absent the runner falls back to the sample and
warns.

## Credentials

Credentials are never written to disk by the runner. Supply them one of three
ways (checked in this order):

1. `-Credential` parameter (a `PSCredential`).
2. `VCENTER_USER` and `VCENTER_PASSWORD` environment variables.
3. Interactive `Get-Credential` prompt (used when neither of the above is set).

On macOS and Linux, PowerShell cannot DPAPI-encrypt exported credential files,
so avoid `Export-CliXml` for vCenter credentials on this machine — the
environment variables or the prompt are the safe options.

## Usage

Prompt for credentials, Word + HTML, health checks on:

```powershell
./New-VMwareAsBuiltReport.ps1 -Target vcenter.example.com -TrustInvalidCertificate
```

Environment-variable credentials, HTML only:

```powershell
$env:VCENTER_USER = 'administrator@vsphere.local'
$env:VCENTER_PASSWORD = '<password>'
./New-VMwareAsBuiltReport.ps1 -Target vcenter.example.com -Format HTML -TrustInvalidCertificate
```

Multiple vCenters with a timestamped filename:

```powershell
./New-VMwareAsBuiltReport.ps1 -Target vcsa01.corp.local, vcsa02.corp.local -Timestamp -TrustInvalidCertificate
```

## Detail level and health checks

Section depth is controlled by the `InfoLevel` block in
`AsBuiltReport.VMware.vSphere.json` (0 = disabled, 1 = summary … 5 =
comprehensive). It ships at level 3 for infrastructure objects and level 2 for
VMs. Edit that file to change scope, filter clusters, or tune the `HealthCheck`
thresholds.

Health checks are enabled by default; pass `-NoHealthCheck` for an
inventory-only document.

## Notes

- `-TrustInvalidCertificate` is required for vCenters presenting self-signed or
  internal-CA certificates. Omit it once a trusted certificate is in place.
- The runner suppresses the PowerCLI CEIP prompt for the session so it can run
  unattended.
