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

# Destination: the AllUsersAllHosts profile.ps1 for each PowerShell edition. The
# two editions live under DIFFERENT roots, so they cannot share one base path:
#   Windows PowerShell 5.x : $env:SystemRoot\System32\WindowsPowerShell\v1.0\profile.ps1
#   PowerShell 7+          : $env:ProgramFiles\PowerShell\7\profile.ps1
# Remote targets reach them via admin shares: Admin$ maps to %SystemRoot%, and
# C$ maps to the system drive (used to reach Program Files for PS7).
function Get-ProfileTargets {
    param([string]$Computer)
    if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq 'localhost') {
        return @(
            (Join-Path $env:SystemRoot   'System32\WindowsPowerShell\v1.0\profile.ps1'),
            (Join-Path $env:ProgramFiles 'PowerShell\7\profile.ps1')
        )
    }
    return @(
        "\\$Computer\Admin$\System32\WindowsPowerShell\v1.0\profile.ps1",
        "\\$Computer\C$\Program Files\PowerShell\7\profile.ps1"
    )
}

function Deploy-ToPath {
    param([string]$Dest)

    $dir = Split-Path $Dest
    if (-not (Test-Path $dir)) {
        Write-Verbose "Skipping $Dest (PowerShell edition not installed at this location)"
        return
    }

    if ((Test-Path $Dest) -and -not $Force) {
        $ans = Read-Host "Profile already exists at '$Dest'. Overwrite? [Y/N]"
        if ($ans -notmatch '^[Yy]') {
            Write-Host "  Skipped $Dest" -ForegroundColor Yellow
            return
        }
    }

    # Backup existing profile
    if (Test-Path $Dest) {
        $backup = "$Dest.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $Dest $backup
        Write-Host "  Backed up existing profile -> $backup" -ForegroundColor DarkYellow
    }

    Copy-Item $ProfileSourcePath $Dest -Force
    Write-Host "  Deployed -> $Dest" -ForegroundColor Green
}

# -- Validate source ------------------------------------------------------------
if (-not (Test-Path $ProfileSourcePath)) {
    Write-Error "Source profile not found: $ProfileSourcePath"
    exit 1
}

foreach ($computer in $ComputerName) {
    Write-Host "`nDeploying to: $computer" -ForegroundColor Cyan

    $isLocal = ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost')
    if (-not $isLocal -and -not (Test-Path "\\$computer\Admin$")) {
        Write-Warning "Cannot reach $computer (\\$computer\Admin$) - skipping"
        continue
    }

    foreach ($dest in (Get-ProfileTargets -Computer $computer)) {
        Deploy-ToPath -Dest $dest
    }
}

Write-Host "`nDeployment complete." -ForegroundColor Cyan
