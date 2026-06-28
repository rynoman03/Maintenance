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
if (-not (Test-Path $src)) {
    Write-Error "AdminProfile.ps1 not found next to this script ($src)."
    exit 1
}

# Per-user AllHosts profile paths, derived from the user's Documents folder so
# OneDrive / folder redirection is handled correctly.
$docs = [Environment]::GetFolderPath('MyDocuments')
$targets = @(Join-Path $docs 'WindowsPowerShell\profile.ps1')   # Windows PowerShell 5.x
if ($AllEditions) {
    $targets += (Join-Path $docs 'PowerShell\profile.ps1')      # PowerShell 7+
}

foreach ($dest in $targets) {
    $dir = Split-Path $dest
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Back up an existing profile only if it is NOT already an AdminHub profile,
    # so repeated refreshes don't pile up backups of our own file.
    if (Test-Path $dest) {
        $existing = Get-Content $dest -Raw -ErrorAction SilentlyContinue
        if ($existing -notmatch 'Show-AdminMenu') {
            $bak = "$dest.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Copy-Item $dest $bak
            Write-Host "  Backed up existing profile -> $bak" -ForegroundColor DarkYellow
        }
    }

    Copy-Item $src $dest -Force
    Unblock-File $dest -ErrorAction SilentlyContinue   # strip Mark of the Web if any
    Write-Host "  Installed -> $dest" -ForegroundColor Green
}

Write-Host "`nDone. Open a new PowerShell window to load the AdminHub menu." -ForegroundColor Cyan
