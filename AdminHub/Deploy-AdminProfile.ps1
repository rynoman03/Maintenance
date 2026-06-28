#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys AdminProfile.ps1 to the AllUsersAllHosts PowerShell profile location
    on the local server (or a list of remote servers).

.PARAMETER ComputerName
    One or more target server names. Defaults to the local machine.

.PARAMETER ProfileSourcePath
    Full path to AdminProfile.ps1. Defaults to the script's own directory.

.PARAMETER Force
    Overwrite an existing profile without prompting.

.EXAMPLE
    .\Deploy-AdminProfile.ps1
    .\Deploy-AdminProfile.ps1 -ComputerName SRV01,SRV02 -Force

.NOTES
    Code signing: for production this script (and AdminProfile.ps1 /
    Remove-AdminProfile.ps1) should be digitally signed with an Authenticode
    code-signing certificate so it can run under the AllSigned execution policy.
    Sign LAST - any edit after signing invalidates the signature. Example:

        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select -First 1
        Set-AuthenticodeSignature -FilePath .\Deploy-AdminProfile.ps1 -Certificate $cert `
            -TimeStampServer http://timestamp.digicert.com -HashAlgorithm SHA256

    See the "Code signing" section of README.md for full instructions.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$ComputerName     = @($env:COMPUTERNAME),
    [string]  $ProfileSourcePath = (Join-Path $PSScriptRoot "AdminProfile.ps1"),
    [switch]  $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Destination inside the target machine: AllUsersAllHosts profile
# Windows PowerShell 5.x : $env:SystemRoot\System32\WindowsPowerShell\v1.0\profile.ps1
# PowerShell 7+           : $env:ProgramFiles\PowerShell\7\profile.ps1
# This script targets Windows PowerShell (5.x) by default.
$PS5ProfileRel  = "System32\WindowsPowerShell\v1.0\profile.ps1"
$PS7ProfileRel  = "PowerShell\7\profile.ps1"

function Deploy-ToLocal {
    param([string]$Root)
    foreach ($rel in @($PS5ProfileRel, $PS7ProfileRel)) {
        $dest = Join-Path $Root $rel
        $dir  = Split-Path $dest

        if (-not (Test-Path $dir)) {
            Write-Verbose "Skipping $dest (directory not found - PowerShell version not installed)"
            continue
        }

        if ((Test-Path $dest) -and -not $Force) {
            $ans = Read-Host "Profile already exists at '$dest'. Overwrite? [Y/N]"
            if ($ans -notmatch '^[Yy]') {
                Write-Host "  Skipped $dest" -ForegroundColor Yellow
                continue
            }
        }

        # Backup existing profile
        if (Test-Path $dest) {
            $backup = "$dest.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Copy-Item $dest $backup
            Write-Host "  Backed up existing profile -> $backup" -ForegroundColor DarkYellow
        }

        Copy-Item $ProfileSourcePath $dest -Force
        Write-Host "  Deployed -> $dest" -ForegroundColor Green
    }
}

# -- Validate source ------------------------------------------------------------
if (-not (Test-Path $ProfileSourcePath)) {
    Write-Error "Source profile not found: $ProfileSourcePath"
    exit 1
}

foreach ($computer in $ComputerName) {
    Write-Host "`nDeploying to: $computer" -ForegroundColor Cyan

    if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost') {
        # Local deployment
        Deploy-ToLocal -Root $env:SystemRoot
    } else {
        # Remote deployment via admin share (\\SERVER\Admin$)
        $adminShare = "\\$computer\Admin$"
        if (-not (Test-Path $adminShare)) {
            Write-Warning "Cannot reach admin share $adminShare - skipping $computer"
            continue
        }
        Deploy-ToLocal -Root $adminShare
    }
}

Write-Host "`nDeployment complete." -ForegroundColor Cyan
