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

# The two PowerShell editions live under different roots, so resolve each
# edition's profile path explicitly (matches Deploy-AdminProfile.ps1).
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

function Remove-FromPath {
    param([string]$Dest)
    if (-not (Test-Path $Dest)) { Write-Verbose "Not found, skipping: $Dest"; return }

    # Look for most-recent backup
    $backups = Get-Item "$Dest.bak_*" -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending

    if ($backups) {
        $latest = $backups[0].FullName
        Move-Item $latest $Dest -Force
        Write-Host "  Restored $Dest from $latest" -ForegroundColor Green
        # Remove any older backups
        $backups | Select-Object -Skip 1 | Remove-Item -Force
    } else {
        Remove-Item $Dest -Force
        Write-Host "  Removed $Dest (no backup found)" -ForegroundColor Yellow
    }
}

foreach ($computer in $ComputerName) {
    Write-Host "`nRemoving from: $computer" -ForegroundColor Cyan

    $isLocal = ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost')
    if (-not $isLocal -and -not (Test-Path "\\$computer\Admin$")) {
        Write-Warning "Cannot reach $computer (\\$computer\Admin$) - skipping"
        continue
    }

    foreach ($dest in (Get-ProfileTargets -Computer $computer)) {
        Remove-FromPath -Dest $dest
    }
}

Write-Host "`nRemoval complete." -ForegroundColor Cyan
