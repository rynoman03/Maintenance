<#
.SYNOPSIS
    Installs (or refreshes) AdminProfile.ps1 as the CURRENT USER's PowerShell
    profile - no administrator rights required. Use this for a personal install
    on your own machine; use Deploy-AdminProfile.ps1 for all-users / server
    deployment.

.DESCRIPTION
    Copies the AdminProfile.ps1 sitting next to this script to the per-user
    AllHosts profile location so the AdminHub menu loads whenever you open
    PowerShell. Re-run it any time to refresh after changes.

    Targets Windows PowerShell 5.x by default
    (Documents\WindowsPowerShell\profile.ps1). Add -AllEditions to also install
    to the PowerShell 7 per-user profile (Documents\PowerShell\profile.ps1).

.PARAMETER AllEditions
    Also install to the PowerShell 7 per-user profile.

.EXAMPLE
    .\Install-UserProfile.ps1
    .\Install-UserProfile.ps1 -AllEditions
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$AllEditions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'AdminProfile.ps1'
$moduleFiles = @('AdminHub.psm1', 'AdminHub.psd1')
foreach ($req in @($src) + ($moduleFiles | ForEach-Object { Join-Path $PSScriptRoot $_ })) {
    if (-not (Test-Path $req)) { Write-Error "Required source file not found: $req"; exit 1 }
}

# Per-user locations, derived from the user's Documents folder (OneDrive / folder
# redirection aware). The module goes under per-user Modules so its commands
# autoload; the profile shim imports it.
$docs = [Environment]::GetFolderPath('MyDocuments')
$editions = @(
    @{ Profile = Join-Path $docs 'WindowsPowerShell\profile.ps1'; Module = Join-Path $docs 'WindowsPowerShell\Modules\AdminHub' }
)
if ($AllEditions) {
    $editions += @{ Profile = Join-Path $docs 'PowerShell\profile.ps1'; Module = Join-Path $docs 'PowerShell\Modules\AdminHub' }
}

foreach ($e in $editions) {
    # 1. Install the module
    if (-not (Test-Path $e.Module)) { New-Item -ItemType Directory -Path $e.Module -Force | Out-Null }
    foreach ($f in $moduleFiles) {
        $mdest = Join-Path $e.Module $f
        Copy-Item (Join-Path $PSScriptRoot $f) $mdest -Force
        Unblock-File $mdest -ErrorAction SilentlyContinue
    }
    Write-Host "  Module  -> $($e.Module)" -ForegroundColor Green

    # 2. Install the profile shim (back up a pre-existing non-AdminHub profile once)
    $dest = $e.Profile
    $dir = Split-Path $dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $dest) {
        $existing = Get-Content $dest -Raw -ErrorAction SilentlyContinue
        if ($existing -notmatch 'AdminHub') {
            $bak = "$dest.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Copy-Item $dest $bak
            Write-Host "  Backed up existing profile -> $bak" -ForegroundColor DarkYellow
        }
    }
    Copy-Item $src $dest -Force
    Unblock-File $dest -ErrorAction SilentlyContinue
    Write-Host "  Profile -> $dest" -ForegroundColor Green
}

Write-Host "`nDone. Open a new PowerShell window to load the AdminHub menu." -ForegroundColor Cyan
