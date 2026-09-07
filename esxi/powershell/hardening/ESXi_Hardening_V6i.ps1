<#
.SYNOPSIS
    ESXi host hardening script V6i — menu-driven, dry-run, themed HTML report, set/verify/fallback logic.
.DESCRIPTION
    Current recommended hardening version. Applies security-focused VMware advanced settings with interactive
    menu (vCenter / standalone / CSV), dry-run-then-apply flow, strict y/n prompts, per-setting verify after
    each change, and fallback via AdvancedOptionManager.UpdateOptions. Outputs a themed HTML KPI dashboard
    and per-host results table. Rollback removed (hardening-only design).
.NOTES
    Author  : HumbledGeeks / Allen Johnson / Gary Matsuda
    Date    : 2025-08-20
    Revised : 2026-07-21
    Version : V6i
    Module  : VMware.PowerCLI
    Repo    : vmware-esxi-powershell
    Warning : Makes configuration changes to ESXi hosts. Always run dry-run first.
    Changelog:
      V6i (2026-07-21)
        - FIX: Added Set-PowerCLIConfiguration -InvalidCertificateAction Ignore (Session scope) so
               Connect-VIServer no longer fails with "The SSL connection could not be established"
               against hosts presenting self-signed certificates.
        - FIX: Explicit Import-Module VMware.PowerCLI (non-fatal) before connecting.
        - PORT: Replaced PowerShell 7-only ternary (? :) expressions with if/else for Windows
                PowerShell 5.1 compatibility (section title, failure-path CSV/summary writes).
        - PORT: Rewrote 'try/catch' used as an assignment expression in New-Rule as a plain statement.
#>
#====================================================================================================================
#  AUTHOR: HumbledGeeks / Allen Johnson / Gary Matsuda
#  PURPOSE: ESXi Host Hardening – menu, dry-run, emoji output, themed HTML, sorted settings, flexible logging
#  DATE: 2025-08-20 (Revised: 2026-07-21)
#  VERSION: V6i (hardening-only)
#  NOTES:
#    - Rollback option removed (hardening-only).
#    - Visuals: colored section headers (console) + matching themed HTML with KPI cards.
#    - Flow: DRY→APPLY prompt at END of dry run; strict y/n; overrides stick (no $input var).
#    - Reliability: set→verify→fallback via AdvancedOptionManager.UpdateOptions.
#    - V6i: self-signed cert handling (InvalidCertificateAction Ignore); PS 5.1 portability fixes.
#====================================================================================================================

[CmdletBinding()]
param()

# ----------------------------- THEME & UI HELPERS -----------------------------
$Theme = @{
  TitleBg     = "DarkBlue"
  TitleFg     = "White"
  SectionFg   = "Cyan"
  AccentFg    = "Magenta"
  InfoFg      = "Cyan"
  OkFg        = "Green"
  WarnFg      = "Yellow"
  ErrFg       = "Red"
  MutedFg     = "DarkGray"
  RuleColor   = "DarkCyan"
}
$EMOJI_OK="✅"; $EMOJI_WARN="🟡"; $EMOJI_ERR="❌"; $EMOJI_INFO="ℹ️"; $EMOJI_GEAR="⚙️"; $EMOJI_NONE="⚪"; $EMOJI_HOST="🖥️"; $EMOJI_WARN_TRI="⚠️"

function New-Rule { param([string]$Char = "─"); $w = 80; try { $w = $Host.UI.RawUI.WindowSize.Width } catch { $w = 80 }; ($Char * [Math]::Max(20,[Math]::Min($w,160))) }
function Write-HeaderBar { param([string]$Text) $r=New-Rule; Write-Host ""; Write-Host $r -ForegroundColor $Theme.RuleColor; Write-Host ("  "+$Text) -ForegroundColor $Theme.TitleFg -BackgroundColor $Theme.TitleBg; Write-Host $r -ForegroundColor $Theme.RuleColor }
function Write-SectionTitle { param([string]$Emoji,[string]$Text) $r=New-Rule; Write-Host ""; Write-Host $r -ForegroundColor $Theme.RuleColor; Write-Host ("  {0} {1}" -f $Emoji,$Text) -ForegroundColor $Theme.SectionFg; Write-Host $r -ForegroundColor $Theme.RuleColor }

# log helpers (path set after log dir chosen)
function Log-Info  { param([string]$m) Write-Host "$EMOJI_INFO $m" -ForegroundColor $Theme.InfoFg;  if($global:textLogPath){$m | Out-File -FilePath $global:textLogPath -Append -Encoding UTF8} }
function Log-Ok    { param([string]$m) Write-Host "$EMOJI_OK   $m" -ForegroundColor $Theme.OkFg;    if($global:textLogPath){$m | Out-File -FilePath $global:textLogPath -Append -Encoding UTF8} }
function Log-Warn  { param([string]$m) Write-Host "$EMOJI_WARN $m" -ForegroundColor $Theme.WarnFg;  if($global:textLogPath){$m | Out-File -FilePath $global:textLogPath -Append -Encoding UTF8} }
function Log-Error { param([string]$m) Write-Host "$EMOJI_ERR  $m" -ForegroundColor $Theme.ErrFg;   if($global:textLogPath){$m | Out-File -FilePath $global:textLogPath -Append -Encoding UTF8} }

Clear-Host
Write-HeaderBar "🛡️  ESXi Host Hardening Script (V6i)"

# ----------------------------- SAFETY -----------------------------
Write-SectionTitle $EMOJI_WARN_TRI "Safety Notice"
Write-Host "You assume the risk of running this script. It will make configuration changes to ESXi hosts." -ForegroundColor $Theme.WarnFg
Write-Host "Best practice is to run in DRY MODE first to validate the impact." -ForegroundColor $Theme.WarnFg
$dryRun = Read-Host "🧪 Run in DRY MODE first? (y/n) [default: y]"
$dryRun = -not ($dryRun -match "^(n)$")

# ----------------------------- CONNECTION -----------------------------
Write-SectionTitle "🔌" "Connection Selection"
Write-Host "  1) vCenter (cluster/all hosts)" -ForegroundColor $Theme.AccentFg
Write-Host "  2) Standalone ESXi host(s)"    -ForegroundColor $Theme.AccentFg
Write-Host "  3) hosts.csv file"            -ForegroundColor $Theme.AccentFg
$selection = Read-Host "Enter choice (1-3)"

# ----------------------------- LOG LOCATION -----------------------------
Write-SectionTitle "📁" "Log Directory"
$LogRoot = Read-Host "Enter a log directory (e.g. C:\Logs). Press Enter for default C:\ESXi_Hardening_Logs"
if ([string]::IsNullOrWhiteSpace($LogRoot)) { $LogRoot = "C:\ESXi_Hardening_Logs" }
if (-not (Test-Path -LiteralPath $LogRoot)) {
  try { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null; Write-Host "$EMOJI_OK Created log directory: $LogRoot" -ForegroundColor $Theme.OkFg }
  catch { Write-Host "$EMOJI_ERR Could not create log directory $LogRoot : $($_.Exception.Message)" -ForegroundColor $Theme.ErrFg; throw }
}
$runTimestamp       = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$global:textLogPath = Join-Path $LogRoot "run_$runTimestamp.txt"

# ----------------------------- POWERCLI CONFIGURATION -----------------------------
# ESXi/vCenter hosts typically present self-signed certificates. Without this,
# Connect-VIServer fails with "The SSL connection could not be established, see inner exception."
Write-SectionTitle "🔒" "PowerCLI Configuration"
try { Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null }
catch { Log-Warn "Could not explicitly import VMware.PowerCLI; relying on autoload. ($($_.Exception.Message))" }
try {
  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
  Log-Warn "Certificate validation is DISABLED for this session (InvalidCertificateAction = Ignore)."
} catch {
  Log-Error "Failed to set PowerCLI certificate handling: $($_.Exception.Message)"
}

# ----------------------------- CREDENTIALS -----------------------------
Write-SectionTitle "🔐" "Credentials"
$cred = Get-Credential -Message "Enter ESXi/vCenter credentials"

# Manage connections
$connectedVIServers = @()
function Disconnect-All {
  foreach ($vi in $connectedVIServers) {
    try { Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null; Log-Info "Disconnected from $($vi.Name)" }
    catch { Log-Warn "Error disconnecting $($vi.Name): $($_.Exception.Message)" }
  }
}

# ----------------------------- HOST DISCOVERY -----------------------------
Write-SectionTitle $EMOJI_HOST "Host Discovery"
$hosts = @()
try {
  switch ($selection) {
    "1" {
      $vCenter = Read-Host "Enter vCenter Server FQDN/IP"
      $vi = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
      $connectedVIServers += $vi
      $clusterName = Read-Host "Enter cluster name (leave blank for all hosts)"
      if ($clusterName) { $hosts = Get-Cluster -Name $clusterName | Get-VMHost; Log-Info "Cluster '$clusterName' selected with $($hosts.Count) host(s)." }
      else { $hosts = Get-VMHost; Log-Info "All vCenter hosts selected: $($hosts.Count) host(s)." }
    }
    "2" {
      $hostnames = Read-Host "Enter comma-separated ESXi hostnames/IPs"
      foreach ($h in $hostnames -split ",") {
        $hn = $h.Trim()
        if ($hn) {
          try { $vi = Connect-VIServer -Server $hn -Credential $cred -ErrorAction Stop; $connectedVIServers += $vi; $hosts += Get-VMHost -Server $vi; Log-Ok "Connected to $hn" }
          catch { Log-Error "Failed to connect to $hn : $($_.Exception.Message)" }
        }
      }
    }
    "3" {
      $csvPath = Read-Host "Enter path to hosts.csv (one host per line in a 'Host' column)"
      if (-not (Test-Path -LiteralPath $csvPath)) { throw "CSV not found: $csvPath" }
      $csv = Import-Csv -LiteralPath $csvPath
      foreach ($row in $csv) {
        $hn = $row.Host
        if ($hn) {
          try { $vi = Connect-VIServer -Server $hn -Credential $cred -ErrorAction Stop; $connectedVIServers += $vi; $hosts += Get-VMHost -Server $vi; Log-Ok "Connected to $hn" }
          catch { Log-Error "Failed to connect to $hn : $($_.Exception.Message)" }
        }
      }
    }
    default { throw "Invalid selection '$selection'." }
  }
} catch { Log-Error "Error building host list: $($_.Exception.Message)"; throw }

if (-not $hosts -or $hosts.Count -eq 0) { Log-Error "No hosts to process. Exiting."; Disconnect-All; return }

# ----------------------------- SETTINGS CATALOG -----------------------------
Write-SectionTitle $EMOJI_GEAR "Settings Catalog (Alphabetized)"
$AdvancedSettings = @(
  [PSCustomObject]@{ Name="Config.HostAgent.log.level";              Value="info";   Type="string" },
  [PSCustomObject]@{ Name="Config.HostAgent.plugins.solo.enableMob"; Value=$false;   Type="bool"   },
  [PSCustomObject]@{ Name="Mem.ShareForceSalting";                   Value=2;        Type="int"    },
  [PSCustomObject]@{ Name="Security.AccountLockFailures";            Value=5;        Type="int"    },
  [PSCustomObject]@{ Name="Security.AccountUnlockTime";              Value=900;      Type="int"    },
  [PSCustomObject]@{ Name="Security.PasswordHistory";                Value=5;        Type="int"    },
  [PSCustomObject]@{ Name="Security.PasswordQualityControl";         Value="similar=deny retry=3 min=disabled,disabled,disabled,disabled,15"; Type="string" },
  [PSCustomObject]@{ Name="UserVars.HostClientCEIPOptIn";            Value="2";      Type="string" },
  [PSCustomObject]@{ Name="UserVars.SuppressShellWarning";           Value=1;        Type="int"    }
) | Sort-Object Name

# ----------------------------- INPUT HELPERS -----------------------------
function Read-YesNo-Strict { param([string]$Prompt,[string]$Default="y")
  while ($true) {
    $resp = Read-Host "$Prompt"
    if ([string]::IsNullOrWhiteSpace($resp)) { $resp = $Default }
    $resp = $resp.Trim().ToLower()
    if ($resp -in @('y','n')) { return $resp }
    Write-Host "$EMOJI_WARN Please enter 'y' or 'n'." -ForegroundColor $Theme.WarnFg
  }
}
function Convert-UserInputToType { param([string]$UserInput,[string]$type)
  if ($null -ne $UserInput) { $UserInput = $UserInput.Trim() }
  switch ($type) {
    "bool" {
      if ([string]::IsNullOrWhiteSpace($UserInput)) { return $null }
      if ($UserInput -eq 'y') { return $true }
      if ($UserInput -eq 'n') { return $false }
      $lc = $UserInput.ToLower()
      if ($lc -match "^(true|1)$") { return $true }
      if ($lc -match "^(false|0)$"){ return $false }
      throw "Invalid boolean input '$UserInput'. Use y/n."
    }
    "int"  { if ([string]::IsNullOrWhiteSpace($UserInput)) { return $null }; if ($UserInput -match "^-?\d+$") { return [int]$UserInput } else { throw "Invalid integer input '$UserInput'." } }
    default{ if ($null -eq $UserInput) { return $null } else { return $UserInput } }
  }
}
function Prompt-For-ChosenValue { param([pscustomobject]$Setting)
  $recVal = if ($Setting.Type -eq "bool") { if ($Setting.Value){"true"}else{"false"} } else { [string]$Setting.Value }
  while ($true) {
    $prompt = switch ($Setting.Type) {
      "bool" { "Enter your value (y/n) or press Enter to keep '$recVal'" }
      "int"  { "Enter your integer value or press Enter to keep '$recVal'" }
      default{ "Enter your value or press Enter to keep '$recVal'" }
    }
    $raw = Read-Host $prompt
    try {
      $converted = Convert-UserInputToType -UserInput $raw -type $Setting.Type
      if ($null -ne $converted) { return $converted }
      return $Setting.Value   # Enter -> keep recommended
    } catch { Write-Host "$EMOJI_WARN $($_.Exception.Message)" -ForegroundColor $Theme.WarnFg }
  }
}

# ----------------------------- INTERACTIVE CHOICES -----------------------------
Write-SectionTitle "🧩" "Apply All Recommended Values?"
$applyAll = (Read-YesNo-Strict -Prompt "Apply all Recommended Values? (y/n) [default: y]" -Default "y") -eq 'y'

$FinalSettings = New-Object System.Collections.Generic.List[object]
if ($applyAll) {
  foreach ($s in $AdvancedSettings) { $FinalSettings.Add($s) }
  Log-Ok "Using all recommended values."
} else {
  Write-Host "Manual mode: For each setting, the recommended value is shown." -ForegroundColor $Theme.MutedFg
  foreach ($s in $AdvancedSettings) {
    Write-Host ""
    Write-Host "Setting: $($s.Name)" -ForegroundColor $Theme.SectionFg
    $recVal = if ($s.Type -eq "bool") { if ($s.Value){"true"}else{"false"} } else { [string]$s.Value }
    Write-Host "Recommended value: $recVal  (type: $($s.Type))" -ForegroundColor $Theme.MutedFg

    $useRec = Read-YesNo-Strict -Prompt "Use recommended value '$recVal'? (y/n) [default: y]" -Default "y"
    if ($useRec -eq 'y') {
      $FinalSettings.Add($s)
      Log-Info "Using recommended value for $($s.Name)"
    } else {
      $chosen = Prompt-For-ChosenValue -Setting $s
      $FinalSettings.Add([PSCustomObject]@{ Name=$s.Name; Value=$chosen; Type=$s.Type })
      $chosenShow = if ($s.Type -eq "bool") { if ($chosen){"true"}else{"false"} } else { [string]$chosen }
      Log-Ok "Chosen value for $($s.Name) -> $chosenShow"
    }
  }
}

# ----------------------------- PREFLIGHT -----------------------------
Write-SectionTitle "🧪" "Preflight Summary"
$preRows = New-Object System.Collections.Generic.List[object]
foreach ($fs in $FinalSettings) {
  $valStr = if ($fs.Value -is [bool]) { if ($fs.Value){"true"}else{"false"} } else { [string]$fs.Value }
  $preRows.Add([PSCustomObject]@{ Setting=$fs.Name; Value=$valStr; Type=$fs.Type })
}
$preRows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor $Theme.InfoFg }

$preflightCsv = Join-Path $LogRoot ("preflight_{0}.csv" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
"Setting,Value,Type" | Out-File -FilePath $preflightCsv -Encoding UTF8
foreach ($r in $preRows) { "$($r.Setting),$($r.Value),$($r.Type)" | Out-File -FilePath $preflightCsv -Append -Encoding UTF8 }
Log-Ok "Preflight CSV saved: $preflightCsv"

# ----------------------------- CONFIRM START -----------------------------
$modeWord = if ($dryRun) { "simulate (dry-run)" } else { "apply" }
$confirm = Read-YesNo-Strict -Prompt ("Proceed to {0} these settings on {1} host(s)? (y/n) [default: y]" -f $modeWord, $hosts.Count) -Default "y"
if ($confirm -ne 'y') { Log-Warn "Operation cancelled by user at preflight stage."; Disconnect-All; return }

# ----------------------------- ENGINE: APPLY/DRY + HTML -----------------------------
$global:ChangeCount = 0; $global:CompliantCount = 0; $global:ErrorCount = 0
$summaryRows = New-Object System.Collections.Generic.List[object]
$script:changeLogCsv = $null; $script:baselineCsv  = $null; $script:htmlPath = $null

function Set-AdvancedSettingSafely {
  param(
    [Parameter(Mandatory=$true)] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost] $VMHost,
    [Parameter(Mandatory=$true)] [string] $Name,
    [Parameter(Mandatory=$true)] $Value,
    [switch] $DryRun
  )
  try {
    $adv = $VMHost | Get-AdvancedSetting -Name $Name -ErrorAction Stop
    $current = [string]$adv.Value
    $newValString = if ($Value -is [bool]) { if ($Value){"true"}else{"false"} } else { [string]$Value }

    if ($current.ToLower() -eq $newValString.ToLower()) {
      Log-Ok "[$($VMHost.Name)] $Name already '$current' (compliant)"
      "$($VMHost.Name),$Name,$current,$newValString,none,compliant" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
      $global:CompliantCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="none"; Result="compliant"})
      return
    }

    if ($DryRun) {
      Log-Warn "[$($VMHost.Name)] Would change $Name from '$current' to '$newValString'"
      "$($VMHost.Name),$Name,$current,$newValString,would_change,dry-run" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
      $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="would_change"; Result="dry-run"})
      return
    }

    # Primary attempt
    $adv | Set-AdvancedSetting -Value $Value -Confirm:$false | Out-Null
    $post = [string]((Get-AdvancedSetting -Entity $VMHost -Name $Name).Value)
    if ($post.ToLower() -eq $newValString.ToLower()) {
      Log-Ok "[$($VMHost.Name)] $EMOJI_GEAR Set $Name to '$newValString' ($EMOJI_OK verified)"
      "$($VMHost.Name),$Name,$current,$newValString,changed,verified" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
      $global:ChangeCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="changed"; Result="verified"})
    } else {
      try {
        $hostView = Get-View -Id $VMHost.Id
        $optMgr   = Get-View -Id $hostView.ConfigManager.AdvancedOption
        $opt      = New-Object VMware.Vim.OptionValue
        $opt.Key  = $Name
        $opt.Value= $Value
        $optMgr.UpdateOptions(@($opt))

        $post2 = [string]((Get-AdvancedSetting -Entity $VMHost -Name $Name).Value)
        if ($post2.ToLower() -eq $newValString.ToLower()) {
          Log-Ok "[$($VMHost.Name)] $EMOJI_GEAR Set $Name via fallback to '$newValString' ($EMOJI_OK verified)"
          "$($VMHost.Name),$Name,$current,$newValString,changed,verified" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
          $global:ChangeCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="changed"; Result="verified"})
        } else {
          Log-Error "[$($VMHost.Name)] Verify failed for $Name. Expected '$newValString' but read back '$post2'."
          "$($VMHost.Name),$Name,$current,$newValString,changed,verify-failed" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
          $global:ErrorCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="changed"; Result="verify-failed"})
        }
      } catch {
        Log-Error "[$($VMHost.Name)] Fallback failed for $Name : $($_.Exception.Message)"
        "$($VMHost.Name),$Name,$current,$newValString,change,error" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
        $global:ErrorCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=$current; New=$newValString; Action="change"; Result="error"})
      }
    }

    # Baseline after attempts
    $baselineVal = (Get-AdvancedSetting -Entity $VMHost -Name $Name).Value
    "$($VMHost.Name),$Name,$baselineVal" | Out-File -FilePath $script:baselineCsv -Append -Encoding UTF8

  } catch {
    Log-Error "[$($VMHost.Name)] Failed setting $Name : $($_.Exception.Message)"
    $failAction = if ($DryRun) { 'would_change' } else { 'change' }
    "$($VMHost.Name),$Name,,,$failAction,error" | Out-File -FilePath $script:changeLogCsv -Append -Encoding UTF8
    $global:ErrorCount++; $summaryRows.Add([PSCustomObject]@{Host=$VMHost.Name; Setting=$Name; Previous=""; New=""; Action=$failAction; Result="error"})
  }
}

function Get-ActionHtml { param([string]$act)
  switch -Regex ($act) {
    "^(changed)$"      { "<span class='ok'>$EMOJI_OK $act</span>" }
    "^(would_change)$" { "<span class='warn'>$EMOJI_WARN $act</span>" }
    "^(none)$"         { "<span class='muted'>$EMOJI_NONE $act</span>" }
    default            { "<span class='err'>$EMOJI_ERR $act</span>" }
  }
}
function Get-ResultHtml { param([string]$res)
  switch -Regex ($res) {
    "^(verified|ok|compliant)$" { "<span class='ok'>$EMOJI_OK $res</span>" }
    "^(dry-run|would_change)$"  { "<span class='warn'>$EMOJI_WARN $res</span>" }
    "^(verify-failed|error)$"   { "<span class='err'>$EMOJI_ERR $res</span>" }
    default                     { "<span class='muted'>$EMOJI_NONE $res</span>" }
  }
}

function Apply-SettingsPass {
  param([bool]$DryRun,[string]$ModeLabel)  # "dry-run" | "apply"

  # fresh file set per pass
  $passTs = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $script:changeLogCsv = Join-Path $LogRoot ("changes_{0}_{1}.csv"  -f $ModeLabel,$passTs)
  $script:baselineCsv  = Join-Path $LogRoot ("baseline_{0}_{1}.csv" -f $ModeLabel,$passTs)
  $script:htmlPath     = Join-Path $LogRoot ("settings_summary_{0}_{1}.html" -f $ModeLabel,$passTs)

  # CSV headers
  "Host,Setting,PreviousValue,NewValue,Action,Result" | Out-File -FilePath $script:changeLogCsv -Encoding UTF8
  "Host,Setting,CurrentValue"                        | Out-File -FilePath $script:baselineCsv  -Encoding UTF8

  # reset counters for this pass
  $global:ChangeCount = 0; $global:CompliantCount = 0; $global:ErrorCount = 0
  $summaryRows.Clear()

  $passEmoji = if ($DryRun) { "🧪" } else { "🚀" }
  $passTitle = if ($DryRun) { "Proceeding to simulate DRY RUN..." } else { "Proceeding to APPLY changes..." }
  Write-SectionTitle $passEmoji $passTitle

  foreach ($h in $hosts) {
    Log-Info "Processing host: $($h.Name)"
    foreach ($s in $FinalSettings) {
      Set-AdvancedSettingSafely -VMHost $h -Name $s.Name -Value $s.Value -DryRun:$DryRun
    }
  }

  # THEMED HTML report for this pass
  $hostCount = $hosts.Count
  $modeText  = if ($DryRun) { "Hardening – Dry Run" } else { "Hardening – Apply Mode" }

  $html = @"
<html>
<head>
<meta charset='utf-8'>
<title>ESXi Hardening Summary - $ModeLabel</title>
<style>
:root{
  --title-bg:#0b3a6e; --title-fg:#ffffff; --rule:#0aa2b0; --accent:#9c27b0;
  --ok:#0a7a0a; --warn:#b58900; --err:#b30000; --muted:#666666;
  --card-border:#dddddd; --tbl-border:#dddddd; --tbl-head:#f6f6f6;
  --text:#222; --bg:#fff; --zebra:#fafafa;
}
@media (prefers-color-scheme: dark){
  :root{
    --title-bg:#0b3a6e; --title-fg:#ffffff; --rule:#17c3d6; --accent:#d17ce3;
    --ok:#7ad67a; --warn:#ffd166; --err:#ff6b6b; --muted:#aaaaaa;
    --card-border:#2f2f2f; --tbl-border:#2f2f2f; --tbl-head:#1f1f1f;
    --text:#eaeaea; --bg:#111; --zebra:#151515;
  }
}
html,body{background:var(--bg); color:var(--text); font-family:Segoe UI,Arial,Helvetica,sans-serif; margin:0; padding:0;}
.container{padding:18px;}
.headerbar{background:var(--title-bg); color:var(--title-fg); padding:12px 16px; border-radius:10px; font-size:20px; font-weight:600;}
.subtle{color:var(--muted); margin-top:6px;}
.rule{height:6px; background:var(--rule); border-radius:4px; margin:14px 0;}
.section{margin-top:16px;}
.section-title{color:var(--accent); font-weight:700; display:flex; align-items:center; gap:8px; margin:6px 0 8px 0; font-size:18px;}
.kpi{display:flex; gap:16px; flex-wrap:wrap; margin:10px 0 16px 0;}
.card{border:1px solid var(--card-border); border-radius:10px; padding:10px 12px; min-width:210px; box-shadow:2px 2px 4px rgba(0,0,0,0.05);}
.card strong{display:block; margin-bottom:4px;}
table{border-collapse:collapse; width:100%; margin-top:8px;}
th,td{border:1px solid var(--tbl-border); padding:8px 8px; text-align:left; vertical-align:top;}
th{background:var(--tbl-head); position:sticky; top:0;}
tbody tr:nth-child(even){background:var(--zebra);}
.muted{color:var(--muted);} .ok{color:var(--ok); font-weight:600;} .warn{color:var(--warn); font-weight:600;} .err{color:var(--err); font-weight:600;}
.small{font-size:12px;}
</style>
</head>
<body>
<div class="container">
  <div class="headerbar">🛡️ ESXi Hardening Summary – $modeText</div>
  <div class="subtle small">Timestamp: $(Get-Date) • Log Folder: $LogRoot</div>

  <div class="rule"></div>

  <div class="section">
    <div class="section-title">🔢 KPIs</div>
    <div class="kpi">
      <div class="card"><strong>🖥️ Hosts Processed</strong><div>$hostCount</div></div>
      <div class="card"><strong>⚙️ Settings Changed</strong><div>$global:ChangeCount</div></div>
      <div class="card"><strong>✅ Compliant</strong><div>$global:CompliantCount</div></div>
      <div class="card"><strong>❌ Errors</strong><div>$global:ErrorCount</div></div>
    </div>
  </div>

  <div class="rule"></div>

  <div class="section">
    <div class="section-title">🧰 Applied Settings</div>
    <table>
      <thead><tr><th>Setting</th><th>Value</th></tr></thead>
      <tbody>
"@

  foreach ($s in $FinalSettings) {
    $val = if ($s.Value -is [bool]) { if ($s.Value){"true"}else{"false"} } else { [string]$s.Value }
    $html += "<tr><td>$($s.Name)</td><td>$val</td></tr>"
  }

  $html += @"
      </tbody>
    </table>
  </div>

  <div class="rule"></div>

  <div class="section">
    <div class="section-title">📜 Per-Host Results</div>
    <table>
      <thead>
        <tr>
          <th>Host</th><th>Setting</th><th>Previous</th><th>New</th><th>Action</th><th>Result</th>
        </tr>
      </thead>
      <tbody>
"@

  foreach ($row in $summaryRows) {
    $html += "<tr><td>$($row.Host)</td><td>$($row.Setting)</td><td>$($row.Previous)</td><td>$($row.New)</td><td>$(Get-ActionHtml $row.Action)</td><td>$(Get-ResultHtml $row.Result)</td></tr>"
  }

  $html += @"
      </tbody>
    </table>
  </div>

  <div class="rule"></div>

  <div class="section">
    <div class="section-title">📁 Files</div>
    <ul class="subtle">
      <li>Changes CSV: $script:changeLogCsv</li>
      <li>Baseline CSV: $script:baselineCsv</li>
      <li>Run Log (shared): $global:textLogPath</li>
      <li>Preflight CSV (shared): $preflightCsv</li>
    </ul>
  </div>
</div>
</body></html>
"@

  $html | Out-File -FilePath $script:htmlPath -Encoding UTF8

  Log-Ok  "🌐 HTML summary exported to: $script:htmlPath"
  Log-Ok  "📄 Changes CSV:  $script:changeLogCsv"
  Log-Ok  "📄 Baseline CSV: $script:baselineCsv"
  return $script:htmlPath
}

# ----------------------------- EXECUTION FLOW -----------------------------
$firstMode = if ($dryRun) { "dry-run" } else { "apply" }
$firstHtml = Apply-SettingsPass -DryRun:$dryRun -ModeLabel $firstMode

# End-of-dry prompt
if ($dryRun) {
  $rerun = Read-YesNo-Strict -Prompt "Dry run completed. Show results in HTML now? (y/n) [default: y]" -Default "y"
  if ($rerun -eq 'y') { Start-Process $firstHtml }

  $switch = Read-YesNo-Strict -Prompt "Dry run finished. Switch to APPLY mode and rerun now with the same settings and hosts? (y/n) [default: n]" -Default "n"
  if ($switch -eq 'y') {
    $secondHtml = Apply-SettingsPass -DryRun:$false -ModeLabel "apply"
    $open = Read-YesNo-Strict -Prompt "Open APPLY results in browser? (y/n) [default: y]" -Default "y"
    if ($open -eq 'y') { Start-Process $secondHtml }
  }
} else {
  $open = Read-YesNo-Strict -Prompt "Open APPLY results in browser? (y/n) [default: y]" -Default "y"
  if ($open -eq 'y') { Start-Process $firstHtml }
}

# ----------------------------- CLEANUP -----------------------------
Write-SectionTitle "🧹" "Cleanup"
Disconnect-All
Write-Host "`n$EMOJI_OK  Configuration complete." -ForegroundColor $Theme.InfoFg
