# VMware vSphere — As-Built Report

Generates an As-Built document (Word + HTML) of a vCenter/vSphere environment
using AsBuiltReport. Runs on macOS PowerShell 7.

## 1. Launch PowerShell

```bash
# macOS: install pwsh once if you don't have it
brew install --cask powershell
pwsh
```

Inside `pwsh`, trust the gallery once:

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
```

## 2. Install / update the modules

```powershell
Install-Module AsBuiltReport.VMware.vSphere -Scope CurrentUser -AllowClobber -SkipPublisherCheck
Install-Module VCF.PowerCLI                 -Scope CurrentUser -AllowClobber -SkipPublisherCheck
# later, to update:
Update-Module AsBuiltReport.VMware.vSphere
Update-Module VCF.PowerCLI
```

## 3. One-time global config (company info, author)

```powershell
New-AsBuiltConfig      # note the JSON path it prints; reuse it with -AsBuiltConfigFilePath
```

## 4. Generate the As-Built

```powershell
$cred = Get-Credential
New-AsBuiltReport `
  -Report VMware.vSphere `
  -Target vcenter.example.com `
  -Credential $cred `
  -Format Html,Word `
  -OutputFolderPath "$HOME/AsBuiltReports" `
  -StyleFilePath "$HOME/AsBuiltReports/<Company>.Style.ps1" `   # optional company branding (see note)
  -EnableHealthCheck -Verbose
```

Replace `vcenter.example.com` with your vCenter FQDN/IP.

## Notes

- Works fully on macOS — PowerCLI and the vSphere report module are cross-platform.
- **Company logo / branding:** the `-StyleFilePath` points to a custom style script
  (`<Company>.Style.ps1`) that embeds the company logo on the cover page. That script
  is pending the logo template. The cover-image embed depends on `System.Drawing`,
  which is Windows-only — so the *logo* renders reliably only when the report is
  generated on Windows; on macOS the report still builds, minus the cover image.
- Remove the `-StyleFilePath` line until `<Company>.Style.ps1` exists.
