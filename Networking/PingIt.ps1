############################################################################################################################
# Created by Ryan Cashier 05.2026 v3.0                                                                                        #
# Last updated 09.2026                                                                                                     #
############################################################################################################################

# Reads a list of servers (one per line; blank lines and lines starting with # are
# ignored) and pings each once. On PowerShell 7+, pings run in parallel.

param(
    [string] $Path = ".\servers.txt",
    [string] $ReportPath
)

$serverlist = Get-Content $Path | Where-Object { $_.Trim() -and $_.Trim() -notlike '#*' }

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $results = $serverlist | ForEach-Object -Parallel {
        [pscustomobject]@{
            Server    = $_
            Reachable = [bool](Test-Connection $_ -Count 1 -ErrorAction SilentlyContinue)
        }
    } -ThrottleLimit 32
} else {
    $results = $serverlist | ForEach-Object {
        [pscustomobject]@{
            Server    = $_
            Reachable = [bool](Test-Connection $_ -Count 1 -ErrorAction SilentlyContinue)
        }
    }
}
$results = @($results)

foreach ($r in $results) {
    if ($r.Reachable) {
        Write-Host "$($r.Server) is reachable." -ForegroundColor Green
    } else {
        Write-Host "$($r.Server) is not reachable." -ForegroundColor Red
    }
}

$upCount = @($results | Where-Object Reachable).Count
$downCount = $results.Count - $upCount
Write-Host ""
Write-Host "Summary: $upCount reachable, $downCount unreachable (of $($results.Count) total)" -ForegroundColor Cyan

if ($ReportPath) {
    $results | Export-Csv -Path $ReportPath -NoTypeInformation
    Write-Host "Results exported to $ReportPath" -ForegroundColor Cyan
}
