<#
.SYNOPSIS
    AdminHub profile shim. Loads the AdminHub module and launches the interactive
    menu in a real console; also runs a non-interactive health check for monitoring.

.DESCRIPTION
    Deployed as the AllUsersAllHosts profile.ps1, this imports the AdminHub module
    (installed under PSModulePath by Deploy-AdminProfile.ps1, or sitting next to
    this file in the repo / per-user "live link"). Because the module lives on
    PSModulePath on servers, its commands also AUTOLOAD inside Enter-PSSession -
    just type `adminhub`, `Show-AdminMenu`, or `Invoke-SystemHealthCheck`.

    The menu launches ONLY in an interactive console, so remoting / Invoke-Command
    / -NonInteractive / scheduled-task sessions load it silently without hanging.

.EXAMPLE
    powershell -NoProfile -File AdminProfile.ps1 -RunCheck            # text + exit code
    powershell -NoProfile -File AdminProfile.ps1 -RunCheck -AsJson    # JSON for monitoring
    powershell -NoProfile -File AdminProfile.ps1 -RunCheck -Quiet     # exit code only

.NOTES
    Exit codes (Nagios convention): 0=OK, 1=WARN, 2=FAIL(CRITICAL), 3=UNKNOWN.
    Execution policy / code signing: see README.md. For AllSigned, sign the module
    (AdminHub.psm1 + AdminHub.psd1) and this shim.
#>
param(
    [switch]$RunCheck,   # run the health check non-interactively, then exit with a status code
    [switch]$AsJson,     # with -RunCheck: emit one JSON object instead of the colored text summary
    [switch]$Quiet       # with -RunCheck: suppress the summary text (exit code only)
)

# Load the AdminHub module: prefer a copy next to this shim (repo / dev live link),
# otherwise the installed module on PSModulePath (deployed servers + Enter-PSSession).
$local = Join-Path $PSScriptRoot 'AdminHub.psd1'
try {
    if (Test-Path $local) { Import-Module $local -Force -ErrorAction Stop }
    else                  { Import-Module AdminHub  -ErrorAction Stop }
} catch {
    Write-Host "AdminHub module failed to load: $($_.Exception.Message)" -ForegroundColor Yellow
    # In monitoring mode a missing/broken module is UNKNOWN(3), not a silent OK(0).
    if ($RunCheck -and $MyInvocation.InvocationName -ne '.') { exit 3 }
    return
}

if ($RunCheck) {
    $code = Invoke-AdminHubCheck -AsJson:$AsJson -Quiet:$Quiet
    # Only 'exit' when actually run as a script; never kill a shell that dot-sourced us.
    # [int] cast guards against a non-scalar slipping through.
    if ($MyInvocation.InvocationName -ne '.') { exit ([int]($code | Select-Object -Last 1)) }
}
elseif ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and
        -not [Console]::IsInputRedirected -and
        ([Environment]::GetCommandLineArgs() -notcontains '-NonInteractive')) {
    # Interactive console only - keeps the menu's Read-Host out of automated sessions.
    Show-AdminMenu
}
