#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the deployed AdminProfile.ps1 from target servers, restoring any
    .bak backup if one exists. If no backup is found the profile is deleted.

.PARAMETER ComputerName
    One or more target server names. Defaults to the local machine.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProfileRels = @(
    "System32\WindowsPowerShell\v1.0\profile.ps1",
    "PowerShell\7\profile.ps1"
)

function Remove-FromLocal {
    param([string]$Root)
    foreach ($rel in $ProfileRels) {
        $dest = Join-Path $Root $rel
        if (-not (Test-Path $dest)) { Write-Verbose "Not found, skipping: $dest"; continue }

        # Look for most-recent backup
        $backups = Get-Item "$dest.bak_*" -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending

        if ($backups) {
            $latest = $backups[0].FullName
            Move-Item $latest $dest -Force
            Write-Host "  Restored $dest from $latest" -ForegroundColor Green
            # Remove any older backups
            $backups | Select-Object -Skip 1 | Remove-Item -Force
        } else {
            Remove-Item $dest -Force
            Write-Host "  Removed $dest (no backup found)" -ForegroundColor Yellow
        }
    }
}

foreach ($computer in $ComputerName) {
    Write-Host "`nRemoving from: $computer" -ForegroundColor Cyan
    $root = if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost') {
                $env:SystemRoot
            } else {
                "\\$computer\Admin$"
            }
    if ($root -like '\\*' -and -not (Test-Path $root)) {
        Write-Warning "Cannot reach $root - skipping"
        continue
    }
    Remove-FromLocal -Root $root
}

Write-Host "`nRemoval complete." -ForegroundColor Cyan
