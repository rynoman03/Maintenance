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

# AdminHub ships as a MODULE (AdminHub.psm1 + AdminHub.psd1) installed under
# PSModulePath, plus a tiny profile.ps1 shim that imports it. Installing the module
# machine-wide makes its commands AUTOLOAD in any session - including Enter-PSSession.
$ModuleSourceDir = $PSScriptRoot
$ModuleFiles     = @('AdminHub.psm1', 'AdminHub.psd1')

# Module folders per edition (PS 5.x: WindowsPowerShell\Modules; PS 7: PowerShell\Modules).
# Remote via C$. Each is installed only if that edition's tree is present.
function Get-ModuleTargets {
    param([string]$Computer)
    if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq 'localhost') {
        return @(
            (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\AdminHub'),
            (Join-Path $env:ProgramFiles 'PowerShell\Modules\AdminHub')
        )
    }
    return @(
        "\\$Computer\C$\Program Files\WindowsPowerShell\Modules\AdminHub",
        "\\$Computer\C$\Program Files\PowerShell\Modules\AdminHub"
    )
}

# Profile shim (profile.ps1) targets, per edition. Admin$ -> %SystemRoot%, C$ -> system drive.
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

function Install-AdminHubModule {
    param([string]$ModuleDir)
    # Only install for an edition that is present (its parent ...\<edition> root exists).
    $editionRoot = Split-Path (Split-Path $ModuleDir)   # ...\WindowsPowerShell or ...\PowerShell
    if (-not (Test-Path $editionRoot)) {
        Write-Verbose "Skipping module at $ModuleDir (PowerShell edition not present)"
        return
    }
    if (-not (Test-Path $ModuleDir)) { New-Item -ItemType Directory -Path $ModuleDir -Force | Out-Null }
    foreach ($f in $ModuleFiles) {
        Copy-Item (Join-Path $ModuleSourceDir $f) (Join-Path $ModuleDir $f) -Force
    }
    Write-Host "  Module  -> $ModuleDir" -ForegroundColor Green
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
    Write-Host "  Profile -> $Dest" -ForegroundColor Green
}

# -- Validate sources -----------------------------------------------------------
foreach ($req in @($ProfileSourcePath) + ($ModuleFiles | ForEach-Object { Join-Path $ModuleSourceDir $_ })) {
    if (-not (Test-Path $req)) { Write-Error "Required source file not found: $req"; exit 1 }
}

foreach ($computer in $ComputerName) {
    Write-Host "`nDeploying to: $computer" -ForegroundColor Cyan

    $isLocal = ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost')
    if (-not $isLocal -and -not (Test-Path "\\$computer\Admin$")) {
        Write-Warning "Cannot reach $computer (\\$computer\Admin$) - skipping"
        continue
    }

    foreach ($m in (Get-ModuleTargets -Computer $computer)) { Install-AdminHubModule -ModuleDir $m }
    foreach ($dest in (Get-ProfileTargets -Computer $computer)) { Deploy-ToPath -Dest $dest }
}

Write-Host "`nModule + profile deployment complete." -ForegroundColor Cyan
