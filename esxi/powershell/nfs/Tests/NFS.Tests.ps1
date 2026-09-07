<#
.SYNOPSIS
    Pester smoke tests for NFS folder scripts. Does not require a live ESXi.
.NOTES
    Run with:  Invoke-Pester ./NFS/Tests -Output Detailed
    Requires Pester 5.x.
#>

BeforeDiscovery {
    $scriptRoot = Split-Path -Parent $PSScriptRoot

    $script:ScriptCases = @(
        @{ Name = 'ESXI_NFS_BestPracticesV4'; Path = (Join-Path $scriptRoot 'ESXI_NFS_BestPracticesV4.ps1');
           ExpectedParams = @('OutputPath','Credential','Username','ConnectionMode','vCenter','Cluster','VMHost','HostCsvPath');
           ShouldProcess = $true }
        @{ Name = 'NetAppVIB_Installation'; Path = (Join-Path $scriptRoot 'NetAppVIB_Installation.ps1');
           ExpectedParams = @('OutputPath','Credential','Username','ConnectionMode','vCenter','Cluster','VMHost','HostCsvPath','VibPath','DatastoreName','VibFile','OpenHtmlReport');
           ShouldProcess = $true }
        @{ Name = 'Get-NfsDatastoreReport'; Path = (Join-Path $scriptRoot 'Get-NfsDatastoreReport.ps1');
           ExpectedParams = @('OutputPath','Credential','Username','ConnectionMode','vCenter','Cluster','VMHost','HostCsvPath');
           ShouldProcess = $false }
        @{ Name = 'Set-NfsDatastoreMount'; Path = (Join-Path $scriptRoot 'Set-NfsDatastoreMount.ps1');
           ExpectedParams = @('Action','DatastoreCsvPath','OutputPath','Credential','Username','vCenter','Cluster','Force');
           ShouldProcess = $true }
    )
}

Describe "NFS scripts: file presence and parse" {
    It "<Name>.ps1 exists" -ForEach $ScriptCases {
        Test-Path $Path | Should -BeTrue
    }

    It "<Name>.ps1 parses cleanly" -ForEach $ScriptCases {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe "NFS scripts: comment-based help — <Name>" -ForEach $ScriptCases {
    BeforeAll {
        $script:content = Get-Content $Path -Raw
    }

    It "has .SYNOPSIS" {
        $content | Should -Match '(?m)^\s*\.SYNOPSIS\s*$'
    }
    It "has .DESCRIPTION" {
        $content | Should -Match '(?m)^\s*\.DESCRIPTION\s*$'
    }
    It "has .NOTES" {
        $content | Should -Match '(?m)^\s*\.NOTES\s*$'
    }
    It "has at least one .EXAMPLE or .PARAMETER block" {
        $content | Should -Match '(?m)^\s*\.(EXAMPLE|PARAMETER)\b'
    }
}

Describe "NFS scripts: CmdletBinding and parameters — <Name>" -ForEach $ScriptCases {
    BeforeAll {
        $tokens = $null; $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
        $script:paramBlock = $ast.ParamBlock
    }

    It "declares a param block" {
        $paramBlock | Should -Not -BeNullOrEmpty
    }

    It "declares [CmdletBinding(...)]" {
        ($paramBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }) |
            Should -Not -BeNullOrEmpty
    }

    It "declares expected parameter '<_>'" -ForEach $ExpectedParams {
        $declared = $paramBlock.Parameters.Name.VariablePath.UserPath
        $declared | Should -Contain $_
    }

    if ($ShouldProcess) {
        It "declares SupportsShouldProcess" {
            $cb = $paramBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } | Select-Object -First 1
            $supports = $cb.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }
            $supports | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Resolve-PowerCLICredential helper — <Name>" -ForEach $ScriptCases {
    BeforeAll {
        $script:content = Get-Content $Path -Raw
    }

    It "contains function Resolve-PowerCLICredential" {
        $content | Should -Match 'function\s+Resolve-PowerCLICredential'
    }
    It "honors -Credential parameter first" {
        $content | Should -Match 'if\s*\(\s*\$Credential\s*\)\s*\{\s*return\s+\$Credential\s*\}'
    }
    It "falls back to env:VCENTER_PASSWORD" {
        $content | Should -Match '\$env:VCENTER_PASSWORD'
    }
}

Describe "NetAppVIB_Installation security" {
    BeforeAll {
        $script:vibPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'NetAppVIB_Installation.ps1'
        $script:content = Get-Content $vibPath -Raw
    }

    It "does NOT pass plaintext User/Password to Connect-VIServer in CSV mode" {
        $content | Should -Not -Match 'Connect-VIServer[^\r\n]*-User\s+\$row\.User[^\r\n]*-Password\s+\$row\.Password'
    }
    It "warns or comments that passwords don't come from CSV" {
        $content | Should -Match 'passwords?\s+NEVER\s+come\s+from\s+CSV'
    }
}

Describe "Set-NfsDatastoreMount safety" {
    BeforeAll {
        $script:mountPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-NfsDatastoreMount.ps1'
        $script:content = Get-Content $mountPath -Raw
    }

    It "checks for powered-on VMs before unmount" {
        $content | Should -Match 'PoweredOn'
    }
    It "requires -Force to bypass powered-on VM check" {
        $content | Should -Match '\$Force'
    }
    It "declares ConfirmImpact='High'" {
        $content | Should -Match "ConfirmImpact\s*=\s*'High'"
    }
}
