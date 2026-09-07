<#
.SYNOPSIS
Interactive ESXi certificate regeneration helper for post-baseline configuration.

.DESCRIPTION
Runs AFTER BestPractices_Security_Hardening.ps1.
This script regenerates ESXi host certificates after hostname/domain/DNS changes so
the certificate identity matches the final FQDN before VCF bring-up.

FEATURES
- Interactive launch experience
- Dry-run mode first
- Connection selection:
    1. vCenter
    2. Standalone ESXi host(s)
    3. hosts.csv file
- Optional reboot after regeneration
- CSV + HTML reporting
- Certificate CN/SAN verification (read live off TCP 443 - no openssl needed)
- Colorized output with clear status markers

HOW IT WORKS (v1.1)
Regenerating an ESXi SELF-SIGNED host certificate is done by /sbin/generate-certificates,
which is shell-only - there is NO esxcli command or vSphere API method that performs it.
This script manages SSH for you so you never have to touch it manually:

    1. Connect to each host over the vSphere API (HTTPS) using PowerCLI.
    2. Enable the SSH service (TSM-SSH) via the API if it is not already running.
    3. Run /sbin/generate-certificates using the OS-native 'ssh' client.
    4. Restart hostd/vpxa (or reboot) to load the new certificate.
    5. Verify the certificate the host is serving on TCP 443 (Subject / SAN).
    6. DISABLE SSH again, returning the host to its prior state.

WHY NATIVE SSH (not Posh-SSH)
Hardened ESXi 8 sshd only offers modern key-exchange algorithms (curve25519-sha256,
ecdh-sha2-*, diffie-hellman-group14-sha256). Posh-SSH / SSH.NET - even current builds -
fail to negotiate these ("Key exchange negotiation failed"). The OS-native OpenSSH client
(/usr/bin/ssh on macOS/Linux) negotiates them fine, so this script shells out to it.
Non-interactive password auth is handled by 'expect'.

.NOTES
Requires:
- VMware.PowerCLI       (API connection, enable/disable SSH)
- Native 'ssh' client   (ships with macOS/Linux; Windows: OpenSSH client feature)
- 'expect'              (ships with macOS; Linux: install via package manager)
- ESXi root credentials (standalone / CSV mode) or vCenter SSO credentials (vCenter mode)

You do NOT need to pre-enable SSH on the hosts - this script does it (and turns it back off).
#>

[CmdletBinding()]
param()

$ScriptVersion = "v1.1"
$ScriptName    = "Regenerate_ESXi_Host_Certificates_Interactive.ps1"
$AuthorLine    = "HumbledGeeks / Allen Johnson / ChatGPT"
$DefaultReconnectWaitSeconds = 90

# Cached path to the generated expect helper script (created on first SSH call).
$script:ExpectScriptPath = $null

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   ESXi Host Certificate Regeneration Utility  ($ScriptVersion)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   Script : $ScriptName" -ForegroundColor Gray
    Write-Host "   Author : $AuthorLine" -ForegroundColor Gray
    Write-Host "   Method : API enables SSH -> regenerate via native ssh -> API disables SSH" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   Purpose:" -ForegroundColor Yellow
    Write-Host "   Regenerate ESXi host certificates AFTER hostname/domain/DNS" -ForegroundColor White
    Write-Host "   changes so certificate CN / SAN reflects the final FQDN." -ForegroundColor White
    Write-Host ""
    Write-Host "   Recommended workflow:" -ForegroundColor Yellow
    Write-Host "   1. Run BestPractices_Security_Hardening.ps1" -ForegroundColor White
    Write-Host "   2. Confirm hostname, DNS, domain, and hosts file (if used)" -ForegroundColor White
    Write-Host "   3. Run this certificate regeneration script" -ForegroundColor White
    Write-Host "   4. Verify the updated certificate before VCF bring-up" -ForegroundColor White
    Write-Host ""
}

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "==== $Message ====" -ForegroundColor Cyan
}

function Write-Good { param([string]$Message) Write-Host "✅ $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "⚠️  $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "❌ $Message" -ForegroundColor Red }

function Prompt-YesNo {
    param(
        [string]$Message,
        [ValidateSet("y","n")]
        [string]$Default = "y"
    )
    while ($true) {
        $suffix = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
        $response = Read-Host "$Message $suffix"
        if ([string]::IsNullOrWhiteSpace($response)) { $response = $Default }
        $response = $response.ToLower().Trim()
        if ($response -in @("y","n")) { return $response }
        Write-WarnMsg "Please enter y or n."
    }
}

function Prompt-OutputDirectory {
    $defaultDir = Join-Path -Path (Get-Location).Path -ChildPath "CertReports"
    Write-Host "Press Enter to use default: $defaultDir" -ForegroundColor DarkGray

    while ($true) {
        $dir = Read-Host "Enter log / report output directory"
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = $defaultDir
        }

        try {
            if (-not [System.IO.Path]::IsPathRooted($dir)) {
                $dir = Join-Path -Path (Get-Location).Path -ChildPath $dir
            }

            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }

            return [System.IO.Path]::GetFullPath($dir)
        }
        catch {
            Write-Bad "Unable to create/access directory '$dir' : $($_.Exception.Message)"
        }
    }
}

function Get-ConnectionChoice {
    Write-Host ""
    Write-Host "Select target source:" -ForegroundColor Yellow
    Write-Host "  1. vCenter" -ForegroundColor White
    Write-Host "  2. Standalone ESXi host(s)" -ForegroundColor White
    Write-Host "  3. hosts.csv file" -ForegroundColor White
    while ($true) {
        $choice = Read-Host "Enter selection (1, 2, or 3)"
        if ($choice -in @("1","2","3")) { return $choice }
        Write-WarnMsg "Please enter 1, 2, or 3."
    }
}

function Resolve-TargetHosts {
    param(
        [string]$ConnectionChoice,
        [pscredential]$Credential
    )

    # Returns a PSCustomObject:
    #   Mode     : 'vCenter' (host objects come from a live vCenter connection)
    #              or 'Direct' (connect to each ESXi host directly over HTTPS)
    #   Hosts    : array of host names / IPs to process
    #   VIServer : the live vCenter connection (Mode 'vCenter' only); $null otherwise
    # NOTE: SSH (port 22) is always opened directly to each host regardless of mode.
    switch ($ConnectionChoice) {
        "1" {
            Write-Section "vCenter Target Selection"
            $vcServer = Read-Host "Enter vCenter Server FQDN or IP"
            if ([string]::IsNullOrWhiteSpace($vcServer)) { throw "vCenter Server cannot be blank." }

            Write-Host "Connecting to vCenter $vcServer ..." -ForegroundColor Yellow
            $viServer = Connect-VIServer -Server $vcServer -Credential $Credential -ErrorAction Stop

            $clusterName = Read-Host "Enter cluster name (leave blank for ALL hosts in vCenter)"
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                $hosts = Get-VMHost -Server $viServer | Sort-Object Name | Select-Object -ExpandProperty Name
            }
            else {
                $cluster = Get-Cluster -Server $viServer -Name $clusterName -ErrorAction Stop
                $hosts = Get-VMHost -Location $cluster | Sort-Object Name | Select-Object -ExpandProperty Name
            }

            if (-not $hosts) {
                Disconnect-VIServer -Server $viServer -Confirm:$false | Out-Null
                throw "No ESXi hosts were discovered from vCenter."
            }

            return [pscustomobject]@{ Mode = "vCenter"; Hosts = @($hosts); VIServer = $viServer }
        }

        "2" {
            Write-Section "Standalone ESXi Host Selection"
            $hostInput = Read-Host "Enter one or more ESXi hostnames / IPs (comma-separated)"
            if ([string]::IsNullOrWhiteSpace($hostInput)) { throw "No ESXi hosts were entered." }

            $hosts = $hostInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $hosts) { throw "No valid ESXi hosts were parsed from input." }
            return [pscustomobject]@{ Mode = "Direct"; Hosts = @($hosts); VIServer = $null }
        }

        "3" {
            Write-Section "CSV Host Selection"
            $csvPath = Read-Host "Enter full path to hosts.csv"
            if (-not (Test-Path -LiteralPath $csvPath)) { throw "CSV file not found: $csvPath" }

            $csv = Import-Csv -Path $csvPath
            if (-not $csv) { throw "CSV file is empty." }
            if (-not ($csv | Get-Member -Name Host -MemberType NoteProperty,AliasProperty,Property)) {
                throw "CSV must contain a 'Host' column."
            }

            $hosts = $csv | ForEach-Object { $_.Host } | Where-Object { $_ } | ForEach-Object { $_.Trim() }
            if (-not $hosts) { throw "No hosts found in CSV Host column." }
            return [pscustomobject]@{ Mode = "Direct"; Hosts = @($hosts); VIServer = $null }
        }
    }
}

function Connect-EsxiApi {
    # Returns a live VIServer connection to the host. For vCenter mode the shared
    # vCenter connection is reused. For direct mode it connects (with retries, since
    # hostd may still be restarting after a cert/agent operation).
    param(
        [Parameter(Mandatory = $true)] [string]$HostName,
        [Parameter(Mandatory = $true)] [pscredential]$Credential,
        [Parameter(Mandatory = $true)] [string]$Mode,
        $VIServer,
        [int]$MaxAttempts = 6,
        [int]$RetryDelaySeconds = 15
    )

    if ($Mode -eq "vCenter") { return $VIServer }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Connect-VIServer -Server $HostName -Credential $Credential -ErrorAction Stop
        }
        catch {
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }
    throw "Could not connect to $HostName over the vSphere API."
}

function Get-ExpectScriptPath {
    # Writes (once) a small expect helper that runs the native ssh client and feeds
    # the password from the SSHPASS environment variable. The password is passed via
    # a bare tcl variable ($pw) so its contents are never re-parsed - safe for any chars.
    if ($script:ExpectScriptPath -and (Test-Path -LiteralPath $script:ExpectScriptPath)) {
        return $script:ExpectScriptPath
    }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("esxi_ssh_" + ([guid]::NewGuid().ToString('N')) + ".exp")
    $expect = @'
set timeout [lindex $argv 0]
set host [lindex $argv 1]
set user [lindex $argv 2]
set cmd  [lindex $argv 3]
set pw   $env(SSHPASS)
log_user 1
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o NumberOfPasswordPrompts=1 -o PubkeyAuthentication=no -o HostKeyAlgorithms=+ssh-rsa $user@$host $cmd
expect {
    -re "(?i)password:" { send -- $pw; send -- "\r"; exp_continue }
    eof
}
catch wait result
exit [lindex $result 3]
'@
    Set-Content -LiteralPath $path -Value $expect -Encoding ASCII
    $script:ExpectScriptPath = $path
    return $path
}

function Invoke-NativeSshCommand {
    # Runs a single command on the host via the OS-native ssh client (negotiates modern
    # KEX with hardened ESXi). Returns the combined output and the remote command's exit
    # status (ssh-level failures such as KEX/auth surface as exit 255).
    param(
        [Parameter(Mandatory = $true)] [string]$HostName,
        [Parameter(Mandatory = $true)] [pscredential]$Credential,
        [Parameter(Mandatory = $true)] [string]$Command,
        [int]$TimeoutSeconds = 300
    )

    $exp  = Get-ExpectScriptPath
    $user = $Credential.UserName

    $env:SSHPASS = $Credential.GetNetworkCredential().Password
    try {
        $output = & expect $exp $TimeoutSeconds $HostName $user $Command 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        Remove-Item Env:\SSHPASS -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        Output     = ($output | Out-String).Trim()
        ExitStatus = $code
    }
}

function Get-RemoteCertInfo {
    <#
        Reads the X.509 certificate presented on the host's TLS port (default 443)
        and returns its Subject and Subject Alternative Name. This is the verification
        step: it confirms the certificate the host is actually serving after
        regeneration + restart. Retries until the service is back or timeout.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutSeconds = 180,
        [int]$RetryDelaySeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        $tcp = $null
        $ssl = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $asyncConnect = $tcp.BeginConnect($HostName, $Port, $null, $null)
            if (-not $asyncConnect.AsyncWaitHandle.WaitOne(5000)) {
                throw "TCP connection to ${HostName}:${Port} timed out."
            }
            $tcp.EndConnect($asyncConnect)

            $ssl = New-Object System.Net.Security.SslStream(
                $tcp.GetStream(),
                $false,
                ([System.Net.Security.RemoteCertificateValidationCallback] { param($s,$c,$ch,$e) $true })
            )
            $ssl.AuthenticateAsClient($HostName)

            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)

            $subject = $cert.Subject
            $san = ""
            foreach ($ext in $cert.Extensions) {
                if ($ext.Oid.Value -eq "2.5.29.17") {
                    # 2.5.29.17 = Subject Alternative Name
                    $san = ($ext.Format($true)).Trim()
                }
            }

            return [pscustomobject]@{
                Subject = $subject
                SAN     = $san
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds $RetryDelaySeconds
        }
        finally {
            if ($ssl) { try { $ssl.Dispose() } catch {} }
            if ($tcp) { try { $tcp.Close() }   catch {} }
        }
    } while ((Get-Date) -lt $deadline)

    throw "Could not retrieve certificate from ${HostName}:${Port} within $TimeoutSeconds seconds. Last error: $lastError"
}

function Disable-EsxiSsh {
    # Cleanup: stop the SSH service, returning the host to its prior state.
    # Reconnects to the host over the API because a prior hostd restart may have dropped
    # the working session. Never throws - cleanup failures are reported as warnings.
    param(
        [Parameter(Mandatory = $true)] [string]$HostName,
        [Parameter(Mandatory = $true)] [pscredential]$Credential,
        [Parameter(Mandatory = $true)] [string]$Mode,
        $VIServer
    )

    $cleanupVi = $null
    try {
        $cleanupVi = Connect-EsxiApi -HostName $HostName -Credential $Credential -Mode $Mode -VIServer $VIServer
        $vmhost = Get-VMHost -Server $cleanupVi -Name $HostName -ErrorAction Stop

        $sshService = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($sshService -and $sshService.Running) {
            Stop-VMHostService -HostService $sshService -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Good "SSH (TSM-SSH) disabled on $HostName."
        }
        else {
            Write-Host "SSH already stopped on $HostName." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-WarnMsg "Could not disable SSH on ${HostName}: $($_.Exception.Message)"
        Write-WarnMsg "Verify SSH state manually on $HostName if needed."
    }
    finally {
        if ($Mode -ne "vCenter" -and $cleanupVi) {
            try { Disconnect-VIServer -Server $cleanupVi -Confirm:$false -Force | Out-Null } catch {}
        }
    }
}

function New-HtmlReport {
    param(
        [Parameter(Mandatory = $true)] [array]$Results,
        [Parameter(Mandatory = $true)] [string]$HtmlPath,
        [Parameter(Mandatory = $true)] [string]$Mode
    )

    $total = $Results.Count
    $success = ($Results | Where-Object Status -eq "Success").Count
    $failed = ($Results | Where-Object Status -eq "Failed").Count
    $pending = ($Results | Where-Object Status -in @("Planned","WhatIf")).Count

    $rows = foreach ($r in $Results) {
        $statusClass = switch ($r.Status) {
            "Success" { "ok" }
            "Failed"  { "bad" }
            default   { "warn" }
        }

@"
<tr class="$statusClass">
<td>$($r.Host)</td>
<td>$($r.Mode)</td>
<td>$($r.PostAction)</td>
<td>$($r.GenerateCertificates)</td>
<td><pre>$($r.CertificateSubject)</pre></td>
<td><pre>$($r.CertificateSAN)</pre></td>
<td>$($r.Status)</td>
<td><pre>$($r.Notes)</pre></td>
</tr>
"@
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>ESXi Certificate Regeneration Report - $Mode</title>
<style>
body { font-family: Arial, sans-serif; background:#0f172a; color:#e5e7eb; margin:20px; }
h1, h2 { color:#93c5fd; }
.cards { display:flex; gap:16px; flex-wrap:wrap; margin-bottom:20px; }
.card { background:#111827; border:1px solid #1f2937; border-radius:14px; padding:16px; min-width:180px; box-shadow:0 4px 14px rgba(0,0,0,.25); }
.card .label { color:#9ca3af; font-size:12px; text-transform:uppercase; letter-spacing:.08em; }
.card .value { font-size:28px; font-weight:700; margin-top:6px; }
table { width:100%; border-collapse:collapse; background:#111827; }
th, td { border:1px solid #1f2937; padding:10px; vertical-align:top; }
th { background:#1f2937; color:#e5e7eb; text-align:left; }
tr.ok td { background:#052e16; }
tr.bad td { background:#450a0a; }
tr.warn td { background:#3f2c06; }
pre { white-space:pre-wrap; word-wrap:break-word; margin:0; font-family:Consolas, monospace; color:#e5e7eb; }
.small { color:#9ca3af; font-size:12px; }
</style>
</head>
<body>
<h1>ESXi Certificate Regeneration Report</h1>
<p class="small">Mode: $Mode</p>
<div class="cards">
    <div class="card"><div class="label">Hosts Processed</div><div class="value">$total</div></div>
    <div class="card"><div class="label">Success</div><div class="value">$success</div></div>
    <div class="card"><div class="label">Failed</div><div class="value">$failed</div></div>
    <div class="card"><div class="label">Planned / WhatIf</div><div class="value">$pending</div></div>
</div>
<h2>Per-Host Results</h2>
<table>
<thead>
<tr>
<th>Host</th>
<th>Mode</th>
<th>Post Action</th>
<th>Generate Certs</th>
<th>Certificate Subject</th>
<th>Certificate SAN</th>
<th>Status</th>
<th>Notes</th>
</tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</body>
</html>
"@

    Set-Content -Path $HtmlPath -Value $html -Encoding UTF8
}

$viServer = $null

try {
    Write-Header
    Write-WarnMsg "This script is intended to run AFTER BestPractices_Security_Hardening.ps1."
    Write-WarnMsg "Make sure hostname, domain name, DNS, and /etc/hosts (if used) are already correct."
    Write-WarnMsg "SSH is enabled automatically over the API, used briefly, then disabled again."
    Write-Host ""

    $dryRunAnswer = Prompt-YesNo -Message "Run in DRY MODE first?" -Default "y"
    $IsDryRun = $dryRunAnswer -eq "y"

    $connectionChoice = Get-ConnectionChoice
    $outputDirectory  = Prompt-OutputDirectory

    Write-Section "Credential Prompt"
    Write-Host "Enter credentials for vCenter (vCenter mode) or ESXi root (standalone / CSV mode)." -ForegroundColor Yellow
    $credential = Get-Credential

    $rebootAnswer = Prompt-YesNo -Message "Reboot each host after certificate regeneration?" -Default "n"
    $rebootAfter = $rebootAnswer -eq "y"

    Write-Section "Loading PowerCLI"
    # Assembly-conflict-safe load: if PowerCLI is already loaded, DON'T re-import (re-importing
    # the meta-module reloads VMware.VimAutomation.Ceip and .NET throws "Assembly already loaded").
    if (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue) {
        Write-Good "PowerCLI already loaded in this session - reusing it."
    }
    else {
        foreach ($mod in @("VMware.VimAutomation.Core", "VMware.PowerCLI")) {
            if (Get-Module -ListAvailable -Name $mod) {
                try { Import-Module $mod -ErrorAction Stop; Write-Good "Imported $mod."; break }
                catch { Write-WarnMsg "Import of $mod failed: $($_.Exception.Message)" }
            }
        }
        if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
            throw "Could not load PowerCLI. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser"
        }
    }

    try {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Good "PowerCLI ready (invalid-certificate action: Ignore)."
    }
    catch {
        Write-WarnMsg "Could not set InvalidCertificateAction: $($_.Exception.Message)"
        Write-WarnMsg "If connections fail with a certificate error, run: Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:`$false"
    }
    try { Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false -ErrorAction Stop | Out-Null } catch {}

    Write-Section "Checking SSH Client"
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "Native 'ssh' client not found in PATH. On macOS/Linux it ships with the OS; on Windows enable the OpenSSH Client feature."
    }
    if (-not (Get-Command expect -ErrorAction SilentlyContinue)) {
        throw "'expect' not found in PATH. It is required for non-interactive SSH password auth. macOS ships it at /usr/bin/expect; on Linux install via your package manager (e.g. 'sudo apt install expect')."
    }
    Write-Good "Native ssh + expect found (negotiates modern KEX with hardened ESXi)."

    Write-Section "Discovering Target Hosts"
    $target      = Resolve-TargetHosts -ConnectionChoice $connectionChoice -Credential $credential
    $connMode    = $target.Mode
    $viServer    = $target.VIServer
    $targetHosts = $target.Hosts
    Write-Good "Discovered $($targetHosts.Count) target host(s). Connection mode: $connMode."

    Write-Host ""
    Write-Host "Targets:" -ForegroundColor Yellow
    $targetHosts | ForEach-Object { Write-Host " - $_" -ForegroundColor White }

    $modeLabel = if ($IsDryRun) { "DRY-RUN" } else { "APPLY" }
    Write-Section "$modeLabel Execution"

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($hostName in $targetHosts) {
        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "Host: $hostName" -ForegroundColor Cyan
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan

        $row = [ordered]@{
            Host                 = $hostName
            Mode                 = $modeLabel
            PostAction           = if ($rebootAfter) { "Reboot" } else { "Restart hostd/vpxa" }
            GenerateCertificates = if ($IsDryRun) { "Planned" } else { "Pending" }
            CertificateSubject   = ""
            CertificateSAN       = ""
            Status               = if ($IsDryRun) { "Planned" } else { "Pending" }
            Notes                = ""
        }

        if ($IsDryRun) {
            Write-WarnMsg "DRY-RUN: Would enable SSH (API), run /sbin/generate-certificates via native ssh, then $($row.PostAction)."
            Write-Host "         Would verify the certificate on port 443, then disable SSH." -ForegroundColor Yellow
            $results.Add([pscustomobject]$row)
            continue
        }

        $apiVi = $null

        try {
            # 1. API connection + host object.
            if ($connMode -eq "vCenter") {
                $apiVi = $viServer
                $vmhost = Get-VMHost -Server $apiVi -Name $hostName -ErrorAction Stop
            }
            else {
                $apiVi = Connect-VIServer -Server $hostName -Credential $credential -ErrorAction Stop
                $vmhost = Get-VMHost -Server $apiVi -ErrorAction Stop
            }
            Write-Good "Connected to $hostName via vSphere API."

            # 2. Informational pre-checks (API).
            try {
                $esxcli = Get-EsxCli -VMHost $vmhost -V2 -ErrorAction Stop
                $hn = $esxcli.system.hostname.get.Invoke()
                if ($hn) {
                    $fqdn = if ($hn.FullyQualifiedDomainName) { $hn.FullyQualifiedDomainName } else { $hn.HostName }
                    if ($fqdn) { Write-Host "Hostname: $fqdn" -ForegroundColor Gray }
                }
                $dnsSearch = $esxcli.network.ip.dns.search.list.Invoke()
                if ($dnsSearch) { Write-Host "DNS Search: $((@($dnsSearch | ForEach-Object { $_.Domain })) -join ', ')" -ForegroundColor Gray }
            } catch { Write-WarnMsg "Could not read host info via ESXCLI (non-fatal): $($_.Exception.Message)" }

            # 3. Enable SSH if it is not already running.
            $sshService = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq "TSM-SSH" }
            if ($sshService -and -not $sshService.Running) {
                Write-Host "Enabling SSH (TSM-SSH) ..." -ForegroundColor Yellow
                Start-VMHostService -HostService $sshService -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Good "SSH enabled."
                Start-Sleep -Seconds 3
            }
            else {
                Write-Host "SSH already running." -ForegroundColor DarkGray
            }

            # Release the direct API connection now; a later hostd restart would invalidate it.
            if ($connMode -ne "vCenter" -and $apiVi) {
                try { Disconnect-VIServer -Server $apiVi -Confirm:$false -Force | Out-Null } catch {}
                $apiVi = $null
            }

            # 4. Regenerate the self-signed certificate over native ssh.
            Write-Host "Running /sbin/generate-certificates (native ssh) ..." -ForegroundColor Yellow
            $gen = Invoke-NativeSshCommand -HostName $hostName -Credential $credential -Command "/sbin/generate-certificates" -TimeoutSeconds 300
            if ($gen.ExitStatus -ne 0) {
                throw "generate-certificates failed (ssh exit $($gen.ExitStatus)). $($gen.Output)"
            }
            $row.GenerateCertificates = "Completed"
            Write-Good "Certificate generation completed."

            # 5. Post-action.
            if ($rebootAfter) {
                Write-Host "Rebooting host to fully apply certificate changes ..." -ForegroundColor Yellow
                try { Invoke-NativeSshCommand -HostName $hostName -Credential $credential -Command "nohup reboot >/dev/null 2>&1 &" -TimeoutSeconds 30 | Out-Null } catch {}

                Write-Host "Waiting $DefaultReconnectWaitSeconds seconds for the host to begin rebooting ..." -ForegroundColor Yellow
                Start-Sleep -Seconds $DefaultReconnectWaitSeconds
                Write-Host "Waiting for the host to serve its new certificate on port 443 ..." -ForegroundColor Yellow
                $certInfo = Get-RemoteCertInfo -HostName $hostName -Port 443 -TimeoutSeconds 900 -RetryDelaySeconds 15
                Write-Good "Host is back and serving its certificate."
            }
            else {
                Write-Host "Restarting hostd (native ssh) ..." -ForegroundColor Yellow
                $hostdResult = Invoke-NativeSshCommand -HostName $hostName -Credential $credential -Command "/etc/init.d/hostd restart" -TimeoutSeconds 180
                if ($hostdResult.ExitStatus -ne 0) {
                    throw "Failed restarting hostd (ssh exit $($hostdResult.ExitStatus)). $($hostdResult.Output)"
                }

                Write-Host "Restarting vpxa (native ssh) ..." -ForegroundColor Yellow
                $vpxaResult = Invoke-NativeSshCommand -HostName $hostName -Credential $credential -Command "/etc/init.d/vpxa restart" -TimeoutSeconds 180
                if ($vpxaResult.ExitStatus -ne 0) {
                    throw "Failed restarting vpxa (ssh exit $($vpxaResult.ExitStatus)). $($vpxaResult.Output)"
                }
                Write-Good "Management agents restarted."

                Write-Host "Verifying certificate on port 443 ..." -ForegroundColor Yellow
                $certInfo = Get-RemoteCertInfo -HostName $hostName -Port 443 -TimeoutSeconds 180 -RetryDelaySeconds 5
            }

            $row.CertificateSubject = $certInfo.Subject
            $row.CertificateSAN     = $certInfo.SAN
            $row.Status             = "Success"

            if ($certInfo.Subject) { Write-Host $certInfo.Subject -ForegroundColor Gray }
            if ($certInfo.SAN)     { Write-Host $certInfo.SAN -ForegroundColor Gray }

            Write-Good "Certificate regeneration verified on $hostName."
        }
        catch {
            $row.Status = "Failed"
            $row.Notes  = $_.Exception.Message
            Write-Bad "Failed on ${hostName}: $($_.Exception.Message)"
        }
        finally {
            if ($connMode -ne "vCenter" -and $apiVi) {
                try { Disconnect-VIServer -Server $apiVi -Confirm:$false -Force | Out-Null } catch {}
            }

            # Disable SSH again (return host to prior state).
            Write-Host "Disabling SSH on $hostName ..." -ForegroundColor Yellow
            Disable-EsxiSsh -HostName $hostName -Credential $credential -Mode $connMode -VIServer $viServer
        }

        $results.Add([pscustomobject]$row)
    }

    Write-Section "Run Summary"
    $results | Format-Table -AutoSize

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath   = Join-Path -Path $outputDirectory -ChildPath "ESXi_Certificate_Regeneration_$modeLabel`_$timestamp.csv"
    $htmlPath  = Join-Path -Path $outputDirectory -ChildPath "ESXi_Certificate_Regeneration_$modeLabel`_$timestamp.html"

    $results | Export-Csv -Path $csvPath -NoTypeInformation
    New-HtmlReport -Results $results -HtmlPath $htmlPath -Mode $modeLabel

    Write-Good "CSV report saved to: $csvPath"
    Write-Good "HTML report saved to: $htmlPath"

    $openReport = Prompt-YesNo -Message "Open HTML report now?" -Default "y"
    if ($openReport -eq "y") {
        # Cross-platform open (you are on macOS PowerShell 7; Start-Process won't open a file there).
        try {
            if ($IsMacOS)      { & open $htmlPath }
            elseif ($IsLinux)  { & xdg-open $htmlPath }
            else               { Start-Process $htmlPath }   # Windows / Windows PowerShell 5.1
        }
        catch { Write-WarnMsg "Could not auto-open the report. Open it manually: $htmlPath" }
    }

    if ($IsDryRun) {
        Write-Host ""
        $switchMode = Prompt-YesNo -Message "Dry run finished. Switch to APPLY mode and rerun now with the same inputs manually?" -Default "n"
        if ($switchMode -eq "y") {
            Write-WarnMsg "Re-launch the script and answer 'n' to the DRY MODE prompt to run live."
        }
    }

    Write-Host ""
    Write-Good "Done."
}
catch {
    Write-Host ""
    Write-Bad $_.Exception.Message
    exit 1
}
finally {
    if ($viServer) { try { Disconnect-VIServer -Server $viServer -Confirm:$false -Force | Out-Null } catch {} }
    if ($script:ExpectScriptPath -and (Test-Path -LiteralPath $script:ExpectScriptPath)) {
        try { Remove-Item -LiteralPath $script:ExpectScriptPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}
